#!/usr/bin/env bash
# ============================================================================
# DE25-Standard boot stack, all from Altera upstream plus this repo's board
# files (no Terasic forks):
#   altera-fpga/arm-trusted-firmware @ socfpga_v2.14.1     BL31
#   altera-fpga/u-boot-socfpga       @ socfpga_v2026.04    SPL + U-Boot proper
#   altera-fpga/linux-socfpga        @ socfpga-6.18.20-lts Image + dtb
# Neither upstream tree has a DE25-Standard board, so the build copies in
#   linux/uboot/socfpga_agilex5_de25_std{.dts,-u-boot.dtsi,_defconfig}
#   linux/dts/socfpga_agilex5_de25_std.dts
# (docs/plan_upstream_hps_first_webgui.md, Phase A).
#
# Out of tree (./build.sh linux):
#   ${BUILD_DIR}/linux/src/   clones, kept between builds; every run resets
#                             them (git checkout -- .) and re-applies the patches
#   ${BUILD_DIR}/linux/out/   bl31.bin  u-boot.itb  spl/u-boot-spl-dtb.hex
#                             Image  socfpga_agilex5_de25_std.dtb
#   ${BUILD_DIR}/toolchain/   ARM GNU aarch64 toolchain, unless CROSS_TOOLCHAIN
#
# Next: ./build.sh jic (SPL + U-Boot + bitstream -> QSPI), and
# linux/tools/make_sdcard_image.sh (Alpine SD card image).
#
# REQUIREMENTS: Linux host, internet, ~10 GB free, and:
#   git wget xz-utils bc bison flex libssl-dev python3 dtc
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-${HERE}/../build}"
mkdir -p "${BUILD_DIR}"
BUILD_DIR="$(cd "${BUILD_DIR}" && pwd)"
SRC="${BUILD_DIR}/linux/src"
OUT="${BUILD_DIR}/linux/out"
JOBS="$(nproc)"

ATF_REPO="https://github.com/altera-fpga/arm-trusted-firmware"
ATF_BRANCH="socfpga_v2.14.1"
UBOOT_REPO="https://github.com/altera-fpga/u-boot-socfpga"
UBOOT_BRANCH="socfpga_v2026.04"
LINUX_REPO="https://github.com/altera-fpga/linux-socfpga"
LINUX_BRANCH="socfpga-6.18.20-lts"
BOARD="socfpga_agilex5_de25_std"
LINUX_DTB="${BOARD}.dtb"
# where U-Boot proper sits in the 16 MB QSPI flash (the SPL's
# CONFIG_SYS_SPI_U_BOOT_OFFS, checked below; make_jic.sh uses the same)
QSPI_UBOOT_OFFS="${QSPI_UBOOT_OFFS:-0x00A00000}"
# where an HPS-first image's FPGA core sits in QSPI (U-Boot's preboot loads
# it from there when the SD card has none; make_jic.sh uses the same)
QSPI_CORE_OFFS="${QSPI_CORE_OFFS:-0x00C00000}"
CORE_NAME="de25_std.core.rbf"

# ARM GNU aarch64-linux toolchain (has the LTO plugin ATF's release build
# needs). CROSS_TOOLCHAIN= a dir with bin/aarch64-none-linux-gnu-gcc skips
# the download.
TOOLCHAIN_URL="https://developer.arm.com/-/media/Files/downloads/gnu/11.2-2022.02/binrel/gcc-arm-11.2-2022.02-x86_64-aarch64-none-linux-gnu.tar.xz"
TOOLCHAIN_DIR="gcc-arm-11.2-2022.02-x86_64-aarch64-none-linux-gnu"
CROSS_PREFIX="aarch64-none-linux-gnu-"

mkdir -p "${SRC}" "${OUT}/spl" "${BUILD_DIR}/toolchain"
export ARCH=arm64

# ---- toolchain -----------------------------------------------------------
if [[ -n "${CROSS_TOOLCHAIN:-}" ]]; then
    [[ -x "${CROSS_TOOLCHAIN}/bin/${CROSS_PREFIX}gcc" ]] || {
        echo "ERROR: no ${CROSS_PREFIX}gcc in CROSS_TOOLCHAIN=${CROSS_TOOLCHAIN}/bin"; exit 1; }
    TC_BIN="${CROSS_TOOLCHAIN}/bin"
else
    TC_BIN="${BUILD_DIR}/toolchain/${TOOLCHAIN_DIR}/bin"
    if [[ ! -x "${TC_BIN}/${CROSS_PREFIX}gcc" ]]; then
        echo ">> fetching toolchain"
        wget -q --show-progress -O "${BUILD_DIR}/toolchain/tc.tar.xz" "${TOOLCHAIN_URL}"
        tar -xf "${BUILD_DIR}/toolchain/tc.tar.xz" -C "${BUILD_DIR}/toolchain"
        rm "${BUILD_DIR}/toolchain/tc.tar.xz"
    fi
