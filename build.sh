#!/usr/bin/env bash
# build.sh - every build of this repo, out of tree under build/.
#
#   ./build.sh fpga-project   create or refresh the Quartus project in build/fpga
#   ./build.sh fpga           ... and compile it -> build/fpga/output_files/de25_soc.sof
#                             (HPS-first; FPGA_FIRST=1: an FPGA-first image)
#   ./build.sh linux          ATF + U-Boot + kernel (linux/build_de25_linux.sh)
#   ./build.sh jic            QSPI image -> build/images/de25_std.jic
#   ./build.sh sdcard         SD card image -> build/images/sdcard.img.gz
#   ./build.sh all            fpga, linux, jic, sdcard
#
# Env: BUILD_DIR (default build/), QUARTUS_BIN.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BUILD_DIR="${BUILD_DIR:-${ROOT}/build}"
QUARTUS_BIN="${QUARTUS_BIN:-$HOME/altera_pro/26.1.1/quartus/bin}"
export PATH="${QUARTUS_BIN}:${PATH}"
FPGA_DIR="${BUILD_DIR}/fpga"

fpga_project() {
    mkdir -p "${FPGA_DIR}"
    (cd "${FPGA_DIR}" && quartus_sh -t "${ROOT}/fpga/build_de25_soc.tcl")
}

fpga() {
    fpga_project
    (
        cd "${FPGA_DIR}"
        "${ROOT}/tools/write_build_id.sh" "${FPGA_DIR}"
        quartus_ipgenerate de25_soc -c de25_soc
        quartus_syn de25_soc
        quartus_fit de25_soc
        quartus_sta de25_soc
        quartus_asm de25_soc
    )
}

linux() { "${ROOT}/linux/build_de25_linux.sh"; }

jic() { "${ROOT}/linux/make_jic.sh"; }

sdcard() { "${ROOT}/linux/tools/make_sdcard_image.sh"; }

case "${1:-}" in
    fpga-project) fpga_project ;;
    fpga)         fpga ;;
    linux)        linux ;;
    jic)          jic ;;
    sdcard)       sdcard ;;
    all)          fpga; linux; jic; sdcard ;;
    *)            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
