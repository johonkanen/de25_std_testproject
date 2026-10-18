# ------------------------------------------------------------------------
# Quartus Prime Pro project script - DE25-Standard SoC bring-up
# Target board: Terasic DE25-Standard (Agilex 5 A5ED013BB32AE4SCS)
#
# Contents:
#   * hps_subsystem - Agilex 5 HPS + HPS-EMIF DDR4, EMAC0 / SD-MMC / UART1 /
#                    I2C1.  H2F / F2SDRAM / F2H(ACE5-Lite) disabled; LWH2F
#                    (lightweight bridge) and the F2H interrupts stay
#                    enabled.  Platform Designer system:
#                    hps/hps_subsystem.qsys + hps/ip/hps_subsystem/*.ip.
#                    See hps/README.md.
#   * register_block - the fpga_interconnect register file, reachable
#                    over the HPS's LWH2F, via axi_lwh2f_bridge.vhd.
#
# Out of tree: run from a build directory, never from the source tree.
# The script copies hps/ (.qsys + .ip) there, because Quartus generates IP
# next to the .qsys/.ip file, and writes git_hash_pkg.vhd and
# build_id_pkg.vhd there.
# PROJECT_IP_REGENERATION_POLICY does not generate IP on a fresh tree, so
# quartus_ipgenerate is needed before synthesis.
#
# Build (or just ./build.sh fpga from the repo root):
#   mkdir -p build/fpga && cd build/fpga
#   quartus_sh  -t ../../fpga/build_de25_soc.tcl
#   quartus_ipgenerate de25_soc -c de25_soc
#   quartus_syn de25_soc
#   quartus_fit de25_soc
#   quartus_sta de25_soc
#   quartus_asm de25_soc
#
# NOTE: this does NOT match the stock Terasic GHRD Linux image (different
# HPS pin mux / no OCM / no debug bridges) - it needs its own device tree /
# bootloader handoff.
# ------------------------------------------------------------------------

package require ::quartus::project

variable this_file_path [file dirname [file normalize [info script]]]
set repo_root [file dirname $this_file_path]
set build_dir [file normalize [pwd]]

if {$build_dir eq $repo_root || [string first "$this_file_path/" "$build_dir/"] == 0} {
    puts "ERROR: run from a build directory (./build.sh fpga), not from the source tree"
    exit 1
}

# Quartus generates IP next to the .qsys/.ip file: build from a copy.
# Edit the originals in fpga/hps/.
file mkdir hps/ip/hps_subsystem
file copy -force $this_file_path/hps/hps_subsystem.qsys hps/
foreach ip [glob -directory $this_file_path/hps/ip/hps_subsystem *.ip] {
    file copy -force $ip hps/ip/hps_subsystem/
}
exec $repo_root/tools/write_githash.sh $build_dir
# build id, register 19 (build.sh stamps a new one before every quartus_syn)
if {![file exists build_id_pkg.vhd]} {
    exec $repo_root/tools/write_build_id.sh $build_dir
}

set need_to_close_project 0
if {[is_project_open]} {
    if {[string compare $quartus(project) "de25_soc"]} { puts "Project de25_soc is not open"; exit 1 }
} else {
    # Always start from an empty .qsf: reopening an existing project only
    # adds assignments, so removed files and pins would stay in it.
    project_new -overwrite -revision de25_soc de25_soc
    set need_to_close_project 1
}

# ---------------------------------------------------------------- device
set_global_assignment -name FAMILY "Agilex 5"
set_global_assignment -name DEVICE A5ED013BB32AE4SCS
set_global_assignment -name DEVICE_FILTER_PACKAGE VPBGA
set_global_assignment -name TOP_LEVEL_ENTITY de25_soc_top
set_global_assignment -name ORIGINAL_QUARTUS_VERSION 25.1.0
set_global_assignment -name LAST_QUARTUS_VERSION "26.1.1 Pro Edition"
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name VHDL_INPUT_VERSION VHDL_2019
set_global_assignment -name OPTIMIZATION_MODE BALANCED
set_global_assignment -name BOARD default

# DE25-Standard configuration scheme (from the GHRD golden_top)
set_global_assignment -name USE_CONF_DONE SDM_IO16
set_global_assignment -name USE_HPS_COLD_RESET SDM_IO11
set_global_assignment -name USE_INIT_DONE SDM_IO13
set_global_assignment -name STRATIXV_CONFIGURATION_SCHEME "ACTIVE SERIAL X4"
set_global_assignment -name ACTIVE_SERIAL_CLOCK AS_FREQ_100MHZ
set_global_assignment -name DEVICE_INITIALIZATION_CLOCK OSC_CLK_1_125MHZ
set_global_assignment -name HPS_DAP_NO_CERTIFICATE on
set_global_assignment -name HPS_DAP_SPLIT_MODE DISABLED
set_global_assignment -name PWRMGT_VOLTAGE_OUTPUT_FORMAT "LINEAR FORMAT"
set_global_assignment -name PWRMGT_LINEAR_FORMAT_N "-12"
set_global_assignment -name POWER_APPLY_THERMAL_MARGIN ADDITIONAL

# QSPI belongs to the HPS: the SPL and U-Boot read U-Boot proper (and, for
# HPS-first images, the FPGA core) from it. With SDM ownership the SPL's
# first QSPI-controller access stalls the bus (seen on the DE25-Nano).
set_global_assignment -name QSPI_OWNERSHIP HPS
#
# HPS_FIRST=1 (environment): "HPS FIRST" - the SDM configures only the HPS
# I/O, DDR I/O and the SPL; U-Boot's preboot loads the FPGA core
# (de25_std.core.rbf, from linux/make_jic.sh). Default for now: "AFTER
# INIT_DONE", the whole FPGA before the HPS starts (plan Phase A; Phase B
# makes HPS-first the default).
if {[info exists ::env(HPS_FIRST)] && $::env(HPS_FIRST) == 1} {
    set_global_assignment -name HPS_INITIALIZATION "HPS FIRST"
} else {
    set_global_assignment -name HPS_INITIALIZATION "AFTER INIT_DONE"
}

