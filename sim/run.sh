#!/usr/bin/env bash
# Compile and run the register-interface testbench with nvc (>= 1.14).
#   sudo apt install nvc     # or build from https://github.com/nickg/nvc
set -euo pipefail
cd "$(dirname "$0")"

ROOT=..
SRC=(
    "$ROOT/source/hVHDL_fpga_interconnect/fpga_interconnect_generic_pkg.vhd"
    "$ROOT/source/fpga_communication/fpga_interconnect_16bit_pkg.vhd"
    "$ROOT/source/hVHDL_uart/uart_rx/uart_rx_pkg.vhd"
    "$ROOT/source/hVHDL_uart/uart_tx/uart_tx_pkg.vhd"
    "$ROOT/source/fpga_communication/serial_protocol_generic_pkg.vhd"
    "$ROOT/source/fpga_communication/communications.vhd"
    "$ROOT/git_hash_pkg.vhd"
    "$ROOT/de25_uart_top.vhd"
    "de25_uart_top_tb.vhd"
)

nvc --std=2019 --work=work -a "${SRC[@]}"
nvc --std=2019 --work=work -e de25_uart_top_tb
nvc --std=2019 --work=work -r de25_uart_top_tb --stop-time=5ms