fi
export PATH="${TC_BIN}:${PATH}"
export CROSS_COMPILE="${CROSS_PREFIX}"
echo ">> toolchain: $(command -v ${CROSS_PREFIX}gcc)  ($(${CROSS_PREFIX}gcc -dumpversion))"

clone() {   # repo branch dir
    [[ -d "${SRC}/$3" ]] || git clone --depth 1 -b "$2" "$1" "${SRC}/$3"
    git -C "${SRC}/$3" checkout -- .
}

# ---- ARM Trusted Firmware ------------------------------------------------
clone "${ATF_REPO}" "${ATF_BRANCH}" atf-altera
pushd "${SRC}/atf-altera" >/dev/null
    # Upstream hardcodes config_ddr_size = 0x80000000 (2 GB): BL2/SPL's DDR
    # size check then hangs on this 1 GB board ("Configured DDR size is
    # greater than the hardware size - HANG"). Use the detected size.
    sed -i 's/config_ddr_size = 0x80000000;/config_ddr_size = hw_ddr_size;/' \
        plat/intel/soc/agilex5/soc/agilex5_ddr.c
    grep -q 'config_ddr_size = hw_ddr_size;' plat/intel/soc/agilex5/soc/agilex5_ddr.c || {
        echo "ERROR: DDR-size patch didn't apply - agilex5_ddr.c changed, check by hand"; exit 1; }
    # SOCFPGA_UART_CONFIG=1: console on UART1, this board's
    make PLAT=agilex5 clean >/dev/null
    make -j"${JOBS}" CROSS_COMPILE="${CROSS_PREFIX}" PLAT=agilex5 ENABLE_LTO=0 SOCFPGA_UART_CONFIG=1 bl31
    cp build/agilex5/release/bl31.bin "${OUT}/bl31.bin"
popd >/dev/null

# ---- U-Boot --------------------------------------------------------------
clone "${UBOOT_REPO}" "${UBOOT_BRANCH}" u-boot-altera
pushd "${SRC}/u-boot-altera" >/dev/null
    # Single-port IO96B EMIF, not the dual-port bit from the hand-off data
    # (Terasic's de25-standard-v2025.01 makes exactly this change).
    sed -i 's|^\(\s*\)plat->dualport = FIELD_GET(IO96B0_DUAL_PORT_MASK, handoff_table\[PORT_EMIF_CONFIG_OFFSET\]);|\1plat->dualport = 0;  /* DE25-Standard: single port (Terasic) */|' \
        drivers/ddr/altera/sdram_agilex5.c
    grep -q 'plat->dualport = 0;  /\* DE25-Standard' drivers/ddr/altera/sdram_agilex5.c || {
        echo "ERROR: the dual-port DDR patch didn't apply - sdram_agilex5.c changed, check by hand"; exit 1; }
    # the board: DT, U-Boot dtsi, defconfig
    cp "${HERE}/uboot/${BOARD}.dts" "${HERE}/uboot/${BOARD}-u-boot.dtsi" arch/arm/dts/
    cp "${HERE}/uboot/${BOARD}_defconfig" configs/
    grep -q "${BOARD}.dtb" arch/arm/dts/Makefile ||
        sed -i "s|^\(\s*\)socfpga_agilex5_de25_nano.dtb\s*\\\\|&\n\1${BOARD}.dtb \\\\|" arch/arm/dts/Makefile
    grep -q "${BOARD}.dtb" arch/arm/dts/Makefile || {
        echo "ERROR: ${BOARD}.dtb not added to arch/arm/dts/Makefile - check by hand"; exit 1; }
    ln -sf "${OUT}/bl31.bin" bl31.bin
    make mrproper
    make "${BOARD}_defconfig"
    # Release the HPS<->FPGA bridges before Linux: upstream U-Boot leaves
    # them in reset (rstmgr brgmodrst = 0xf) and the first LWH2F access from
    # Linux is a SIGBUS. `bridge enable` refuses when the fabric is not
    # configured.
    scripts/config --set-str CONFIG_BOOTCOMMAND "bridge enable; run distro_bootcmd"
    # HPS-first images (HPS_FIRST=1 ./build.sh fpga): the SDM leaves the
    # FPGA core unconfigured; load it before anything else. Skipped when the
    # fabric is configured already (FPGA-first image, JTAG .sof, software
    # reboot): sysmgr FPGA_CONFIG (0x10d120dc) reads 3. From the SD card's
    # FAT partition, else from the QSPI copy make_jic.sh writes at
    # QSPI_CORE_OFFS (a 4 KB "core_size=0x..." header for `env import`, the
    # core right after it). A card core that reads but does not load falls
    # back to the QSPI copy too.
    scripts/config --enable CONFIG_USE_PREBOOT
    scripts/config --set-str CONFIG_PREBOOT "if itest.l *0x10d120dc != 3; then if load mmc 0:1 \${loadaddr} ${CORE_NAME} && fpga load 0 \${loadaddr} \${filesize}; then echo core from SD; else sf probe && sf read \${loadaddr} $(printf '%#x' "${QSPI_CORE_OFFS}") 0x1000 && env import -t \${loadaddr} && sf read \${loadaddr} $(printf '%#x' $(( QSPI_CORE_OFFS + 0x1000 ))) \${core_size} && fpga load 0 \${loadaddr} \${core_size} && echo core from QSPI; fi; fi"
    make olddefconfig
    grep -q '^CONFIG_BOOTCOMMAND="bridge enable; run distro_bootcmd"$' .config || {
        echo "ERROR: CONFIG_BOOTCOMMAND not set"; exit 1; }
    grep -q '^CONFIG_PREBOOT="if itest.l \*0x10d120dc != 3; then' .config || {
        echo "ERROR: CONFIG_PREBOOT not set"; exit 1; }
    grep -q "^CONFIG_DEFAULT_DEVICE_TREE=\"${BOARD}\"$" .config || {
        echo "ERROR: CONFIG_DEFAULT_DEVICE_TREE is not ${BOARD}"; exit 1; }
    # U-Boot proper from QSPI as well as from the SD card, so a blank or
    # broken card still reaches a U-Boot prompt (linux/tools/sd_recover.py)
    got="$(sed -n 's/^CONFIG_SYS_SPI_U_BOOT_OFFS=//p' .config)"
    [[ -n "${got}" ]] && (( got == QSPI_UBOOT_OFFS )) || {
        echo "ERROR: CONFIG_SYS_SPI_U_BOOT_OFFS is '${got}', make_jic.sh expects ${QSPI_UBOOT_OFFS}"; exit 1; }
    make -j"${JOBS}"
    cp u-boot.itb             "${OUT}/u-boot.itb"
    cp spl/u-boot-spl-dtb.hex "${OUT}/spl/u-boot-spl-dtb.hex"
