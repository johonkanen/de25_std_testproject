# ------------------------------------------------------------------------
# Quartus Prime Pro project script - minimal UART bring-up build
# Target board: Terasic DE25-Standard (Agilex 5 A5ED013BB32AE4SCS)
#
# Scope: fpga_communication UART block + an fpga_interconnect register file.
# Everything runs on the 50 MHz board clock - no PLL, no DSP, no processors.
#
# VHDL sources live under source/ : hVHDL_uart and hVHDL_fpga_interconnect
# are submodules; the three fpga_communication glue files are vendored
# (see source/fpga_communication/README.md).
#
# First checkout:
#     git submodule update --init
#
# Build (run every command from this directory):
#     quartus_sh  -t build_de25_uart.tcl
#     quartus_syn de25_uart
#     quartus_fit de25_uart
#     quartus_sta de25_uart
#     quartus_asm de25_uart
#
# Program (cable INDEX, JTAG device @1 - see program.sh / jtagconfig):
#     quartus_pgm -c 1 -m jtag -o "p;output_files/de25_uart.sof@1"
#
# Talk to it (50e6 / 434 ~= 115200 baud, 32-bit data words):
#     python test_uart.py /dev/ttyUSB0 115200
#     >>> Uart(...).read(1)   # -> 0x0000DE25
# ------------------------------------------------------------------------

package require ::quartus::project

variable this_file_path [file dirname [file normalize [info script]]]

set need_to_close_project 0

if {[is_project_open]} {
    if {[string compare $quartus(project) "de25_uart"]} {
        puts "Project de25_uart is not open"
        exit 1
    }
} else {
    if {[project_exists de25_uart]} {
        project_open -revision de25_uart de25_uart
    } else {
        project_new -revision de25_uart de25_uart
    }
    set need_to_close_project 1
}

# ---------------------------------------------------------------- device
set_global_assignment -name FAMILY "Agilex 5"
set_global_assignment -name DEVICE A5ED013BB32AE4SCS
set_global_assignment -name DEVICE_FILTER_PACKAGE VPBGA
set_global_assignment -name TOP_LEVEL_ENTITY de25_uart_top
set_global_assignment -name ORIGINAL_QUARTUS_VERSION 25.1.0
set_global_assignment -name LAST_QUARTUS_VERSION "26.1.1 Pro Edition"
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name VHDL_INPUT_VERSION VHDL_2019
set_global_assignment -name OPTIMIZATION_MODE BALANCED
set_global_assignment -name BOARD default

# DE25-Standard configuration scheme (matches the Terasic golden top)
set_global_assignment -name USE_CONF_DONE SDM_IO16
set_global_assignment -name USE_HPS_COLD_RESET SDM_IO11
set_global_assignment -name USE_INIT_DONE SDM_IO13
set_global_assignment -name STRATIXV_CONFIGURATION_SCHEME "ACTIVE SERIAL X4"
set_global_assignment -name ACTIVE_SERIAL_CLOCK AS_FREQ_100MHZ
set_global_assignment -name DEVICE_INITIALIZATION_CLOCK OSC_CLK_1_125MHZ

# ------------------------------------------------------------ source set
# fpga_interconnect protocol (generic package + 32 data / 16 address instance)
set_global_assignment -name VHDL_FILE $this_file_path/source/hVHDL_fpga_interconnect/fpga_interconnect_generic_pkg.vhd
set_global_assignment -name VHDL_FILE $this_file_path/source/fpga_communication/fpga_interconnect_16bit_pkg.vhd

# uart rx / tx (entity + package in the same file) and the serial protocol
set_global_assignment -name VHDL_FILE $this_file_path/source/hVHDL_uart/uart_rx/uart_rx_pkg.vhd
set_global_assignment -name VHDL_FILE $this_file_path/source/hVHDL_uart/uart_tx/uart_tx_pkg.vhd
set_global_assignment -name VHDL_FILE $this_file_path/source/fpga_communication/serial_protocol_generic_pkg.vhd
set_global_assignment -name VHDL_FILE $this_file_path/source/fpga_communication/communications.vhd

