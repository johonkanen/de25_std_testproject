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
| `fpga/` | top level `de25_soc_top.vhd`, register file, LWH2F bridge, `de25_soc.sdc`, `build_de25_soc.tcl` (creates the Quartus project) |
| `fpga/source/` | `hVHDL_fpga_interconnect` (submodule), its 32/16-bit instance in `fpga_communication/`, MAX6650 fan controller |
| `fpga/hps/` | HPS + DDR4 EMIF Platform Designer system ([fpga/hps/README.md](fpga/hps/README.md)) |
| `tools/` | `program.sh` (JTAG), `write_githash.sh` |
| `linux/` | ATF / U-Boot / kernel build, device tree, QSPI image ([linux/README.md](linux/README.md)) |
| `docs/` | pinout, fan controller, plan |

The fabric-only `de25_uart` build, the bare-metal HPS tests, the
FreeRTOS experiment and the fabric UART register master were removed;
they are in the git history.

## Build

Everything is built out of tree into `build/` (`BUILD_DIR=` moves it):

```
git submodule update --init
./build.sh fpga        # -> build/fpga/output_files/de25_soc.sof
./build.sh linux       # ATF + U-Boot + kernel (still in linux/build_output/ until Phase A)
./build.sh jic         # -> build/images/de25_soc.jic
./build.sh all
```

`fpga/build_de25_soc.tcl` refuses to run inside the source tree. It copies
`fpga/hps/` into `build/fpga/hps/`, because Quartus generates IP next to the
`.qsys`/`.ip` files, and writes `git_hash_pkg.vhd` there. Edit the
originals in `fpga/hps/`.

## Program (volatile JTAG load)

```
tools/program.sh                   # build/fpga/output_files/de25_soc.sof
tools/program.sh --check           # set up jtagd + jtagconfig only
```

From WSL2 the on-board USB-Blaster must be attached first
(`usbipd attach --wsl --busid <b-p>` on Windows, after every replug). With
more than one cable attached, name it: `CABLE="<name from jtagconfig>"`.

## Register file

Over LWH2F at `0x2000_0000`, register *n* at byte offset *n* × `0x10`
(`fpga/register_block.vhd`).

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
