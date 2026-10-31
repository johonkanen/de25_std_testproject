#!/usr/bin/env bash
# alpine_rootfs_config.sh ROOT_DIR BOOT_DIR DATA_DIR - turn the extracted
# rootfs base (make_rootfs_base.sh: Alpine aarch64 minirootfs + python3,
# e2fsprogs) into the DE25-Standard's rootfs, and fill the data partition.
#
# The A/B layout (docs/plan_rauc.md step 2): every rootfs slot - the
# factory image's, P1's, P2's - gets this same rootfs, and an image update
# over the network replaces a whole slot. So the rootfs holds nothing that
# differs between boards or changes at run time; that lives on the data
# partition (mmcblk0p6, mounted at /data), behind links:
#
#   /etc/de25          -> /data/de25            mac, net (BOARD_IP, BOARD_GW)
#   /opt/de25web       -> /data/de25web         the web GUI: releases, token,
#                                               control.json, supervisor.sh
#   /lib/firmware/rsu  -> /data/firmware/rsu    each RSU image's FPGA core
#                                               (fpga_access.py)
#   RAUC's state and artifact repositories in /data/rauc (system.conf)
#
# ROOT_DIR gets init, networking, hostname, RTC, time sync and fstab;
# BOOT_DIR (the FAT) gets extlinux/extlinux.conf, the fallback U-Boot boots
# when a rootfs has no /boot/Image; DATA_DIR gets the MAC, the address, the
# web GUI and its token.
#
# Used by make_sdcard_image.sh. Run as root or under fakeroot so the files
# end up owned by root. Adapted from the DE25-Nano's.
#
# Env: BOARD_IP, BOARD_GW - the board's static address; DTB - the device
# tree file name; BOARD_MAC - eth0's MAC (else a new one);
# DE25WEB_TOKEN_FILE - the web GUI's update token to keep (else a new one);
# SSH_KEYS - public key files whose keys may log in as root over ssh.
set -euo pipefail

ROOT="${1:?usage: alpine_rootfs_config.sh ROOT_DIR BOOT_DIR DATA_DIR}"
BOOT="${2:?usage: alpine_rootfs_config.sh ROOT_DIR BOOT_DIR DATA_DIR}"
DATA="${3:?usage: alpine_rootfs_config.sh ROOT_DIR BOOT_DIR DATA_DIR}"
TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOARD_IP="${BOARD_IP:-192.168.1.223}"
BOARD_GW="${BOARD_GW:-192.168.1.1}"
DTB="${DTB:-socfpga_agilex5_de25_std.dtb}"

[[ -f "${ROOT}/etc/alpine-release" ]] || { echo "ERROR: ${ROOT} is not an Alpine rootfs"; exit 1; }
[[ -x "${ROOT}/usr/bin/python3" ]] || { echo "ERROR: no python3 in ${ROOT} - use make_rootfs_base.sh's tarball"; exit 1; }

echo ">> configuring inittab, networking, hostname, RTC, time sync"
# (no devtmpfs mount: the kernel mounts /dev itself, CONFIG_DEVTMPFS_MOUNT)
# /data before anything that reads it: checked (-p: only safe repairs),
# then mounted
cat > "${ROOT}/etc/inittab" << 'EOF'
::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -t sysfs sysfs /sys
::sysinit:/sbin/e2fsck -p /dev/mmcblk0p6
::sysinit:/bin/mount /data
::sysinit:/bin/mkdir -p /dev/pts
::sysinit:/bin/mount -t devpts devpts /dev/pts
::sysinit:/etc/rc.local
ttyS0::respawn:/bin/sh
::respawn:/usr/sbin/eth-watchdog
::respawn:/usr/sbin/lcd-status
::respawn:/usr/sbin/dropbear -F -E -R -s
::respawn:/opt/de25web/supervisor.sh
::ctrlaltdel:/sbin/reboot
::shutdown:/usr/sbin/killall5 -15
::shutdown:/bin/sleep 2
::shutdown:/usr/sbin/killall5 -9
::shutdown:/bin/umount -a -r
EOF
# devpts: ssh sessions need ptys. dropbear: -F foreground (init respawns
# it), -E log to stderr, -R make host keys on first use, -s no passwords:
# keys only (SSH_KEYS).
# Shutdown: busybox init runs these before it kills anything itself, so
# stop every process first. With files open for writing, `umount -a -r`
# cannot make / read-only, every reboot then resets a read-write root, and
# on the DE25-Nano a run of reboots broke the ext4 journal. TERM, 2 s, KILL,
# then read-only.

