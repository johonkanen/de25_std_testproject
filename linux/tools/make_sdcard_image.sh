#!/usr/bin/env bash
# make_sdcard_image.sh - a complete DE25-Standard SD card as one image
# file, built without root (fakeroot + mkfs.ext4 -d + mtools, no loop
# mounts). The A/B layout of docs/plan_rauc.md step 2 (MBR):
#
#   p1  FAT32, bootable: each RSU image's U-Boot (u-boot_<slot>.itb) and
#       FPGA core (de25_std_<slot>.core.rbf), the fallback kernel, .dtb and
#       extlinux/extlinux.conf
#   p2  rootfs of the factory image  \
#   p3  rootfs.0, booted by P1        > the same rootfs image (rootfs.ext4)
#   p4  extended:                    /
#     p5  rootfs.1, booted by P2
#     p6  data (ext4, /data): the web GUI, RAUC's state and repositories,
#         each image's core, the MAC and address (alpine_rootfs_config.sh)
#
# U-Boot boots the rootfs of the image the SDM started (build_de25_linux.sh:
# its /boot/Image and .dtb, root=/dev/mmcblk0pN). The rootfs is also written
# on its own as ${BUILD_DIR}/images/rootfs.ext4: an image bundle carries it
# (make_bundle.py image).
#
# Output: ${BUILD_DIR}/images/sdcard.img, .img.gz and .img.gz.sha256, and
# rootfs.ext4. Write the card from U-Boot over TFTP (linux/tools/sd_recover.py),
# or with dd from a card reader:
#   gunzip -c build/images/sdcard.img.gz | sudo dd of=/dev/sdX bs=4M conv=fsync
#
# Needs ./build.sh linux (u-boot.itb, Image, .dtb, rsu_client), ./build.sh
# jic (the core), ./build.sh rauc and the RAUC keys (linux/tools/rauc_keys.sh),
# docker (make_rootfs_base.sh: the rootfs base with python3).
# Env: BUILD_DIR, BOOT_MB (256), SLOT_MB (768, each rootfs partition),
# ROOTFS_MB (512, the rootfs file system - RAUC grows it to the partition),
# DATA_MB (512 - grow it on the board), BOARD_IP, BOARD_GW, ALPINE_VERSION,
# DE25WEB_TOKEN_FILE (the web GUI's update token; default
# ~/.de25web_token_std when it exists - deploy_bundle.py's - else a new one),
# DE25_MAC_FILE (eth0's MAC; default ~/.de25_std_mac, written on the first
# build).
set -euo pipefail

TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${TOP}/build}"
export BUILD_DIR
LOUT="${BUILD_DIR}/linux/out"
IMAGES="${BUILD_DIR}/images"
BOOT_MB="${BOOT_MB:-256}"            # FAT32 with 512-byte clusters needs >= 33 MB
SLOT_MB="${SLOT_MB:-768}"
ROOTFS_MB="${ROOTFS_MB:-512}"
DATA_MB="${DATA_MB:-512}"
DTB="socfpga_agilex5_de25_std.dtb"
CORE="${IMAGES}/de25_std.core.rbf"
IMG="${IMAGES}/sdcard.img"
ROOTFS_IMG="${IMAGES}/rootfs.ext4"
TOKEN_FILE="${DE25WEB_TOKEN_FILE:-${HOME}/.de25web_token_std}"
[[ -s "${TOKEN_FILE}" ]] || TOKEN_FILE=""
RAUC_BIN="${BUILD_DIR}/rauc/rauc-aarch64"
RAUC_CA="${RAUC_KEYS:-${HOME}/.de25_rauc_keys}/ca.cert.pem"
# the board's eth0 MAC, kept across re-imaged cards like the token (a new
# one each image left the LAN's ARP caches pointing at the old card)
MAC_FILE="${DE25_MAC_FILE:-${HOME}/.de25_std_mac}"
BOARD_MAC="$(cat "${MAC_FILE}" 2>/dev/null || true)"
STAGE="${IMAGES}/sdimage"
SLOTS="FACTORY_IMAGE P1 P2"          # the RSU images (make_jic.sh)

for f in u-boot.itb Image "${DTB}" rsu/rsu_client rsu/librsu.rc; do
    [[ -f "${LOUT}/${f}" ]] || { echo "ERROR: ${LOUT}/${f} missing - ./build.sh linux first"; exit 1; }
