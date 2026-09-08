# de25_std_testproject — UART bring-up build

Minimal Quartus Prime Pro build for the **Terasic DE25-Standard**
(Agilex 5 `A5ED013BB32AE4SCS`), structured like
[`johonkanen/axc3000_test`](https://github.com/johonkanen/axc3000_test).

Scope of the default `de25_uart` build: a UART + `fpga_interconnect`
register block, running straight off the 50 MHz board oscillator. No PLL,
no DSP, no processors — just enough to prove the toolchain, the pins and
the serial register interface work on a fresh board. A second top level,
`de25_soc`, adds the Agilex 5 HPS with DDR4 / Ethernet / SD-MMC — see
[SoC variant](#soc-variant--de25_soc) below.

## Sources

`source/` holds two submodules and three vendored files:

| path | origin |
|------|--------|
| `source/hVHDL_uart` | `hVHDL/hVHDL_uart` |
| `source/hVHDL_fpga_interconnect` | `hVHDL/hVHDL_fpga_interconnect` |
| `source/fpga_communication/*.vhd` | vendored from `johonkanen/fpga_communication` |

The vendored `communications.vhd` has one local change from upstream: the
two UART config signals are given initial values so `number_of_clocks_per_bit`
is never 0 on the first clock edge (see the comment in the file).

## Build (run from this directory)

```
git submodule update --init
./write_githash.sh                       # stamp git_hash_pkg.vhd (optional)
quartus_sh  -t build_de25_uart.tcl
quartus_syn de25_uart
quartus_fit de25_uart
quartus_sta de25_uart
quartus_asm de25_uart
```

The `.tcl` writes `de25_uart.qpf` / `de25_uart.qsf` (both git-ignored) and
sets every device / pin / config-scheme assignment. Built and verified
through `quartus_asm` with Quartus Prime Pro **26.1.1** (the DE25 demos
themselves ship for 25.1; both work).

## Program (volatile JTAG load)

On-board **Intel FPGA Download Cable II** (USB-Blaster II).

```
quartus_pgm -c 1 -m jtag -o "p;output_files/de25_uart.sof@1"
```

`@1` is the FPGA's position in the JTAG chain — run `jtagconfig` to confirm
(the Agilex 5 SoC puts the SDM in the chain). Use the cable **index**
(`-c 1`), not a name.

### From WSL2

WSL2 has no native USB — forward the blaster with
[usbipd-win](https://github.com/dorssel/usbipd-win):

```
# Windows, admin PowerShell — bind once, attach after every replug / wsl --shutdown
usbipd list
usbipd bind   --busid <b-p>
usbipd attach --wsl --busid <b-p>
```

Then [`program.sh`](program.sh) does the WSL side (perms, `jtagd`,
`jtagconfig`, `quartus_pgm`):

```
./program.sh                       # flash output_files/de25_uart.sof
./program.sh path/to/other.sof     # flash a specific file
./program.sh --check               # set up + jtagconfig, don't flash
sudo ./program.sh --install-udev   # once: persistent 0666 rule
```

`QUARTUS_BIN=`, `CABLE=` and `DEVICE=` env vars override the tool path,
cable index and JTAG device index.

## Talk to it

**The UART is not the on-board USB port** — that CP2105 channel goes to the
HPS. `uart_rxd` / `uart_txd` are on GPIO-header pins `GPIO_D[0]` /
`GPIO_D[1]`; wire a **3.3 V** USB-serial adapter to them
(see [docs/de25_pinout.md](docs/de25_pinout.md)):

```
adapter GND -> header GND ; adapter TX -> GPIO_D[0] ; adapter RX -> GPIO_D[1]
```

50 MHz / `g_clock_divider` (434) = 115207 baud, 32-bit data words.

```
python test_uart.py [/dev/ttyUSB0] [115200]
```

`test_uart.py` is self-contained (`pip install pyserial`) and exercises
every register. Exit status 0 = all passed.

| addr | meaning |
|-----:|---------|
| 1 | constant id `0x0000DE25` (RO) |
| 2 | git hash (RO) |
| 3 | loopback register (R/W) |
| 4 | read strobe counter (RO, ++ per read) |
| 5 | LED register — low 9 bits drive `LEDR[8:0]` (R/W) |
| 6 | `SW[9:0]` slide switches (RO) |
| 7 | `KEY[3:0]` push-buttons, 1 = pressed (RO) |
| 8 | free-running core-clock uptime counter (RO) |
| 9 | fan target speed — MAX6650 KTACH register (R/W), resets to a quiet default |
| 10 | fan tach0/rpm — bits 7:0 raw Tach0Count, bits 23:8 rpm (RO) |
| 11 | fan link status — bits 7:0 Config readback, bit 8 init_done, bit 9 i2c_error (RO) |

`LEDR[9]` is a ~1 Hz heartbeat so the board shows life with nothing attached.

Registers 9–11 drive the board's MAX6650 fan controller over its own I2C
bus (`source/fan_control/`) — see [docs/de25_std_fan.md](docs/de25_std_fan.md)
for the register values, the KTACH speed encoding, and how to trim the
startup speed.

## Simulate

A testbench drives the real UART pins of `de25_uart_top` and checks the
register responses. Needs [`nvc`](https://github.com/nickg/nvc) ≥ 1.14:

```
cd sim && ./run.sh
```

Expected tail: `==== ALL CHECKS PASSED ====`.

## SoC variant — `de25_soc`

A second top level, `de25_soc_top.vhd`, adds the **Agilex 5 HPS** alongside
the unchanged fabric register block:

- `hps_subsystem` (`hps/hps_subsystem.qsys`, a Platform Designer system
  instantiated as a VHDL component — no wrapper-generator script) —
  HPS + HPS-EMIF **DDR4**, with **EMAC0** (gigabit, RGMII + MDIO),
  **SD/MMC** (4-bit), UART1 console, I2C1. `H2F`/`F2SDRAM`/`F2H(ACE5-Lite)`
  are disabled; `LWH2F` (lightweight HPS-to-FPGA) and the F2H interrupts
  stay enabled but unwired — see [hps/README.md](hps/README.md).
- `de25_uart_top` — the fabric UART register block, exactly as above, on
  `GPIO_D[0]/[1]`, independent of the HPS.

```
quartus_sh  -t build_de25_soc.tcl
quartus_ipgenerate de25_soc   # regenerates hps_subsystem (ALWAYS_REGENERATE_IP)
quartus_syn de25_soc          # verified: 0 errors, 0 warnings (26.1.1)
quartus_fit de25_soc          # verified: 0 errors, timing met
quartus_sta de25_soc
quartus_asm de25_soc          # verified: 0 errors — .sof programmed on hardware
```

Because the H2F/F2SDRAM/F2H bridges are off and the pin mux differs from
the GHRD's, `de25_soc` does **not** boot the stock Terasic GHRD SD image —
it needs its own device tree and U-Boot SPL handoff built from this
project (see [`linux/`](linux/README.md)). The fabric register block
still works exactly as in the `de25_uart` build.

A first-cut Linux build (`build_de25_linux.sh` + a bridge-free device tree,
modelled on Altera's roll-your-own GSRD script) is in
[`linux/`](linux/README.md). It builds end to end (ATF + U-Boot + kernel +
toybox initramfs + `sdcard.img`); not yet booted on hardware.

**Talking to the HPS today, with none of that**:
[`hps/baremetal_uart1_test/`](hps/baremetal_uart1_test/README.md) is a
from-scratch bare-metal program — no ATF, no U-Boot, no Linux, no SD card
— that runs straight out of HPS OCRAM and talks over HPS UART1. Loaded the
same volatile-JTAG way as every other `.sof` here
(`quartus_pfg -o hps_path=...` + `quartus_pgm`).
**Hardware-verified**: prints a banner (pin-mux + clock bring-up return
codes, measured UART clock, programmed baud divisor) and echoes every byte
sent back, confirmed byte-for-byte over `/dev/ttyUSB2`.

## Pinout

From `~/dev/de25_std/Demonstration/FPGA/golden_top/golden_top.qsf`:

| signal | pin | IO standard |
|--------|-----|-------------|
| `CLOCK0_50` | CH128 | 3.3-V LVCMOS (50 MHz) |
| `CPU_RESET_n` | BM78 | 1.2-V (active low) |
| `uart_rxd` | BK31 (`GPIO_D[0]`) | 3.3-V LVCMOS |
| `uart_txd` | BE43 (`GPIO_D[1]`) | 3.3-V LVCMOS |

Full table + notes: [docs/de25_pinout.md](docs/de25_pinout.md).

## Note

- Critical Warning 20759 (missing Reset Release IP) is expected, exactly as
  in `axc3000_test`. Startup is covered here by a ~21 ms power-on-reset
  counter (`g_por_cycles`); add the **Reset Release IP** (`ninit_done`) for
  a production build — the DE25 demos under
  `Demonstration/FPGA/DDR4_Test_RTL/reset_release.ip` have a ready-made one
  for this device.
- To move to a 100 MHz core clock via an IOPLL (like `axc3000_test`), see
  the last section of `docs/de25_pinout.md`.
