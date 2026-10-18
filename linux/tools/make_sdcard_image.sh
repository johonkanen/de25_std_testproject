#!/usr/bin/env bash
# make_sdcard_image.sh - a complete DE25-Standard SD card as one image
# file, built without root (fakeroot + mkfs.ext4 -d + mtools, no loop
# mounts):
#
#   partition 1  FAT32, bootable: u-boot.itb, Image, the board's .dtb,
#                extlinux/extlinux.conf (U-Boot's distro boot finds it),
#                and an HPS-first build's FPGA core (de25_std.core.rbf)
#   partition 2  ext4: Alpine aarch64 minirootfs, configured by
#                alpine_rootfs_config.sh
#
# Output: ${BUILD_DIR}/images/sdcard.img, .img.gz and .img.gz.sha256.
# Write it from U-Boot over TFTP (linux/tools/sd_recover.py), or with dd
# from a card reader:
#   gunzip -c build/images/sdcard.img.gz | sudo dd of=/dev/sdX bs=4M conv=fsync
#
# Needs ./build.sh linux (u-boot.itb, Image, .dtb), and for an HPS-first
# image ./build.sh jic (the core).
# Env: BUILD_DIR, IMG_MB (default 768 - the rootfs can be grown on the
# board later), BOOT_MB (128), BOARD_IP, BOARD_GW, ALPINE_VERSION.
set -euo pipefail

TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${TOP}/build}"
LOUT="${BUILD_DIR}/linux/out"
IMAGES="${BUILD_DIR}/images"
IMG_MB="${IMG_MB:-768}"
BOOT_MB="${BOOT_MB:-128}"            # FAT32 with 512-byte clusters needs >= 33 MB
ALPINE_VERSION="${ALPINE_VERSION:-3.24.1}"
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/alpine-minirootfs-${ALPINE_VERSION}-aarch64.tar.gz"
TARBALL="${BUILD_DIR}/downloads/alpine-minirootfs-${ALPINE_VERSION}-aarch64.tar.gz"
DTB="socfpga_agilex5_de25_std.dtb"
CORE="${IMAGES}/de25_std.core.rbf"
IMG="${IMAGES}/sdcard.img"
STAGE="${IMAGES}/sdimage"

for f in u-boot.itb Image "${DTB}"; do
    [[ -f "${LOUT}/${f}" ]] || { echo "ERROR: ${LOUT}/${f} missing - ./build.sh linux first"; exit 1; }
done
for t in fakeroot mkfs.ext4 sfdisk mformat mcopy mmd gzip; do
    command -v "${t}" >/dev/null || { echo "ERROR: ${t} not found"; exit 1; }
done
mkdir -p "${IMAGES}" "$(dirname "${TARBALL}")"
[[ -f "${TARBALL}" ]] || { echo ">> fetching Alpine ${ALPINE_VERSION} minirootfs"; wget -q -O "${TARBALL}" "${ALPINE_URL}"; }

# layout, in 512-byte sectors: 1 MiB gap, the FAT partition, ext4 to the end
P1_START=2048
P1_SECTORS=$(( BOOT_MB * 2048 ))
P2_START=$(( P1_START + P1_SECTORS ))
P2_SECTORS=$(( IMG_MB * 2048 - P2_START ))
FAT="${IMG}@@$(( P1_START * 512 ))"

echo ">> ${IMG} (${IMG_MB} MB): boot ${BOOT_MB} MB FAT32 + root $(( P2_SECTORS / 2048 )) MB ext4"
rm -f "${IMG}" "${IMG}.gz" "${IMG}.gz.sha256"
truncate -s "${IMG_MB}M" "${IMG}"
sfdisk --quiet "${IMG}" << EOF
label: dos
start=${P1_START}, size=${P1_SECTORS}, type=c, bootable
start=${P2_START}, size=${P2_SECTORS}, type=83
EOF

echo ">> boot partition"
rm -rf "${STAGE}"
mkdir -p "${STAGE}/boot"
mformat -i "${FAT}" -F -c 1 -T "${P1_SECTORS}" -h 64 -s 32 -v STDBOOT ::
mcopy -i "${FAT}" "${LOUT}/u-boot.itb" "${LOUT}/Image" "${LOUT}/${DTB}" ::
# an HPS-first build's FPGA core (make_jic.sh): U-Boot's preboot loads it
# from here before anything touches the fabric
if [[ -f "${CORE}" ]]; then
    mcopy -i "${FAT}" "${CORE}" ::
    echo "   + de25_std.core.rbf (HPS-first FPGA core)"
fi

echo ">> root partition (Alpine ${ALPINE_VERSION})"
# one fakeroot session: extraction, configuration and mkfs see the same
# (root) ownership, so the image has root-owned files without real root
BOARD_IP="${BOARD_IP:-192.168.1.223}" BOARD_GW="${BOARD_GW:-192.168.1.1}" DTB="${DTB}" \
fakeroot -- bash -euo pipefail -c '
    mkdir -p "$1/root"
    tar xzf "$2" -C "$1/root" --numeric-owner
    "$3/linux/tools/alpine_rootfs_config.sh" "$1/root" "$1/boot"
    if [ -f "$7" ]; then
        install -D -m 644 "$7" "$1/root/lib/firmware/de25_std.core.rbf"
        echo "   + /lib/firmware/de25_std.core.rbf"
    fi
    mkfs.ext4 -q -F -L std-root -E offset=$(( $4 * 512 )) -d "$1/root" "$5" "$(( $6 / 2 ))k"
' _ "${STAGE}" "${TARBALL}" "${TOP}" "${P2_START}" "${IMG}" "${P2_SECTORS}" "${CORE}"

mmd   -i "${FAT}" ::extlinux
mcopy -i "${FAT}" "${STAGE}/boot/extlinux/extlinux.conf" ::extlinux/
MAC="$(cat "${STAGE}/root/etc/de25/mac")"
rm -rf "${STAGE}"

echo ">> compressing"
gzip -k -9 "${IMG}"
( cd "${IMAGES}" && sha256sum "$(basename "${IMG}.gz")" > "$(basename "${IMG}.gz").sha256" )

echo
echo "==================================================================="
echo "  ${IMG}.gz  ($(du -h "${IMG}.gz" | cut -f1)), eth0 MAC ${MAC}"
echo
echo "  write it: python3 linux/tools/sd_recover.py   (U-Boot + TFTP)"
echo "        or: gunzip -c ${IMG}.gz | sudo dd of=/dev/sdX bs=4M conv=fsync"
echo "==================================================================="