done
[[ -f "${CORE}" && -f "${CORE%.rbf}.json" ]] || { echo "ERROR: ${CORE} (+ .json) missing - ./build.sh jic first"; exit 1; }
[[ -x "${RAUC_BIN}" ]] || { echo "ERROR: ${RAUC_BIN} missing - ./build.sh rauc"; exit 1; }
[[ -f "${RAUC_CA}" ]] || { echo "ERROR: ${RAUC_CA} missing - linux/tools/rauc_keys.sh"; exit 1; }
for t in fakeroot mkfs.ext4 sfdisk mformat mcopy mmd gzip dtc; do
    command -v "${t}" >/dev/null || { echo "ERROR: ${t} not found"; exit 1; }
done
(( ROOTFS_MB <= SLOT_MB )) || { echo "ERROR: ROOTFS_MB ${ROOTFS_MB} > SLOT_MB ${SLOT_MB}"; exit 1; }
mkdir -p "${IMAGES}"
BASE="$("${TOP}/linux/tools/make_rootfs_base.sh")"

# layout, in 512-byte sectors (1 MiB = 2048): a 1 MiB gap before p1, and
# before each logical partition (its EBR)
MB=2048
P1_START=${MB};                        P1_SIZE=$(( BOOT_MB * MB ))
P2_START=$(( P1_START + P1_SIZE ));    SLOT=$(( SLOT_MB * MB ))
P3_START=$(( P2_START + SLOT ))
P4_START=$(( P3_START + SLOT ))
P5_START=$(( P4_START + MB ))
P6_START=$(( P5_START + SLOT + MB ));  P6_SIZE=$(( DATA_MB * MB ))
P4_SIZE=$(( P6_START + P6_SIZE - P4_START ))
IMG_SECTORS=$(( P4_START + P4_SIZE ))
FAT="${IMG}@@$(( P1_START * 512 ))"

echo ">> ${IMG} ($(( IMG_SECTORS / MB )) MB): FAT ${BOOT_MB} MB, 3 rootfs slots of ${SLOT_MB} MB, data ${DATA_MB} MB"
rm -f "${IMG}" "${IMG}.gz" "${IMG}.gz.sha256" "${ROOTFS_IMG}"
truncate -s $(( IMG_SECTORS * 512 )) "${IMG}"
sfdisk --quiet "${IMG}" << EOF
label: dos
start=${P1_START}, size=${P1_SIZE}, type=c, bootable
start=${P2_START}, size=${SLOT}, type=83
start=${P3_START}, size=${SLOT}, type=83
start=${P4_START}, size=${P4_SIZE}, type=5
start=${P5_START}, size=${SLOT}, type=83
start=${P6_START}, size=${P6_SIZE}, type=83
EOF

echo ">> boot partition"
rm -rf "${STAGE}"
mkdir -p "${STAGE}/boot"
mformat -i "${FAT}" -F -c 1 -T "${P1_SIZE}" -h 64 -s 32 -v STDBOOT ::
# the fallback kernel (extlinux.conf) and u-boot.itb for SPLs without RSU
mcopy -i "${FAT}" "${LOUT}/u-boot.itb" "${LOUT}/Image" "${LOUT}/${DTB}" "${CORE}" ::
# the SPL's RSU multiboot loads the U-Boot of the image the SDM booted
# (u-boot_<slot>.itb), U-Boot's preboot that image's core
# (de25_std_<slot>.core.rbf). P2 is empty until an image update writes it
# and its files; until then it gets this build's, which never boot.
for slot in ${SLOTS}; do
    mcopy -i "${FAT}" "${LOUT}/u-boot.itb" "::u-boot_${slot}.itb"
    mcopy -i "${FAT}" "${CORE}" "::de25_std_${slot}.core.rbf"
done