# git hash constant (refresh with ./write_githash.sh)
set_global_assignment -name VHDL_FILE $this_file_path/git_hash_pkg.vhd

# bring-up top level
set_global_assignment -name VHDL_FILE $this_file_path/de25_uart_top.vhd

# ---------------------------------------------------------- constraints
set_global_assignment -name SDC_FILE $this_file_path/de25_uart.sdc

# ------------------------------------------------------------------ pins
# from Demonstration/FPGA/golden_top/golden_top.qsf
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

# UART on the GPIO header - GPIO_D[0] / GPIO_D[1] (see docs/de25_pinout.md)
set_location_assignment PIN_BK31  -to uart_rxd
set_location_assignment PIN_BE43  -to uart_txd

set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to CLOCK0_50    -entity de25_uart_top
set_instance_assignment -name IO_STANDARD "1.2-V"        -to CPU_RESET_n  -entity de25_uart_top
set_instance_assignment -name IO_STANDARD "1.2-V"        -to KEY[0]       -entity de25_uart_top
set_instance_assignment -name IO_STANDARD "1.2-V"        -to KEY[1]       -entity de25_uart_top
set_instance_assignment -name IO_STANDARD "1.2-V"        -to KEY[2]       -entity de25_uart_top
set_instance_assignment -name IO_STANDARD "1.2-V"        -to KEY[3]       -entity de25_uart_top
set_instance_assignment -name IO_STANDARD "1.2-V"        -to SW[0]        -entity de25_uart_top
set_instance_assignment -name IO_STANDARD "1.2-V"        -to SW[1]        -entity de25_uart_top
set_instance_assignment -name IO_STANDARD "1.2-V"        -to SW[2]        -entity de25_uart_top
set_instance_assignment -name IO_STANDARD "1.2-V"        -to SW[3]        -entity de25_uart_top
set_instance_assignment -name IO_STANDARD "1.2-V"        -to SW[4]        -entity de25_uart_top
set_instance_assignment -name IO_STANDARD "1.2-V"        -to SW[5]        -entity de25_uart_top
set_instance_assignment -name IO_STANDARD "1.2-V"        -to SW[6]        -entity de25_uart_top
set_instance_assignment -name IO_STANDARD "1.2-V"        -to SW[7]        -entity de25_uart_top
set_instance_assignment -name IO_STANDARD "1.2-V"        -to SW[8]        -entity de25_uart_top
set_instance_assignment -name IO_STANDARD "1.2-V"        -to SW[9]        -entity de25_uart_top
set_instance_assignment -name IO_STANDARD "1.2-V"        -to LEDR[0]      -entity de25_uart_top
set_instance_assignment -name IO_STANDARD "1.2-V"        -to LEDR[1]      -entity de25_uart_top
set_instance_assignment -name IO_STANDARD "1.2-V"        -to LEDR[2]      -entity de25_uart_top
set_instance_assignment -name IO_STANDARD "1.2-V"        -to LEDR[3]      -entity de25_uart_top
set_instance_assignment -name IO_STANDARD "1.2-V"        -to LEDR[4]      -entity de25_uart_top
set_instance_assignment -name IO_STANDARD "1.2-V"        -to LEDR[5]      -entity de25_uart_top
set_instance_assignment -name IO_STANDARD "1.2-V"        -to LEDR[6]      -entity de25_uart_top
set_instance_assignment -name IO_STANDARD "1.2-V"        -to LEDR[7]      -entity de25_uart_top
set_instance_assignment -name IO_STANDARD "1.2-V"        -to LEDR[8]      -entity de25_uart_top
set_instance_assignment -name IO_STANDARD "1.2-V"        -to LEDR[9]      -entity de25_uart_top
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to uart_rxd     -entity de25_uart_top
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to uart_txd     -entity de25_uart_top

set_instance_assignment -name CURRENT_STRENGTH_NEW 6MA -to uart_txd -entity de25_uart_top

# --------------------------------------------------------------- commit
export_assignments

if {$need_to_close_project} {
    project_close
}