# the links to the data partition (see the top)
mkdir -p "${ROOT}/data" "${ROOT}/opt" "${ROOT}/lib/firmware"
rm -rf "${ROOT}/etc/de25" "${ROOT}/opt/de25web" "${ROOT}/lib/firmware/rsu"
ln -s /data/de25 "${ROOT}/etc/de25"
ln -s /data/de25web "${ROOT}/opt/de25web"
ln -s /data/firmware/rsu "${ROOT}/lib/firmware/rsu"
# ssh host keys on /data too: the board keeps its identity across image
# updates (every rootfs slot is the same image)
rm -rf "${ROOT}/etc/dropbear"
ln -s /data/dropbear "${ROOT}/etc/dropbear"

# root's ssh keys (dropbear -s: no password logins)
mkdir -p -m 700 "${ROOT}/root/.ssh"
: > "${ROOT}/root/.ssh/authorized_keys"
for k in ${SSH_KEYS:-}; do
    [[ -s "${k}" ]] && cat "${k}" >> "${ROOT}/root/.ssh/authorized_keys"
done
chmod 600 "${ROOT}/root/.ssh/authorized_keys"
[[ -s "${ROOT}/root/.ssh/authorized_keys" ]] || echo "   NOTE: no ssh keys (SSH_KEYS) - ssh logins impossible"

cat > "${ROOT}/etc/rc.local" << 'EOF'
#!/bin/sh
# RSU boot confirmation first: it takes over the watchdog U-Boot started
# (linux/board/rsu-confirm.sh, plan F5)
[ -x /usr/sbin/rsu-confirm ] && /usr/sbin/rsu-confirm &
# the board's own settings, on the data partition (alpine_rootfs_config.sh)
BOARD_IP=192.168.1.223
BOARD_GW=192.168.1.1
[ -r /etc/de25/net ] && . /etc/de25/net
ifconfig lo 127.0.0.1
# one fixed MAC (U-Boot gives eth0 a new random one on every boot)
[ -s /etc/de25/mac ] && ip link set eth0 address $(cat /etc/de25/mac)
ifconfig eth0 ${BOARD_IP} netmask 255.255.255.0 up
route add default gw ${BOARD_GW}
echo "nameserver ${BOARD_GW}" > /etc/resolv.conf
hostname de25-std
# PCF85263A RTC on I2C1: with a CR1220 cell fitted the clock survives
# power-off, so set it early; NTP below still corrects it and writes it back
[ -e /dev/rtc0 ] && hwclock -s -u -f /dev/rtc0
# tell the LAN this address has this MAC (a re-imaged card may bring a
# new one, and caches keep the old for minutes)
arping -U -c 2 -I eth0 ${BOARD_IP} > /dev/null 2>&1 &
# NTP needs the network: in the background, so init goes on and starts
# eth-watchdog, which bounces an eth0 that passes no traffic after a warm
# reboot (plan §5.14). This waits for the gateway first (up to 3 min).
# python3 is in the image (make_rootfs_base.sh); `apk add` stays only for a
# rootfs without it.
(
    i=0
    while ! ping -c 1 -W 1 ${BOARD_GW} > /dev/null 2>&1 && [ $i -lt 180 ]; do
        i=$((i + 1)); sleep 1
    done
    ntpd -q -n -p pool.ntp.org && [ -e /dev/rtc0 ] && hwclock -w -u -f /dev/rtc0
    command -v python3 > /dev/null || apk add python3
) &
# ssh host keys (dropbear -R) live on /data; a card older than ssh has no dir
mkdir -p -m 700 /data/dropbear
EOF
chmod +x "${ROOT}/etc/rc.local"

echo de25-std > "${ROOT}/etc/hostname"

