# de25_std_testproject — Linux on the DE25-Standard

Agilex 5 HPS + fabric register file for the **Terasic DE25-Standard**
(`A5ED013BB32AE4SCS`), booting Linux from SD. The FPGA project exists to
give Linux its HPS handoff (SPL in the `.sof`/`.jic`) and a register file
reachable over the lightweight HPS-to-FPGA bridge (LWH2F).

Where this is going: [docs/plan_upstream_hps_first_webgui.md](docs/plan_upstream_hps_first_webgui.md)
(upstream boot stack, HPS-first, web GUI, network updates).

## Layout

| path | what |
|------|------|
| `de25_soc_top.vhd`, `uart_register_block.vhd`, `axi_lwh2f_bridge.vhd`, `h2f_user0_clk_heartbeat.vhd`, `de25_soc.sdc` | FPGA top level and register file |
| `build_de25_soc.tcl` | creates the Quartus project (all assignments) |
| `source/` | `hVHDL_uart`, `hVHDL_fpga_interconnect` (submodules), vendored `fpga_communication`, MAX6650 fan controller |
| `hps/` | HPS + DDR4 EMIF Platform Designer system ([hps/README.md](hps/README.md)) |
| `linux/` | ATF / U-Boot / kernel build, device tree, QSPI image ([linux/README.md](linux/README.md)) |
| `docs/` | pinout, fan controller, plan |

The fabric-only `de25_uart` build, the bare-metal HPS tests and the
FreeRTOS experiment were removed; they are in the git history before this
README's commit.

## Build

```
git submodule update --init
./write_githash.sh                 # stamp git_hash_pkg.vhd (optional)
quartus_sh  -t build_de25_soc.tcl
quartus_syn de25_soc               # regenerates hps_subsystem (ALWAYS_REGENERATE_IP)
quartus_fit de25_soc
quartus_sta de25_soc
quartus_asm de25_soc
linux/build_de25_linux.sh
linux/make_jic.sh
```

Out-of-tree builds into a single `build/` directory are planned (Phase 0b
of the plan).

## Program (volatile JTAG load)

```
./program.sh                       # output_files/de25_soc.sof
./program.sh --check               # set up jtagd + jtagconfig only
```

From WSL2 the on-board USB-Blaster must be attached first
(`usbipd attach --wsl --busid <b-p>` on Windows, after every replug).

## Register file

Over LWH2F at `0x2000_0000`, register *n* at byte offset *n* × `0x10`.
The same registers are also reachable over a fabric UART on
`GPIO_D[0]/[1]` (3.3 V); that path is scheduled for removal.

| reg | meaning |
|----:|---------|
| 1 | constant id `0x0000DE25` (RO) |
| 2 | git hash (RO) |
| 3 | loopback (R/W) |
| 4 | read strobe counter (RO, +1 per read) |
| 5 | LED register, low 9 bits drive `LEDR[8:0]` (R/W); `LEDR[9]` is a heartbeat |
| 6 | `SW[9:0]` (RO) |
| 7 | `KEY[3:0]`, 1 = pressed (RO) |
| 8 | uptime counter (RO) |
| 9 | fan target, MAX6650 KTACH (R/W) |
| 10 | fan: bits 7:0 Tach0Count, bits 23:8 rpm (RO) |
| 11 | fan: bits 7:0 Config readback, bit 8 init_done, bit 9 i2c_error (RO) |

Fan details: [docs/de25_std_fan.md](docs/de25_std_fan.md). Pins:
[docs/de25_pinout.md](docs/de25_pinout.md).

## Notes

- Critical Warning 20759 (missing Reset Release IP) is expected; startup
  is covered by a ~21 ms power-on-reset counter.
- `CPU_RESET_n` also resets the LWH2F bridge side: do not press it while
  Linux is accessing the register file.
