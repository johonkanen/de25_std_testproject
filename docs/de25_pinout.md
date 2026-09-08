# DE25-Standard pin notes for `de25_uart`

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
| `uart_rxd`    | PIN_BK31  | 3.3-V LVCMOS | `GPIO_D[0]` — board→FPGA |
| `uart_txd`    | PIN_BE43  | 3.3-V LVCMOS | `GPIO_D[1]` — FPGA→board |

## Why the UART is on the GPIO header

The DE25-Standard's on-board USB bridge is a **Silicon Labs CP2105** dual
UART (`~/dev/de25_std/Datasheet/UART TO USB/CP2105-F01-GM.pdf`). In every
Terasic example its UART lines go to the **HPS** (`HPS_UART_RX` PIN_AB127 /
`HPS_UART_TX` PIN_M124, 1.8 V) — there is no FPGA-fabric UART wired to it.

So this build breaks the UART out to two GPIO-header pins and you attach an
external **3.3 V** USB-serial adapter (FT232, CP210x, CH340, …):

```
adapter GND  <-> GPIO header GND
adapter TXD   -> GPIO_D[0]  (uart_rxd, PIN_BK31)
adapter RXD  <-  GPIO_D[1]  (uart_txd, PIN_BE43)
```

`GPIO_D[0]` / `GPIO_D[1]` are the first two pins of the 40-pin GPIO header;
check the DE25-Standard User Manual §3.9 "GPIO" for the exact header
position and whether that header sits behind a level translator (if it uses
an auto-direction shifter, move `uart_txd` to a plain output-capable pin).

## Repointing the pins

Edit the two `set_location_assignment` lines for `uart_rxd` / `uart_txd`
in `build_de25_uart.tcl` and re-run `quartus_sh -t build_de25_uart.tcl`.

## Using a PLL instead of the raw 50 MHz clock

This build runs everything on `CLOCK0_50` (`g_clock_divider = 434`). To get
a 100 MHz core clock like `axc3000_test`, add an `altera_iopll`
(50 MHz → 100 MHz, `locked` used) — the DE25 demos
`Demonstration/FPGA/DRAM_RTL_Test/v/pll.ip` is a board-tested 50→100/200
IOPLL for this exact device you can copy into `ip/`. Then set
`g_clock_divider = 868` and hold `system_reset` until `locked`.