# eth0 sometimes passed no traffic after a warm reboot on the DE25-Nano;
# the watchdog bounces it (linux/board/eth-watchdog.sh)
install -D -m 755 "${TOOLS}/../board/eth-watchdog.sh" "${ROOT}/usr/sbin/eth-watchdog"
# RSU boot confirmation (plan F5): an image that does not come up healthy
# falls back (linux/board/rsu-confirm.sh)
install -D -m 755 "${TOOLS}/../board/rsu-confirm.sh" "${ROOT}/usr/sbin/rsu-confirm"
# the board's address on the LCD module (linux/board/lcd-status.py)
install -D -m 755 "${TOOLS}/../board/lcd-status.py" "${ROOT}/usr/sbin/lcd-status"

# The root is whichever partition U-Boot named (root=): no line for it.
# /boot (the FAT partition) stays unmounted: only what writes a new FPGA
# core or U-Boot mounts it, so a power cut cannot leave a dirty FAT behind.
# Mounted, it covers this rootfs's own /boot (the kernel U-Boot loaded -
# harmless while Linux runs).
cat > "${ROOT}/etc/fstab" << 'EOF'
/dev/mmcblk0p6  /data   ext4    rw,relatime             0 2
/dev/mmcblk0p1  /boot   vfat    rw,relatime,noauto      0 0
proc            /proc   proc    defaults                0 0
sysfs           /sys    sysfs   defaults                0 0
devtmpfs        /dev    devtmpfs defaults               0 0
EOF
mkdir -p "${ROOT}/boot"

# ---- the data partition ---------------------------------------------------
echo ">> data partition: MAC, address, web GUI"
mkdir -p -m 700 "${DATA}/dropbear"
mkdir -p "${DATA}/de25" "${DATA}/firmware/rsu" "${DATA}/rauc/gui" "${DATA}/rauc/core"
# One fixed, locally administered MAC. BOARD_MAC (make_sdcard_image.sh keeps
# it in a host file) keeps it across re-imaged cards; else a new one.
if [[ -n "${BOARD_MAC:-}" ]]; then
    echo "${BOARD_MAC}" > "${DATA}/de25/mac"
elif [[ ! -s "${DATA}/de25/mac" ]]; then
    printf '02:de:25:%02x:%02x:%02x\n' $(od -An -tu1 -N3 /dev/urandom) > "${DATA}/de25/mac"
fi
printf 'BOARD_IP=%s\nBOARD_GW=%s\n' "${BOARD_IP}" "${BOARD_GW}" > "${DATA}/de25/net"

echo ">> installing the web GUI to /data/de25web (see linux/webapp/README.md)"
# the same layout linux/tools/install_webapp.py makes on a running board
python3 - "${DATA}/de25web" "${TOOLS}" << 'PYEOF'
import io, os, sys, tarfile
base, tools = sys.argv[1], sys.argv[2]
sys.modules.setdefault("serial", type(sys)("serial"))   # install_webapp imports it
sys.path.insert(0, tools)
import install_webapp
blob, rel = install_webapp.bundle()
os.makedirs(os.path.join(base, "releases"), exist_ok=True)
tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz").extractall(base)
link = os.path.join(base, "current")
if os.path.lexists(link):
    os.remove(link)
os.symlink(os.path.join("releases", rel), link)
print("   release", rel)
PYEOF
find "${DATA}/de25web" -name __pycache__ -prune -exec rm -rf {} +
# the update token: DE25WEB_TOKEN_FILE keeps an existing one (a re-imaged
# card then still takes the same uploads), else a new one
if [[ -n "${DE25WEB_TOKEN_FILE:-}" && -s "${DE25WEB_TOKEN_FILE}" ]]; then
    ( umask 077; tr -d ' \n' < "${DE25WEB_TOKEN_FILE}" > "${DATA}/de25web/token" )
elif [[ ! -f "${DATA}/de25web/token" ]]; then
    ( umask 077; head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' > "${DATA}/de25web/token" )
fi

echo ">> extlinux.conf (the fallback boot: FAT kernel, factory rootfs)"
mkdir -p "${BOOT}/extlinux"
cat > "${BOOT}/extlinux/extlinux.conf" << EOF
# U-Boot boots the running image's rootfs (its /boot/Image) itself; this is
# its fallback when that fails: the FAT's kernel on the factory rootfs.
default alpine
timeout 1

label alpine
    kernel /Image
    fdt /${DTB}
    append console=ttyS0,115200 root=/dev/mmcblk0p2 rw rootwait earlycon panic=-1 kvm-arm.mode=nvhe watchdog.open_timeout=120
EOF
