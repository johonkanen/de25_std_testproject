# Timing constraints for the DE25-Standard UART bring-up build.
#
# Everything runs on the 50 MHz board oscillator - no PLL, so the clock is
# created here directly.

create_clock -name CLOCK0_50 -period 20.000 [get_ports CLOCK0_50]

derive_clock_uncertainty

# Asynchronous pins - no external timing relationship
set_false_path -from [get_ports CPU_RESET_n]
set_false_path -from [get_ports {SW[*]}]
set_false_path -from [get_ports {KEY[*]}]
set_false_path -to   [get_ports {LEDR[*]}]
set_false_path -from [get_ports uart_rxd]
set_false_path -to   [get_ports uart_txd]
