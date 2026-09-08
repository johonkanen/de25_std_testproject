#!/usr/bin/env bash
# ============================================================================
# DE25-Standard "roll-your-own" Linux build for the minimal `de25_soc` FPGA
# design (Agilex 5, all FPGA<->HPS bridges disabled).
#
# Adapted from Altera's agilex5e-ed-gsrd  a5ed065es-premium-devkit-oobe/
# baseline-a55/software/ryo_linux/ryo_linux_sd.sh.
#
# Produces, in linux/build_output/:
#   bl31.bin                   ARM Trusted Firmware (BL31)
#   u-boot.itb                 U-Boot proper (FIT)
#   spl/u-boot-spl-dtb.hex     first-stage boot loader (goes in the JIC)
#   Image                      Linux kernel
#   socfpga_agilex5_de25.dtb   device tree
#   initramfs.cpio             toybox root filesystem
#   sdcard.img                 FAT32 image: Image + dtb + itb + initramfs
#
# Then combine the SPL with the FPGA bitstream:
#   quartus_pfg -c ../output_files/de25_soc.sof de25_soc.jic \
#       -o device=MT25QU02G -o flash_loader=A5ED013BB32AE4SCS \
#       -o hps_path=linux/build_output/u-boot-socfpga/spl/u-boot-spl-dtb.hex \
#       -o mode=ASX4 -o hps=1
# (adjust -o device= to the DE25-Standard QSPI part; see docs.)
#
# REQUIREMENTS: Linux host, internet, ~25 GB free, and:
#   git wget xz-utils bc bison flex libssl-dev python3 mtools dosfstools
#
# This is a FIRST CUT - it builds every component with default configs and
# an in-RAM toybox rootfs.  It has not been run on hardware.  Expect to
# iterate on linux/dts/socfpga_agilex5_de25.dts over the HPS UART console.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${HERE}/build_output"
JOBS="$(nproc)"

# ---- pinned sources (match your Quartus / QPDS release) --------------------
# QPDS_REF is a git TAG on all three altera-fpga repos; use the one that
# matches your Quartus version (QPDS26.1.1_REL_GSRD_PR for Quartus 26.1.1).
QPDS_REF="${QPDS_REF:-QPDS26.1.1_REL_GSRD_PR}"
ATF_REPO="https://github.com/altera-fpga/arm-trusted-firmware"
UBOOT_REPO="https://github.com/altera-fpga/u-boot-socfpga"
LINUX_REPO="https://github.com/altera-fpga/linux-socfpga"
TOYBOX_REPO="https://github.com/landley/toybox.git"
# ARM GNU aarch64 bare-metal-capable toolchain (has the LTO plugin that
# ATF's release build needs; the landley musl toolchain does not).
# Point CROSS_TOOLCHAIN at an existing install to skip the download.
TOOLCHAIN_URL="https://developer.arm.com/-/media/Files/downloads/gnu/13.3.rel1/binrel/arm-gnu-toolchain-13.3.rel1-x86_64-aarch64-none-linux-gnu.tar.xz"
TOOLCHAIN_DIR="arm-gnu-toolchain-13.3.rel1-x86_64-aarch64-none-linux-gnu"
CROSS_PREFIX="aarch64-none-linux-gnu-"

SOF="${SOF:-${HERE}/../output_files/de25_soc.sof}"

# mformat/mcopy: from PATH, or set MTOOLS_BIN to a dir holding them
[[ -n "${MTOOLS_BIN:-}" ]] && export PATH="${MTOOLS_BIN}:${PATH}"
command -v mformat >/dev/null || { echo "ERROR: mtools (mformat/mcopy) not found; apt install mtools, or set MTOOLS_BIN"; exit 1; }

mkdir -p "${OUT}"
cd "${OUT}"

export ARCH=arm64

# ---- toolchain -----------------------------------------------------------
if [[ -n "${CROSS_TOOLCHAIN:-}" && -x "${CROSS_TOOLCHAIN}/bin/${CROSS_PREFIX}gcc" ]]; then
    TC_BIN="${CROSS_TOOLCHAIN}/bin"
else
    if [[ ! -x "${TOOLCHAIN_DIR}/bin/${CROSS_PREFIX}gcc" ]]; then
        echo ">> fetching toolchain"
        wget -q --show-progress -O tc.tar.xz "${TOOLCHAIN_URL}"
        tar -xf tc.tar.xz && rm tc.tar.xz
    fi
    TC_BIN="${OUT}/${TOOLCHAIN_DIR}/bin"