echo ">> rootfs ($(basename "${BASE}")) and data"
# one fakeroot session: extraction, configuration and mkfs see the same
# (root) ownership, so the images have root-owned files without real root
BOARD_IP="${BOARD_IP:-192.168.1.223}" BOARD_GW="${BOARD_GW:-192.168.1.1}" DTB="${DTB}" \
DE25WEB_TOKEN_FILE="${TOKEN_FILE}" BOARD_MAC="${BOARD_MAC}" fakeroot -- bash -euo pipefail -c '
    S=$1 TOP=$2 LOUT=$3 CORE=$4 RAUC_BIN=$5 RAUC_CA=$6
    mkdir -p "$S/root" "$S/data"
    tar xzf "$7" -C "$S/root" --numeric-owner
    "$TOP/linux/tools/alpine_rootfs_config.sh" "$S/root" "$S/boot" "$S/data"
    # the kernel and DT U-Boot boots this rootfs with
    install -D -m 644 "$LOUT/Image" "$S/root/boot/Image"
    install -D -m 644 "$LOUT/'"${DTB}"'" "$S/root/boot/'"${DTB}"'"
    # the FPGA core reload (overlay + tool); each image'"'"'s core is on /data
    dtc -q -@ -I dts -O dtb -o "$S/root/lib/firmware/de25_std_core_reload.dtbo" \
        "$TOP/linux/tools/fpga_reload/core_reload.dts"
    install -D -m 755 "$TOP/linux/tools/fpga_reload/fpga-reload" "$S/root/usr/sbin/fpga-reload"
    for slot in FACTORY_IMAGE P1; do
        install -D -m 644 "$CORE" "$S/data/firmware/rsu/$slot/de25_std.core.rbf"
        install -m 644 "${CORE%.rbf}.json" "$S/data/firmware/rsu/$slot/de25_std.core.json"
    done
    # RSU userspace: rsu_client (static) and its config
    install -D -m 755 "$LOUT/rsu/rsu_client" "$S/root/usr/bin/rsu_client"
    install -D -m 644 "$LOUT/rsu/librsu.rc" "$S/root/etc/librsu.rc"
    # RAUC: the install-only binary, its config, the CA, the handlers
    install -D -m 755 "$RAUC_BIN" "$S/root/usr/bin/rauc"
    install -D -m 644 "$TOP/linux/board/rauc/system.conf" "$S/root/etc/rauc/system.conf"
    install -D -m 644 "$RAUC_CA" "$S/root/etc/rauc/keyring.pem"
    for h in post-install bootloader; do
        install -D -m 755 "$TOP/linux/board/rauc/$h" "$S/root/usr/lib/rauc/$h"
    done
    echo "   + /boot/Image + .dtb, rsu_client, rauc + system.conf, keyring.pem, handlers"
    mkfs.ext4 -q -F -L std-root -d "$S/root" "$8" '"${ROOTFS_MB}"'M
    mkfs.ext4 -q -F -L std-data -E offset=$(( $9 * 512 )) -d "$S/data" "${10}" "$(( ${11} / 2 ))k"
' _ "${STAGE}" "${TOP}" "${LOUT}" "${CORE}" "${RAUC_BIN}" "${RAUC_CA}" "${BASE}" \
    "${ROOTFS_IMG}" "${P6_START}" "${IMG}" "${P6_SIZE}"

# the same rootfs into all three slots
for start in ${P2_START} ${P3_START} ${P5_START}; do
    dd if="${ROOTFS_IMG}" of="${IMG}" bs=1M seek=$(( start / MB )) conv=notrunc,sparse status=none
done

mmd   -i "${FAT}" ::extlinux
mcopy -i "${FAT}" "${STAGE}/boot/extlinux/extlinux.conf" ::extlinux/
MAC="$(cat "${STAGE}/data/de25/mac")"
[[ -s "${MAC_FILE}" ]] || echo "${MAC}" > "${MAC_FILE}"
( umask 077; cat "${STAGE}/data/de25web/token" > "${IMAGES}/de25web_token" )
rm -rf "${STAGE}"

echo ">> compressing"
gzip -k -9 "${IMG}"
( cd "${IMAGES}" && sha256sum "$(basename "${IMG}.gz")" > "$(basename "${IMG}.gz").sha256" )

echo
echo "==================================================================="
echo "  ${IMG}.gz  ($(du -h "${IMG}.gz" | cut -f1)), eth0 MAC ${MAC}"
echo "  ${ROOTFS_IMG}  (${ROOTFS_MB} MB, for image bundles)"
if [[ -n "${TOKEN_FILE}" ]]; then
    echo "  web GUI update token: kept from ${TOKEN_FILE}"
else
    echo "  web GUI update token: new, in ${IMAGES}/de25web_token - copy it to"
    echo "  ~/.de25web_token_std for deploy_bundle.py once this card is in use"
fi
echo
echo "  write it: python3 linux/tools/sd_recover.py   (U-Boot + TFTP)"
echo "        or: gunzip -c ${IMG}.gz | sudo dd of=/dev/sdX bs=4M conv=fsync"
echo "==================================================================="
