#!/usr/bin/env bash
# Combine the FPGA bitstream + U-Boot SPL into a QSPI flash image (.jic)
# for the DE25-Standard.  Run linux/build_de25_linux.sh first (for the SPL)
# and build de25_soc.sof (quartus_syn/fit/asm) at the repo root.
#
#   ./linux/make_jic.sh
#
# The SPL boots from QSPI, then loads u-boot.itb / Image / dtb / initramfs
# from the SD card (sdcard.img), so only SPL+bitstream go in the .jic.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOF="${SOF:-${HERE}/../output_files/de25_soc.sof}"
SPL="${SPL:-${HERE}/build_output/spl/u-boot-spl-dtb.hex}"
JIC="${JIC:-${HERE}/build_output/de25_soc.jic}"

# DE25-Standard: Micron MT25QU512 QSPI flash, device A5ED013BB32AE4SCS
DEVICE="${DEVICE:-MT25QU512}"
FLASH_LOADER="${FLASH_LOADER:-A5ED013BB32AE4SCS}"

[[ -f "${SOF}" ]] || { echo "missing ${SOF} - build the FPGA first"; exit 1; }
[[ -f "${SPL}" ]] || { echo "missing ${SPL} - run build_de25_linux.sh first"; exit 1; }

quartus_pfg -c "${SOF}" "${JIC}" \
    -o hps_path="${SPL}" \
    -o device="${DEVICE}" \
    -o flash_loader="${FLASH_LOADER}" \
    -o mode=ASX4

echo
echo "wrote ${JIC}"
echo
echo "program it (needs the board on JTAG; on WSL2 forward the USB-Blaster II"
echo "with usbipd first - see ../program.sh):"
echo "    quartus_pgm -c 1 -m jtag -o \"pvi;${JIC}\""
echo "then set MSEL for QSPI + HPS-first and power-cycle."
