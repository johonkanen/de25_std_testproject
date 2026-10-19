#!/usr/bin/env bash
# alpine_rootfs_config.sh ROOT_DIR [BOOT_DIR] - turn an extracted Alpine
# aarch64 minirootfs into the DE25-Standard's rootfs: init, networking,
# hostname, a fixed MAC, the RTC, time sync, fstab, and the web GUI in
# /opt/de25web. With BOOT_DIR, also
# writes the boot partition's extlinux/extlinux.conf, which U-Boot's distro
# boot finds on its own (no saveenv needed).
#
# Used by make_sdcard_image.sh. Run as root or under fakeroot so the files
# end up owned by root. Adapted from the DE25-Nano's.
#
# Env: BOARD_IP, BOARD_GW - the board's static address; DTB - the device
# tree file name on the boot partition; DE25WEB_TOKEN_FILE - the web GUI's
# update token to keep (else a new one).
set -euo pipefail

ROOT="${1:?usage: alpine_rootfs_config.sh ROOT_DIR [BOOT_DIR]}"
BOOT="${2:-}"
TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOARD_IP="${BOARD_IP:-192.168.1.223}"
BOARD_GW="${BOARD_GW:-192.168.1.1}"
DTB="${DTB:-socfpga_agilex5_de25_std.dtb}"

[[ -f "${ROOT}/etc/alpine-release" ]] || { echo "ERROR: ${ROOT} is not an Alpine rootfs"; exit 1; }

echo ">> configuring inittab, networking, hostname, RTC, time sync"
# (no devtmpfs mount: the kernel mounts /dev itself, CONFIG_DEVTMPFS_MOUNT)
cat > "${ROOT}/etc/inittab" << 'EOF'
::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -t sysfs sysfs /sys
::sysinit:/etc/rc.local
ttyS0::respawn:/bin/sh
::respawn:/usr/sbin/eth-watchdog
::respawn:/opt/de25web/supervisor.sh
::ctrlaltdel:/sbin/reboot
::shutdown:/usr/sbin/killall5 -15
::shutdown:/bin/sleep 2
::shutdown:/usr/sbin/killall5 -9
::shutdown:/bin/umount -a -r
EOF
# Shutdown: busybox init runs these before it kills anything itself, so
# stop every process first. With files open for writing, `umount -a -r`
# cannot make / read-only, every reboot then resets a read-write root, and
# on the DE25-Nano a run of reboots broke the ext4 journal. TERM, 2 s, KILL,
# then read-only.

# One fixed, locally administered MAC per card: U-Boot's
# NET_RANDOM_ETHADDR gives eth0 a new one on every boot, which the LAN's
# ARP caches and DHCP reservations do not like.
mkdir -p "${ROOT}/etc/de25"
[[ -s "${ROOT}/etc/de25/mac" ]] ||
    printf '02:de:25:%02x:%02x:%02x\n' $(od -An -tu1 -N3 /dev/urandom) > "${ROOT}/etc/de25/mac"

cat > "${ROOT}/etc/rc.local" << EOF
#!/bin/sh
ifconfig lo 127.0.0.1
ip link set eth0 address \$(cat /etc/de25/mac)
ifconfig eth0 ${BOARD_IP} netmask 255.255.255.0 up
route add default gw ${BOARD_GW}
echo "nameserver ${BOARD_GW}" > /etc/resolv.conf
hostname de25-std
# PCF85263A RTC on I2C1: with a CR1220 cell fitted the clock survives
# power-off, so set it early; NTP below still corrects it and writes it
# back (apk needs a sane clock for TLS).
[ -e /dev/rtc0 ] && hwclock -s -u -f /dev/rtc0
# a pause for the link to finish training (without it ntpd races and
# fails on a fair number of boots - DE25-Nano)
sleep 2
ntpd -q -n -p pool.ntp.org && [ -e /dev/rtc0 ] && hwclock -w -u -f /dev/rtc0
# The web GUI (/opt/de25web, started from inittab) needs python3: fetched
# on the first boot with network, a no-op after that.
command -v python3 >/dev/null || apk add python3
EOF
chmod +x "${ROOT}/etc/rc.local"

echo de25-std > "${ROOT}/etc/hostname"

# eth0 sometimes passed no traffic after a warm reboot on the DE25-Nano;
# the watchdog bounces it (linux/board/eth-watchdog.sh)
install -D -m 755 "${TOOLS}/../board/eth-watchdog.sh" "${ROOT}/usr/sbin/eth-watchdog"

# /boot (the FAT partition) stays unmounted: only what writes a new FPGA
# core mounts it, so a power cut cannot leave a dirty FAT behind
cat > "${ROOT}/etc/fstab" << 'EOF'
/dev/mmcblk0p2  /       ext4    rw,relatime             0 1
/dev/mmcblk0p1  /boot   vfat    rw,relatime,noauto      0 0
proc            /proc   proc    defaults                0 0
sysfs           /sys    sysfs   defaults                0 0
devtmpfs        /dev    devtmpfs defaults               0 0
EOF
mkdir -p "${ROOT}/boot"

echo ">> installing the web GUI to /opt/de25web (see linux/webapp/README.md)"
# the same layout linux/tools/install_webapp.py makes on a running board
python3 - "${ROOT}/opt/de25web" "${TOOLS}" << 'PYEOF'
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
find "${ROOT}/opt/de25web" -name __pycache__ -prune -exec rm -rf {} +
# the update token: DE25WEB_TOKEN_FILE keeps an existing one (a re-imaged
# card then still takes deploy_web.py), else a new one
if [[ -n "${DE25WEB_TOKEN_FILE:-}" && -s "${DE25WEB_TOKEN_FILE}" ]]; then
    ( umask 077; tr -d ' \n' < "${DE25WEB_TOKEN_FILE}" > "${ROOT}/opt/de25web/token" )
elif [[ ! -f "${ROOT}/opt/de25web/token" ]]; then
    ( umask 077; head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' > "${ROOT}/opt/de25web/token" )
fi

if [[ -n "${BOOT}" ]]; then
    echo ">> extlinux.conf"
    mkdir -p "${BOOT}/extlinux"
    cat > "${BOOT}/extlinux/extlinux.conf" << EOF
# Found by U-Boot's distro boot on the card's bootable FAT partition.
default alpine
timeout 1

label alpine
    kernel /Image
    fdt /${DTB}
    append console=ttyS0,115200 root=/dev/mmcblk0p2 rw rootwait earlycon panic=-1 kvm-arm.mode=nvhe
EOF
fi