popd >/dev/null

# ---- Linux kernel --------------------------------------------------------
clone "${LINUX_REPO}" "${LINUX_BRANCH}" linux-altera
pushd "${SRC}/linux-altera" >/dev/null
    cp "${HERE}/dts/${BOARD}.dts" arch/arm64/boot/dts/intel/
    grep -q "${LINUX_DTB}" arch/arm64/boot/dts/intel/Makefile ||
        echo "dtb-\$(CONFIG_ARCH_INTEL_SOCFPGA) += ${LINUX_DTB}" >> arch/arm64/boot/dts/intel/Makefile
    make defconfig
    # Built in, because the rootfs carries no modules:
    #   SENSORS_SOC64            SoC temperatures/voltages (web GUI, fan loop)
    #   FPGA_MGR_STRATIX10_SOC, FPGA_BRIDGE, FPGA_REGION, OF_FPGA_REGION
    #                            FPGA core reload from Linux (fpga-reload)
    #   INTEL_STRATIX10_RSU      remote system update (later)
    #   RTC_DRV_PCF85363         the board's PCF85263A RTC on I2C1
    for c in SENSORS_SOC64 FPGA_MGR_STRATIX10_SOC FPGA_BRIDGE FPGA_REGION OF_FPGA_REGION \
             INTEL_STRATIX10_RSU RTC_DRV_PCF85363; do
        scripts/config --enable "CONFIG_${c}"
    done
    make olddefconfig
    for c in SENSORS_SOC64 FPGA_MGR_STRATIX10_SOC FPGA_BRIDGE FPGA_REGION OF_FPGA_REGION \
             OF_OVERLAY OF_CONFIGFS INTEL_STRATIX10_RSU RTC_DRV_PCF85363; do
        grep -q "^CONFIG_${c}=y$" .config || { echo "ERROR: CONFIG_${c} not built in"; exit 1; }
    done
    make -j"${JOBS}" Image "intel/${LINUX_DTB}"
    cp arch/arm64/boot/Image                    "${OUT}/Image"
    cp "arch/arm64/boot/dts/intel/${LINUX_DTB}" "${OUT}/${LINUX_DTB}"
popd >/dev/null

echo
echo "==================================================================="
echo "  ${OUT}:"
echo "    bl31.bin  u-boot.itb  spl/u-boot-spl-dtb.hex  Image  ${LINUX_DTB}"
echo
echo "  next: ./build.sh jic                    # -> build/images/de25_std.jic"
echo "        linux/tools/make_sdcard_image.sh  # -> build/images/sdcard.img"
echo "==================================================================="
