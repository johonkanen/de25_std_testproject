# Timing constraints for the DE25-Standard SoC bring-up build.
#
# The HPS-EMIF IP constrains its own DDR4_REFCLK_p through the .qip SDC, so
# only the fabric board clock and the fabric async pins are set here.

create_clock -name CLOCK0_50 -period 20.000 [get_ports CLOCK0_50]

derive_clock_uncertainty

# fabric async pins (the register block runs on CLOCK0_50)
set_false_path -from [get_ports CPU_RESET_n]
set_false_path -from [get_ports {SW[*]}]
set_false_path -from [get_ports {KEY[*]}]
set_false_path -to   [get_ports {LEDR[*]}]
set_false_path -from [get_ports uart_rxd]
set_false_path -to   [get_ports uart_txd]
