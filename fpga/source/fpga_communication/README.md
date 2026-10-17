# vendored from johonkanen/fpga_communication

`fpga_interconnect_16bit_pkg.vhd` is copied verbatim from
<https://github.com/johonkanen/fpga_communication>: the 32-bit data /
16-bit address instance of `fpga_interconnect_generic_pkg` (from the
`hVHDL_fpga_interconnect` submodule under `../`). The UART master
(`communications.vhd`, `serial_protocol_generic_pkg.vhd`) was removed with
the fabric UART.

To update: copy the newer version from upstream and re-run the build.
