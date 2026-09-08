# ------------------------------------------------------------------------
# Quartus Prime Pro project script - DE25-Standard SoC bring-up
# Target board: Terasic DE25-Standard (Agilex 5 A5ED013BB32AE4SCS)
#
# Contents:
#   * hps_min      - Agilex 5 HPS + HPS-EMIF DDR4, EMAC0 / SD-MMC / UART1 /
#                    USB0 / I2C1 / SPIM0.  All FPGA<->HPS bridges disabled.
#   * de25_uart_top - the fabric UART + fpga_interconnect register block
#                    (unchanged), on GPIO_D[0]/[1].
#
# Prerequisites - generate the HPS/EMIF IP once (agilex_hps.ip already has
# the bridges disabled; hps_min.v is generated from the two *_inst.v):
#
#   qsys-generate hps/ip/hps_subsys/agilex_hps.ip   --synthesis=VHDL --part=A5ED013BB32AE4SCS
#   qsys-generate hps/ip/qsys_top/emif_io96b_hps.ip --synthesis=VHDL --part=A5ED013BB32AE4SCS
#   python3 hps/gen_hps_min.py
#
# Build:
#   quartus_sh  -t build_de25_soc.tcl
#   quartus_syn de25_soc
#   quartus_fit de25_soc
#   quartus_sta de25_soc
#   quartus_asm de25_soc
#
# NOTE: with the FPGA<->HPS bridges disabled this design does NOT match the
# stock Terasic GHRD Linux image - it needs its own device tree / bootloader
# handoff.
# ------------------------------------------------------------------------

package require ::quartus::project

variable this_file_path [file dirname [file normalize [info script]]]

set need_to_close_project 0
if {[is_project_open]} {
    if {[string compare $quartus(project) "de25_soc"]} { puts "Project de25_soc is not open"; exit 1 }
} else {
    if {[project_exists de25_soc]} {
        project_open -revision de25_soc de25_soc
    } else {
        project_new -revision de25_soc de25_soc
    }
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
set_global_assignment -name VERILOG_INPUT_VERSION SYSTEMVERILOG_2005
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

# ---------------------------------------------------------- fabric HDL
set_global_assignment -name VHDL_FILE $this_file_path/source/hVHDL_fpga_interconnect/fpga_interconnect_generic_pkg.vhd
set_global_assignment -name VHDL_FILE $this_file_path/source/fpga_communication/fpga_interconnect_16bit_pkg.vhd
set_global_assignment -name VHDL_FILE $this_file_path/source/hVHDL_uart/uart_rx/uart_rx_pkg.vhd
set_global_assignment -name VHDL_FILE $this_file_path/source/hVHDL_uart/uart_tx/uart_tx_pkg.vhd
set_global_assignment -name VHDL_FILE $this_file_path/source/fpga_communication/serial_protocol_generic_pkg.vhd
set_global_assignment -name VHDL_FILE $this_file_path/source/fpga_communication/communications.vhd
set_global_assignment -name VHDL_FILE $this_file_path/git_hash_pkg.vhd
set_global_assignment -name VHDL_FILE $this_file_path/de25_uart_top.vhd

# ---------------------------------------------------------- SoC HDL + IP
set_global_assignment -name VERILOG_FILE $this_file_path/hps/hps_min.v
set_global_assignment -name VERILOG_FILE $this_file_path/de25_soc_top.v
set_global_assignment -name QIP_FILE $this_file_path/hps/ip/hps_subsys/agilex_hps/agilex_hps.qip
set_global_assignment -name QIP_FILE $this_file_path/hps/ip/qsys_top/emif_io96b_hps/emif_io96b_hps.qip

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
set_location_assignment PIN_BK31  -to uart_rxd
set_location_assignment PIN_BE43  -to uart_txd

set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to CLOCK0_50
set_instance_assignment -name IO_STANDARD "1.2-V"        -to CPU_RESET_n
foreach p {KEY[0] KEY[1] KEY[2] KEY[3] SW[0] SW[1] SW[2] SW[3] SW[4] SW[5] SW[6] SW[7] SW[8] SW[9] \
           LEDR[0] LEDR[1] LEDR[2] LEDR[3] LEDR[4] LEDR[5] LEDR[6] LEDR[7] LEDR[8] LEDR[9]} {
    set_instance_assignment -name IO_STANDARD "1.2-V" -to $p
}
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to uart_rxd
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to uart_txd
set_instance_assignment -name CURRENT_STRENGTH_NEW 6MA    -to uart_txd

# ------------------------------------------------ HPS + DDR4 pins (GHRD)
# 123 pins x {location, IO_STANDARD}, incl. HPS_CLK_25 / DDR4_REFCLK_p / DDR4_RZQ
source $this_file_path/hps/hps_ddr4_pins.tcl

# --------------------------------------------------------------- commit
export_assignments
if {$need_to_close_project} { project_close }
