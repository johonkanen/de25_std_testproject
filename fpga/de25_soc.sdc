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

# the TLA2518 ADC's SPI (tla2518_reader.vhd): SCLK, CS and SDI leave from I/O
# registers and SDO is taken in one, a whole SCLK period (40 ns) after the
# falling edge that launched it; the round trip (I/O registers, board, the
# ADC's 16 ns) is checked there, not here
set_false_path -to   [get_ports {ADC_SCK ADC_CS_n ADC_SDI}]
set_false_path -from [get_ports ADC_SDO]