# ---------------------------------------------------------- fabric HDL
set_global_assignment -name VHDL_FILE $this_file_path/source/hVHDL_fpga_interconnect/fpga_interconnect_generic_pkg.vhd
set_global_assignment -name VHDL_FILE $this_file_path/source/fpga_communication/fpga_interconnect_16bit_pkg.vhd
set_global_assignment -name VHDL_FILE git_hash_pkg.vhd
set_global_assignment -name VHDL_FILE build_id_pkg.vhd
set_global_assignment -name VHDL_FILE $this_file_path/axi_lwh2f_bridge.vhd

# MAX6650 fan controller (see source/fan_control/)
set_global_assignment -name VHDL_FILE $this_file_path/source/fan_control/i2c_master_pkg.vhd
set_global_assignment -name VHDL_FILE $this_file_path/source/fan_control/max6650_fan_control.vhd

set_global_assignment -name VHDL_FILE $this_file_path/register_block.vhd
set_global_assignment -name VHDL_FILE $this_file_path/h2f_user0_clk_heartbeat.vhd
set_global_assignment -name VHDL_FILE $this_file_path/de25_soc_top.vhd

# ---------------------------------------------------------- SoC HDL + IP
set_global_assignment -name QSYS_FILE hps/hps_subsystem.qsys
set_global_assignment -name IP_FILE hps/ip/hps_subsystem/hps_subsystem_intel_agilex_5_soc_0.ip
set_global_assignment -name IP_FILE hps/ip/hps_subsystem/hps_subsystem_emif_io96b_hps_0.ip
set_global_assignment -name IP_FILE hps/ip/hps_subsystem/hps_subsystem_s10_user_rst_clkgate_0.ip
set_global_assignment -name PROJECT_IP_REGENERATION_POLICY ALWAYS_REGENERATE_IP

# ---------------------------------------------------------- constraints
set_global_assignment -name SDC_FILE $this_file_path/de25_soc.sdc

# ------------------------------------------------------------ fabric pins
set_location_assignment PIN_CH128 -to CLOCK0_50
set_location_assignment PIN_BM78  -to CPU_RESET_n
set_location_assignment PIN_BW59  -to KEY[0]
set_location_assignment PIN_CA59  -to KEY[1]
set_location_assignment PIN_CF71  -to KEY[2]
set_location_assignment PIN_CH71  -to KEY[3]
set_location_assignment PIN_BM62  -to SW[0]
set_location_assignment PIN_BP62  -to SW[1]
set_location_assignment PIN_BH62  -to SW[2]
set_location_assignment PIN_BH59  -to SW[3]
set_location_assignment PIN_BM59  -to SW[4]
set_location_assignment PIN_BK59  -to SW[5]
set_location_assignment PIN_BU62  -to SW[6]
set_location_assignment PIN_CF59  -to SW[7]
set_location_assignment PIN_BU59  -to SW[8]
set_location_assignment PIN_BR59  -to SW[9]
set_location_assignment PIN_CC71  -to LEDR[0]
set_location_assignment PIN_BH78  -to LEDR[1]
set_location_assignment PIN_CH69  -to LEDR[2]
set_location_assignment PIN_CF69  -to LEDR[3]
set_location_assignment PIN_CA62  -to LEDR[4]
set_location_assignment PIN_CC62  -to LEDR[5]
set_location_assignment PIN_CF62  -to LEDR[6]
set_location_assignment PIN_BM69  -to LEDR[7]
set_location_assignment PIN_CA71  -to LEDR[8]
set_location_assignment PIN_BR62  -to LEDR[9]

# H2F User0 clock heartbeat test - GPIO_D[2] (see docs/de25_pinout.md and
# h2f_user0_clk_heartbeat.vhd), from Demonstration/FPGA/golden_top/golden_top.qsf
set_location_assignment PIN_BF29  -to H2F_CLK_TEST

# MAX6650 fan controller I2C bus (from Demonstration/SoC_FPGA/GHRD/golden_top.qsf)
set_location_assignment PIN_BF120 -to FPGA_I2C_SCL
set_location_assignment PIN_BH118 -to FPGA_I2C_SDA

set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to CLOCK0_50
set_instance_assignment -name IO_STANDARD "1.2-V"        -to CPU_RESET_n
foreach p {KEY[0] KEY[1] KEY[2] KEY[3] SW[0] SW[1] SW[2] SW[3] SW[4] SW[5] SW[6] SW[7] SW[8] SW[9] \
           LEDR[0] LEDR[1] LEDR[2] LEDR[3] LEDR[4] LEDR[5] LEDR[6] LEDR[7] LEDR[8] LEDR[9]} {
    set_instance_assignment -name IO_STANDARD "1.2-V" -to $p
}
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to H2F_CLK_TEST
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to FPGA_I2C_SCL
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to FPGA_I2C_SDA

# ------------------------------------------------ HPS + DDR4 pins (GHRD)
# 100 pins x {location, IO_STANDARD} for the peripherals this pin mux
# actually drives (EMAC0, SD/MMC, UART1, I2C1, DDR4) - no USB0/SPIM0/LCM.
source $this_file_path/hps/hps_pins.tcl

# --------------------------------------------------------------- commit
export_assignments
if {$need_to_close_project} { project_close }