fi
export PATH="${TC_BIN}:${PATH}"
export CROSS_COMPILE="${CROSS_PREFIX}"
# toybox (and others) invoke ${CROSS_COMPILE}cc; the ARM GNU toolchain only
# ships ${CROSS_COMPILE}gcc, so provide a cc alias on PATH.
mkdir -p "${OUT}/ccshim"
ln -sf "$(command -v ${CROSS_PREFIX}gcc)" "${OUT}/ccshim/${CROSS_PREFIX}cc"
export PATH="${OUT}/ccshim:${PATH}"
echo ">> toolchain: $(command -v ${CROSS_PREFIX}gcc)  ($(${CROSS_PREFIX}gcc -dumpversion))"

# ---- ARM Trusted Firmware ----------------------------------------------
if [[ ! -d arm-trusted-firmware ]]; then
    git clone --depth 1 -b "${QPDS_REF}" "${ATF_REPO}" arm-trusted-firmware
fi
make -C arm-trusted-firmware -j"${JOBS}" PLAT=agilex5 ENABLE_LTO=0 bl31
cp arm-trusted-firmware/build/agilex5/release/bl31.bin "${OUT}/bl31.bin"

# ---- U-Boot -----------------------------------------------------------
if [[ ! -d u-boot-socfpga ]]; then
    git clone --depth 1 -b "${QPDS_REF}" "${UBOOT_REPO}" u-boot-socfpga
fi
pushd u-boot-socfpga >/dev/null
    # U-Boot uses the upstream socfpga_agilex5_de25_nano DT (see the config
    # fragment) - nothing to inject here.
    git checkout -- . && git clean -fdq
    ln -sf "${OUT}/bl31.bin" bl31.bin
    make mrproper
    make socfpga_agilex5_defconfig
    ./scripts/kconfig/merge_config.sh -O . -m .config "${HERE}/de25_uboot.config-fragment"
    make -j"${JOBS}"
    mkdir -p "${OUT}/spl"
    cp u-boot.itb              "${OUT}/u-boot.itb"
    cp spl/u-boot-spl-dtb.hex  "${OUT}/spl/u-boot-spl-dtb.hex"
popd >/dev/null

# ---- Linux kernel ---------------------------------------------------
if [[ ! -d linux-socfpga ]]; then
    git clone --depth 1 -b "${QPDS_REF}" "${LINUX_REPO}" linux-socfpga
fi
pushd linux-socfpga >/dev/null
    git checkout -- . && git clean -fdq
    cp "${HERE}/dts/socfpga_agilex5_de25.dts" arch/arm64/boot/dts/intel/
    grep -qE 'socfpga_agilex5_de25\.dtb' arch/arm64/boot/dts/intel/Makefile || \
        sed -i 's|\(socfpga_agilex5_socdk\.dtb\)|\1\ndtb-$(CONFIG_ARCH_INTEL_SOCFPGA) += socfpga_agilex5_de25.dtb|' \
            arch/arm64/boot/dts/intel/Makefile
    make defconfig
    ./scripts/kconfig/merge_config.sh -O . .config "${HERE}/de25_kernel.config-fragment"
    make -j"${JOBS}" Image intel/socfpga_agilex5_de25.dtb
    cp arch/arm64/boot/Image                              "${OUT}/Image"
    cp arch/arm64/boot/dts/intel/socfpga_agilex5_de25.dtb "${OUT}/socfpga_agilex5_de25.dtb"
popd >/dev/null

# ---- toybox initramfs ------------------------------------------------
if [[ ! -d toybox ]]; then git clone --depth 1 "${TOYBOX_REPO}" toybox; fi
pushd toybox >/dev/null
    make clean || true
    make defconfig
    mkroot/mkroot.sh
    gzip -dc root/aarch64/initramfs.cpio.gz > "${OUT}/initramfs.cpio"
popd >/dev/null

# ---- SD card image (FAT32: Image + dtb + itb + initramfs) ----------
cd "${OUT}"
rm -f sdcard.img
dd if=/dev/zero of=sdcard.img bs=1M count=96 status=none
mformat -i sdcard.img -F ::
mcopy -i sdcard.img u-boot.itb Image socfpga_agilex5_de25.dtb initramfs.cpio ::

echo
echo "==================================================================="
echo "  build_output/  ready:"
echo "    sdcard.img  Image  socfpga_agilex5_de25.dtb  u-boot.itb"
echo "    initramfs.cpio  bl31.bin  spl/u-boot-spl-dtb.hex"
echo
echo "  next:"
echo "  1. combine SPL + FPGA into a JIC (adjust -o device= to the board QSPI part):"
echo "       quartus_pfg -c ${SOF} de25_soc.jic \\"
echo "           -o device=MT25QU02G -o flash_loader=A5ED013BB32AE4SCS \\"
echo "           -o hps_path=${OUT}/spl/u-boot-spl-dtb.hex -o mode=ASX4 -o hps=1"
echo "  2. flash sdcard.img to the SD card, program the JIC, set MSEL for"
echo "     QSPI+HPS-first, power-cycle.  Console = HPS UART (CP2105) @115200."
echo "==================================================================="
