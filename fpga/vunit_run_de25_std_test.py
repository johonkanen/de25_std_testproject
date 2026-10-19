#!/usr/bin/env python3
"""
vunit_run_de25_std_test.py - VUnit test runner for the DE25-Standard's
fabric (adapted from the DE25-Nano's vunit_run_de25_nano_test.py).

Compiles every fabric source (the top level included, so a port mismatch
shows here before Quartus) and runs the testbenches in fpga/sim/ with nvc.
Output goes to ${BUILD_DIR:-build}/sim/ (git_hash_pkg.vhd and
build_id_pkg.vhd are generated there too). Needs vunit_hdl
(pip install vunit_hdl) and nvc >= 1.14 on PATH.

    ./build.sh sim                                      # run everything
    python3 fpga/vunit_run_de25_std_test.py -v           # verbose output
    python3 fpga/vunit_run_de25_std_test.py --list        # list test cases
    python3 fpga/vunit_run_de25_std_test.py de25_std_lib.hex_display_tb.all

Keep the source list in step with fpga/build_de25_soc.tcl (the HPS
subsystem itself is not simulated: de25_soc_top.vhd declares it as a
component and is only analysed).
"""

import os
import subprocess
import sys
from pathlib import Path

from vunit import VUnit

FPGA = Path(__file__).resolve().parent
TOP = FPGA.parent
SIM_OUT = Path(os.environ.get("BUILD_DIR") or TOP / "build") / "sim"
SIM_OUT.mkdir(parents=True, exist_ok=True)

# generated packages, as the Quartus build makes them in build/fpga
subprocess.run([str(TOP / "tools/write_githash.sh"), str(SIM_OUT)], check=True,
               stdout=subprocess.DEVNULL)
subprocess.run([str(TOP / "tools/write_build_id.sh"), str(SIM_OUT)], check=True,
               stdout=subprocess.DEVNULL)

if not any(a == "-o" or a.startswith("--output-path") for a in sys.argv[1:]):
    sys.argv[1:1] = ["--output-path", str(SIM_OUT / "vunit_out")]

VU = VUnit.from_argv(vhdl_standard="2019")
lib = VU.add_library("de25_std_lib")

S = FPGA / "source"
for f in [
    S / "hVHDL_fpga_interconnect/fpga_interconnect_generic_pkg.vhd",
    S / "fpga_communication/fpga_interconnect_16bit_pkg.vhd",
    SIM_OUT / "git_hash_pkg.vhd",
    SIM_OUT / "build_id_pkg.vhd",
    FPGA / "axi_lwh2f_bridge.vhd",
    S / "fan_control/i2c_master_pkg.vhd",
    S / "fan_control/max6650_fan_control.vhd",
    S / "blinkers/blinker_pkg.vhd",
    S / "blinkers/blinker_counter.vhd",
    S / "blinkers/blinker_scanner.vhd",
    S / "blinkers/blinker_breathing.vhd",
    S / "blinkers/blinker_sparkle.vhd",
    S / "blinkers/blinker_slot.vhd",
    S / "led_blinkers.vhd",
    S / "hex_display.vhd",
    FPGA / "register_block.vhd",
    FPGA / "h2f_user0_clk_heartbeat.vhd",
    FPGA / "de25_soc_top.vhd",
    FPGA / "sim/led_blinkers_tb.vhd",
    FPGA / "sim/hex_display_tb.vhd",
]:
    lib.add_source_files(f)

# register_block names work.git_hash_pkg / work.build_id_pkg without a use
# clause, which VUnit's dependency scan does not see
regs = lib.get_source_file(str(FPGA / "register_block.vhd"))
for pkg in ("git_hash_pkg.vhd", "build_id_pkg.vhd"):
    regs.add_dependency_on(lib.get_source_file(str(SIM_OUT / pkg)))

VU.main()
