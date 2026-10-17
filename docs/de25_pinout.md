# DE25-Standard pin notes

All pin/IO-standard values are taken from the Terasic golden top
(`~/dev/de25_std/Demonstration/FPGA/golden_top/golden_top.qsf`) for the
Agilex 5 `A5ED013BB32AE4SCS`.

| signal | pin | IO standard | note |
|--------|-----|-------------|------|
| `CLOCK0_50`   | PIN_CH128 | 3.3-V LVCMOS | 50 MHz oscillator |
| `CPU_RESET_n` | PIN_BM78  | 1.2-V | active-low push-button |
| `KEY[3:0]`    | BW59 / CA59 / CF71 / CH71 | 1.2-V | active low |
| `SW[9:0]`     | BM62 BP62 BH62 BH59 BM59 BK59 BU62 CF59 BU59 BR59 | 1.2-V | |
| `LEDR[9:0]`   | CC71 BH78 CH69 CF69 CA62 CC62 CF62 BM69 CA71 BR62 | 1.2-V | LEDR[9] = heartbeat |
| `H2F_CLK_TEST` | PIN_BF29 | 3.3-V LVCMOS | `GPIO_D[2]`, H2F User0 clock heartbeat |
| `FPGA_I2C_SCL` / `FPGA_I2C_SDA` | BF120 / BH118 | 3.3-V LVCMOS | MAX6650 fan bus |

The HPS console is HPS UART1 on dedicated HPS pins (`HPS_UART_TX` M124 /
`HPS_UART_RX` AB127, 1.8 V) to the board's USB-UART. The fabric UART that
used to be on `GPIO_D[0]/[1]` was removed; LWH2F is the only way into the
register file.

## Using a PLL instead of the raw 50 MHz clock

This build runs everything on `CLOCK0_50`. To get
a 100 MHz core clock like `axc3000_test`, add an `altera_iopll`
(50 MHz → 100 MHz, `locked` used) — the DE25 demos
`Demonstration/FPGA/DRAM_RTL_Test/v/pll.ip` is a board-tested 50→100/200
IOPLL for this exact device you can copy into `ip/`. Then hold
`system_reset` until `locked`, and update `g_clock_hz` of the fan
controller.
