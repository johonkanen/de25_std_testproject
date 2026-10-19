# Plan: DE25-Standard to upstream boot, HPS-first, network updates, web GUI

Status 2026-10-18: Phase 0b and Phase A done - the upstream stack boots
Alpine on the board (A8 results under "Phase A progress"). Phase B passed
on the board 2026-10-19 except B1b's watchdog-expiry check ("Phase B
progress"). Next: that check, then Phase C.
Branch `upstream-hps-first`. §2 describes the
repository *before* Phase 0b; paths elsewhere are the new ones (`fpga/`,
`tools/`, `build/`). The reference implementation is the sister repository
`~/dev/de25_nano_testproject` (DE25-Nano, same Agilex 5 family), referred
to below as "the Nano repo". Paths without a repo prefix are in this repo
(`~/dev/de25_std_testproject`); `nano:` paths are in the Nano repo.

The reader is expected to have only this document and the two repositories.
Do the phases in order. Each step says what to change, what "done" looks
like on the board, and how to fall back.

**Hardware rules for whoever implements this:** steps marked **[HW]**
touch the board (JTAG programming, the serial console, the network). Do
them only with the user's agreement, and only with someone able to
power-cycle the board. Never run the "corrupt core" test (Phase E) without
a person at the power switch.

---

## 1. Goal and end state

| | end state on the DE25-Standard |
|---|---|
| boot stack | Altera upstream only: ATF `altera-fpga/arm-trusted-firmware` `socfpga_v2.14.1`, U-Boot `altera-fpga/u-boot-socfpga` `socfpga_v2026.04`, Linux `altera-fpga/linux-socfpga` `socfpga-6.18.20-lts`. A small, board-specific U-Boot DT and Linux DT kept in this repo and copied into the trees by the build script. No Terasic forks. |
| rootfs | Alpine 3.24 aarch64 minirootfs on SD partition 2 (ext4), built without root by `linux/tools/make_sdcard_image.sh`; `extlinux.conf` on the FAT partition; written to the card over TFTP by `sd_recover.py` |
| boot mode | **HPS-first** by default (`HPS_INITIALIZATION "HPS FIRST"`): the SDM configures the HPS side only, U-Boot's preboot loads the FPGA core (SD, else a QSPI copy), Linux reloads the core in ~2 s without a reboot (`fpga-reload`). `FPGA_FIRST=1` builds the old "AFTER INIT_DONE" variant as the fallback |
| CPUs | all four cores online (2x A55 + 2x A76) |
| fabric | the register file over LWH2F with build id, board variant, LED blinkers on `LEDR[9:0]`, the six 7-segment displays, switches, keys, MAX6650 fan |
| web GUI | three processes (`fpga_access.py`, `temp_control.py`, `fpga_web.py`) under a supervisor; an SVG drawing of the DE25-Standard with live LEDs, HEX displays, switches, keys and fan; blinker picker; SoC temperatures and voltages; die-temperature PI loop driving the fan; "GUI release" and "FPGA core" update cards |
| updates | GUI releases over HTTP with test / confirm / automatic revert; FPGA cores over HTTP as a bundle (core + manifest) with periphery check, rollback, card copy; later RSU for phase 1 |
| docs | `docs/linux_boot.md`, `docs/hps_first.md`, `linux/webapp/README.md` written like the Nano's |

---

## 2. Current state of this repository

| area | state | what it uses / lacks |
|---|---|---|
| removed 2026-10-17 | fabric-only `de25_uart` build, its testbench and `test_uart.py`, the bare-metal HPS tests (`hps/baremetal_*`), the FreeRTOS experiment, scratch `out_*.sof`, all in-tree Quartus output | in git history before the cleanup commit. Binaries of the 2026-09-08 state (upstream U-Boot that failed on SD, `.sof`, `.jic`, ATF hand patch as a `.patch`) saved in `~/de25_std_known_good_2026-09-08/`. The hand-built Terasic U-Boot that booted the board exists **only on the SD card** |
| `build_de25_soc.tcl`, `de25_soc_top.vhd` | HPS (`hps/hps_subsystem.qsys`) + DDR4 + `uart_register_block.vhd`; LWH2F wired and hardware-confirmed | no `QSPI_OWNERSHIP` (default SDM), no `HPS_INITIALIZATION` (default "AFTER INIT_DONE"); fabric on `CLOCK0_50`; LWH2F bridge reset follows `CPU_RESET_n` |
| `uart_register_block.vhd` (now `fpga/register_block.vhd`) | registers 1..11 (see table in §3.3), two masters (fabric UART + LWH2F); LWH2F only since 0b | no build id, no blinkers, no HEX |
| HPS IP `hps/ip/hps_subsystem/hps_subsystem_intel_agilex_5_soc_0.ip` | vendored from another DE25-Standard project; EMAC0, SD, UART1, I2C1; LWH2F 32-bit; H2F User0 clock 50 MHz | **`Pwr_a76_core2_on`/`_core3_on` = false** (also `{0}` in `hps/hps_subsystem.tcl` lines 1343-1344): Linux would see 2 CPUs. HPS_LED/HPS_KEY (GPIO1 IO17/IO16), USB0, SPIM0 not in the pin mux |
| `PROJECT_IP_REGENERATION_POLICY` | `ALWAYS_REGENERATE_IP` in `build_de25_soc.tcl` | good - avoids most of the Nano's stale-IP trap, but verify anyway (§5.1) |
| `linux/build_de25_linux.sh` | ATF/U-Boot/Linux from the `QPDS26.1.1_REL_GSRD_PR` tag (the same commits as `socfpga_v2.14.1` / `socfpga_v2026.04`), U-Boot with `socfpga_agilex5_defconfig` + the **Nano's** DT, toybox initramfs | SD did **not** work with that U-Boot (every SD command timed out); the board was booted with **Terasic's fork** `terasic/u-boot-socfpga` `de25-standard-v2025.01` (`socfpga_agilex5_de25s_defconfig`), built by hand - the script was never updated. ATF `config_ddr_size` patch applied by hand in `linux/build_output/arm-trusted-firmware` |
| `linux/de25_uboot.config-fragment`, `de25_kernel.config-fragment` | the fragments above; the kernel one disables `STRICT_DEVMEM` | `STRICT_DEVMEM` is **not** the cause of LWH2F SIGBUS (it was bridges in reset; the Nano runs with `STRICT_DEVMEM=y`). Both fragments become obsolete |
| `linux/dts/socfpga_agilex5_de25.dts` | Linux DT that booted 6.18.20 (EMAC0 up, SD rootfs read) | no `&qspi`, no `&temp_volt` sensor labels, no RTC, `phy-mode = "rgmii-id"` (Terasic uses `"rgmii"`), old Cadence combo-PHY properties that 6.18 ignores |
| `linux/make_jic.sh` | `quartus_pfg` SOF + SPL only, MT25QU128, `A5ED013BB32AE4SCS` | no U-Boot in QSPI, no core copy, no manifest |
| web GUI, network updates, HPS-first | none | - |
| Linux boot | hardware-confirmed once (2026-09-08/09), toybox in RAM, by hand from U-Boot | no Alpine, no extlinux |

Upstream support (checked 2026-10-17 against the live branch heads, which
equal the local checkouts in `nano:linux/build_output/`): **neither
`socfpga_v2026.04` (U-Boot) nor `socfpga-6.18.20-lts` / `socfpga-6.19`
(Linux) has a DE25-Standard board.** U-Boot has only
`socfpga_agilex5_de25_nano_defconfig` + `socfpga_agilex5_de25_nano.dts`;
Linux has only `socfpga_agilex5_de25_nano.dts`. Terasic has the Standard
in its forks: U-Boot `de25-standard-v2025.01` (commit `e905465722`
"add support for de25-standard revC": `socfpga_agilex5_de25s.dts`,
`-u-boot.dtsi`, `socfpga_agilex5_de25s_defconfig`, and the same
`dualport = 0` DDR change as the Nano), Linux `de25-standard-6.12.11-lts`
(`socfpga_agilex5_de25s.dts`), ATF `de25-standard-v2.12.0` (same commit as
their Nano ATF). So this repo carries its own board DTs (Phase A, A3/A4),
derived from upstream's Nano DTs plus Terasic's Standard DTs.

---

## 3. Differences Standard vs Nano that matter

### 3.1 Board and device

| | DE25-Standard (this repo) | DE25-Nano (reference) | consequence |
|---|---|---|---|
| device | `A5ED013BB32AE4SCS` (2x A55 + 2x A76 per the user manual) | `A5EB013BB23BE4SCS` | `FLASH_LOADER=A5ED013BB32AE4SCS` - use the full string (the Nano found the abbreviated form resolves a different IDCODE) |
| HPS console | **HPS UART1 on dedicated HPS pins** (`HPS_UART_TX` M124 / `HPS_UART_RX` AB127, 1.8 V) to the board's USB-UART (repo docs say CP2105; user manual rev D says FT2232H inside the USB-Blaster III, one Type-C) | UART1 routed **through the fabric** to `FPGA_UART_TX/RX` | on the Standard the console works **from the first SPL line even in HPS-first mode** - the Nano's "silent until the core loads" problem does not exist here. All serial tools need a new `default_console()` |
| fabric UART | removed in Phase 0b (was a register-file UART master on `GPIO_D[0]/[1]`) | retired | LWH2F is the only bus master, as on the Nano |
| fabric clock | `CLOCK0_50` (CH128, 3.3 V); LWH2F AXI clock = `CLOCK0_50` | HPS `h2f_user0` clock | fine either way; keep `CLOCK0_50` |
| reset | `CPU_RESET_n` button (BM78) resets the register file **and the LWH2F bridge-side reset** (`axi_bridge_reset <= system_reset`) | power-on counter only | pressing the button while Linux polls LWH2F (20 Hz) can stall the CPU. Phase C decouples the bridge reset from the button |
| LEDs | `LEDR[9:0]`, 1.2 V; `LEDR[9]` heartbeat | `LED[7:0]`; `LED[7]` heartbeat | blinkers and GUI for 10 LEDs |
| switches / keys | `SW[9:0]`, `KEY[3:0]` (1.2 V) | `SW[3:0]`, `KEY[1:0]` | GUI, register decode |
| 7-segment | **six HEX displays** `HEX0..HEX5` (common anode, 1.2 V; pins in `~/dev/de25_std/Demonstration/FPGA/golden_top/golden_top.qsf`) | none | new registers + GUI element |
| HPS LED / key | `HPS_LED` Y127 (GPIO1 IO17), `HPS_KEY` K124 (GPIO1 IO16) - **not in this repo's HPS pin mux** | 3 HPS LEDs | optional (§4 A1b); changes the periphery |
| fan | **MAX6650**, closed-loop tach regulation, own I2C bus `FPGA_I2C_SCL` BF120 / `FPGA_I2C_SDA` BH118, addr 0x48. Register 9 = KTACH target (`KTACH = 119040/RPM - 1` with KSCALE 2), 1500 rpm default (KTACH 78). **No thermal fail-safe** of its own | AMC6821 duty-cycle, THERM fail-safe enabled | the temperature loop's actuator is a target **rpm**, not a duty; the dead-man lease matters more; see §4 C5 |
| DDR | 1 GB DDR4, 32-bit (2x 16-bit), IO96B HPS EMIF | 1 GB LPDDR4 | ATF `config_ddr_size` patch needed; U-Boot `dualport = 0` patch needed too (Terasic's Standard U-Boot carries exactly the Nano's change) |
| QSPI | MT25QU128, 16 MB (confirmed by JTAG autodetect) | MT25QU128 | same flash layout as the Nano |
| SD card | 3.3 V only (Terasic DTs: `no-1-8-v`); no GPIO for 1.8 V switching in this pin mux | upstream DT has `sd_io_1v8_reg` on GPIO1 port B bit 3 | do **not** copy the Nano's `vqmmc` GPIO regulator; the main U-Boot risk (A3) |
| Ethernet | KSZ9031RN, MDIO address 1, RGMII (Terasic DTs: `phy-mode = "rgmii"`) | KSZ9031 | open question: `rgmii` vs `rgmii-id` (§7) |
| RTC | **PCF85263A at 0x51 on HPS I2C1, CR1220 battery holder** | none | with a coin cell the clock survives power-off: `CONFIG_RTC_DRV_PCF85363=y`, `hwclock -s` in `rc.local`, NTP still for TLS |
| other HPS I2C1 devices | ADXL345 accelerometer | - | optional GUI later |
| board temperature | ADT7461 on the fan I2C bus (Terasic `BOARD_MANAGEMENT.v`) | AMC6821 reads one | optional register later |
| JTAG | on-board USB-Blaster III: `jtagconfig` lists `DE25-Standard [1-1-iface0]`; the HPS console is interface 1 of the same USB device (`usb-TERASIC_DE25-Standard_<serial>-if01-port0`) | USB-Blaster II | cable *name* in all `quartus_pgm` commands; never `-c 1` when more than one board is attached |
| MSEL | SW10 = `001` (AS fast, QSPI) - the default | AS/QSPI | no change |

### 3.2 Files: what carries over from the Nano repo

| Nano file | Standard target | adapt |
|---|---|---|
| `nano:linux/build_de25_nano_linux.sh` | `linux/build_de25_linux.sh` (rewrite) | board DT copy-in, defconfig, file names, no toybox; §4 A2 |
| `nano:linux/make_jic.sh` | `linux/make_jic.sh` (rewrite) | names, `FLASH_LOADER`, HPS/EMIF `.ip` paths in the periphery hash; drop the Nano's stale header comment (it still says `QSPI_OWNERSHIP SDM` / "AFTER INIT_DONE") |
| `nano:linux/tools/make_sdcard_image.sh`, `alpine_rootfs_config.sh`, `setup_alpine_rootfs.sh` | `linux/tools/` | DTB name, core name, IP, hostname, `fstab noauto` for `/boot`, RTC, stable MAC |
| `nano:linux/tools/sd_recover.py`, `tftp_server.py` | `linux/tools/` | console port, board IP; the U-Boot prompt string is the same (`SOCFPGA_AGILEX5 # `) |
| `nano:linux/tools/push_to_nano.py` | `linux/tools/push_to_board.py` | `default_console()`, `--board-ip` |
| `nano:linux/tools/install_webapp.py`, `deploy_web.py`, `deploy_fpga.py`, `gui_test.py` | `linux/tools/` | host, token file, core names, GUI selectors |
| `nano:linux/tools/fpga_reload/fpga-reload`, `core_reload.dts` | `linux/tools/fpga_reload/` | core name, id check |
| `nano:linux/board/de25web-supervisor.sh` | `linux/board/` | almost unchanged (paths are generic `/opt/de25web`) |
| `nano:linux/webapp/*` | `linux/webapp/` | register map, LED/SW/KEY counts, HEX, fan model, board drawing |
| `nano:write_build_id.sh` | `write_build_id.sh` | unchanged |
| `nano:source/led_blinkers.vhd`, `nano:source/blinkers/*.vhd`, `nano:sim/led_blinkers_tb.vhd`, `nano:vunit_run_de25_nano_test.py` | `fpga/source/`, `fpga/sim/`, `fpga/vunit_run_de25_std_test.py` | 10 LEDs instead of 8 |
| `nano:axi_lwh2f_bridge.vhd` | already here (it came from this repo) | none |

These are copies, so the two repos will drift. Accept that for now; once both
boards run the same web stack, move `linux/tools`, `linux/webapp` and
`linux/board` into a shared repo or submodule with a per-board config.

Nano commits worth reading for the reference diffs: `7e43152` (HPS-first,
fpga-reload, A76), `f512b24` (GUI 1.3.0: fpga_access / temp_control),
`be159b5` (core updates over the network), `026b2f3` (QSPI clock fix,
RSU driver), `75cb0d6` (GUI v1, board drawing), `da56eee` (upstream stack,
U-Boot in QSPI, SD over TFTP).

### 3.3 Register map: today and proposed

Over LWH2F at `0x2000_0000`, register *n* at byte offset *n* x `0x10`.
Keep the Nano's numbers for everything both boards have, so the web stack
differs as little as possible.

| reg | today (`fpga/register_block.vhd`) | proposed | notes |
|---:|---|---|---|
| 1 | id `0x0000DE25` | same | |
| 2 | git hash | same | |
| 3 | loopback | same | |
| 4 | read counter | same | |
| 5 | LED register, `LEDR[8:0]` | same, used in blinker mode 0 | `LEDR[9]` heartbeat in mode 0 |
| 6 | `SW[9:0]` | same | |
| 7 | `KEY[3:0]`, 1 = pressed | bit 4 = `CPU_RESET_n` pressed (once it no longer resets the bridge) | |
| 8 | uptime counter | same | |
| 9 | fan KTACH target (R/W) | same | software converts rpm <-> KTACH |
| 10 | fan: 7:0 Tach0Count, 23:8 rpm | same | check the rpm scale on hardware (§7) |
| 11 | fan: 7:0 Config readback (0x29), bit 8 init_done, bit 9 i2c_error | same | |
| 12 | - | reserved (later: ADT7461 board temperature) | |
| 13 | - | blinker mode, low 3 bits (R/W): 0 software, 1 off, 2 counter, 3 scanner, 4 breathing, 5 sparkle | as Nano |
| 14 | - | LEDR 3..0 brightness, a byte each | as Nano |
| 15 | - | LEDR 7..4 brightness | as Nano |
| 16 | - | features: bit 0 hardware blinkers, bit 1 HEX displays | |
| 17 | - | blinker module id, four ASCII chars | as Nano |
| 18 | - | **board variant**, `0x53544400` ("STD\0") | the Nano reads 0 here; tools refuse a core or release for the other board |
| 19 | - | **build id** (Unix time, `write_build_id.sh`) | as Nano |
| 20 | - | LEDR 9..8 brightness (bits 15:0) | |
| 21 | - | HEX value, 24 bits, HEX0 = bits 3:0 (R/W) | shown as hex digits |
| 22 | - | HEX control (R/W): bit 0 raw mode, bits 13:8 blank mask per digit | |
| 23 | - | HEX raw segments HEX3..0, 7 bits per byte, 1 = lit (R/W) | used when raw mode is set |
| 24 | - | HEX raw segments HEX5..4 | |
| 25 | - | HEX segments driven, HEX3..0 (RO) | the GUI draws from 25/26 |
| 26 | - | HEX segments driven, HEX5..4 (RO) | |

The HEX block may be simplified; the GUI only needs 21-22 (or 23-24) to
write and 25-26 to read what is lit.

---

## 4. Phased plan

Overview:

| phase | result | depends on |
|---|---|---|
| 0 | baseline, branch, tools | - |
| 0b | cleanup: only the Linux system left, every build out of tree in `build/` | 0 |
| A | upstream ATF/U-Boot/Linux, Alpine SD image, FPGA-first, 4 CPUs, U-Boot also in QSPI, SD written over TFTP | 0b |
| B | HPS-first, preboot core loader, `fpga-reload` | A |
| C | register file v2 (build id, blinkers, HEX), `fpga_access.py` / `temp_control.py` / `fpga_web.py`, board drawing | B (C1-C3 FPGA work can start in parallel with B) |
| D | GUI updates over the network (supervisor, test/confirm/revert) | C |
| E | FPGA core updates over the network (manifest, periphery hash, rollback, card copy) | B, D |
| F | later: RSU, partial reconfiguration, Ethernet hardening | E |

### Phase 0 - baseline

1. Branch `upstream-hps-first` (exists; created for the cleanup).
2. Note the current board state before changing it: what is in QSPI, what
   U-Boot the card holds. **[HW]** If unknown, read the U-Boot banner on
   the console at the next power-on. **Keep a copy of the card** (`dd`
   from a card reader): the working Terasic U-Boot is not on disk anywhere
   else.
3. Tools: Quartus Pro 26.1.1 (`~/altera_pro/26.1.1`), the aarch64 toolchain
   (`CROSS_TOOLCHAIN` may point at the Nano's
   `nano:linux/build_output/gcc-arm-11.2-2022.02-x86_64-aarch64-none-linux-gnu`),
   `mtools dosfstools fakeroot e2fsprogs (mkfs.ext4 -d) fdisk (sfdisk) dtc pyserial`.
   Python `vunit_hdl` + `nvc` for simulation; Playwright's headless
   Chromium for `gui_test.py` (its DevTools client is
   `~/dev/pr_testing/tools/gui_test.py`).
4. WSL2: attach both USB devices with `usbipd.exe attach --wsl --busid <id>`
   (JTAG and console share one Type-C on rev D boards; two devices on
   boards with a separate CP2105). Run `jtagconfig` and
   `ls -l /dev/serial/by-id/`; record the cable name and the console's
   by-id path (it is the port that prints the SPL banner at power-on).

### Phase 0b - cleanup and out-of-tree builds

Only the Linux system is kept: the FPGA design that carries the HPS
handoff and the register file, the boot stack, the rootfs, the web stack.

**0b1. Delete (done 2026-10-17, `953f138`).** See §2, "removed".

**0b2. Source layout (done, `ea667ae`).** `git mv` plus the path fixes
needed to keep it building, so `git log --follow` keeps working:

```
fpga/            de25_soc_top.vhd, register_block.vhd, axi_lwh2f_bridge.vhd,
                 h2f_user0_clk_heartbeat.vhd, de25_soc.sdc, build_de25_soc.tcl
fpga/source/     (was source/: submodules, fan_control, fpga_communication)
fpga/hps/        (was hps/: hps_subsystem.qsys, ip/, hps_pins.tcl, hps_subsystem.tcl)
linux/           build_de25_linux.sh, make_jic.sh, dts/, uboot/, tools/, webapp/, board/
tools/           program.sh, write_githash.sh (write_build_id.sh comes in A1)
docs/
build.sh         single entry point
```

**0b3. Everything generated goes to `build/`** (done for the FPGA,
`feaa43e`; `BUILD_DIR` overrides it; `.gitignore` is `/build/`,
`/linux/build_output/` until A2, `__pycache__/`, `*.pyc`):

```
build/fpga/                 Quartus project de25_soc: qpf/qsf, output_files/, qdb/, dni/,
                            hps/ (copy of fpga/hps), git_hash_pkg.vhd, build_id_pkg.vhd
build/linux/src/            atf-altera, u-boot-altera, linux-altera clones (kept between
                            builds; `git checkout -- .` + patches on every run)
build/linux/out/            bl31.bin, u-boot.itb, spl/u-boot-spl-dtb.hex, Image, *.dtb
build/images/               de25_std.jic, de25_std.core.rbf, de25_std.core.json, sdcard.img
build/sim/                  VUnit output
build/toolchain/            aarch64 gcc, unless CROSS_TOOLCHAIN points elsewhere
```

`build.sh fpga-project|fpga|linux|jic|all` runs each step (`sdcard` and
`sim` are added in A6 and C1). What was done and learned:

- **Quartus.** `build_de25_soc.tcl` refuses to run inside the source tree.
  It copies `fpga/hps/hps_subsystem.qsys` and `ip/hps_subsystem/*.ip` to
  `build/fpga/hps/` on every run and points `QSYS_FILE` / `IP_FILE` at the
  copies, because Quartus generates IP **next to the `.qsys`/`.ip` file**
  (the `.qsys` refers to its `.ip` files by relative path, so the copy
  resolves). Platform Designer GUI edits are made on
  `fpga/hps/hps_subsystem.qsys`; do not press "Generate" there.
- **`ALWAYS_REGENERATE_IP` does not generate IP on a fresh tree**:
  synthesis fails with "The synthesis RTL for hps/hps_subsystem.qsys has
  not been generated". `build.sh` runs `quartus_ipgenerate de25_soc -c
  de25_soc` before `quartus_syn`. The old README's "nothing to run by
  hand" was wrong; it only worked on a tree that still had generated IP.
- **The tcl recreates the project** (`project_new -overwrite`) on every
  run. It used to reopen an existing project and only add assignments, so
  removed files and pins stayed in the `.qsf` ("Can't analyze file ...",
  "Node ... does not exist in design").
- **Generated VHDL.** `tools/write_githash.sh OUT_DIR` writes
  `git_hash_pkg.vhd` into `build/fpga/` (hash 0 outside git); the file is
  no longer tracked. `write_build_id.sh` follows the same pattern in A1.
- **Linux.** `make_jic.sh` writes `build/images/de25_soc.jic` and reads
  the `.sof` from `build/fpga/`; `build_de25_linux.sh` still writes
  `linux/build_output/`. The Phase A rewrite (A2, A5) moves it to
  `build/linux/` directly; do not first port the old script.
  `linux/build_output/` (4.2 GB of old QPDS-tag clones) is deleted once
  A2 has built.
- **Fabric UART removed.** `communications.vhd`,
  `serial_protocol_generic_pkg.vhd`, the `hVHDL_uart` submodule, the
  `uart_rxd/uart_txd` ports, pins and false paths are gone;
  `uart_register_block` is now `register_block`. LWH2F is the only bus
  master. Before/after: the `.pin` files differ only in BE43/BK31 (now
  unused), 909 -> 616 ALMs, 1659 -> 1198 registers, timing met.
- **`tools/program.sh`** defaults to `build/fpga/output_files/de25_soc.sof`
  and selects the cable by **name**: the only cable when there is one,
  otherwise `CABLE="<name from jtagconfig>"` is required.

Verified: with the same git hash, the out-of-tree build gives the same
`.pin` file (non-comment lines) and fitter resource summary as an in-tree
build of `953f138`. After `./build.sh fpga`, `git status --ignored` shows
only `build/`, `.claude/` and `linux/build_output/`.

### Phase A - upstream boot stack, Alpine, FPGA-first

**Phase A progress (2026-10-18): A1-A7 built, A8 passed on the board
(results after the A8 steps).** `./build.sh fpga linux jic sdcard` produce
`build/fpga/output_files/de25_soc.sof`, `build/linux/out/*`,
`build/images/de25_std.jic` and `build/images/sdcard.img.gz`. Checklist
tests 1 (`HPS_A76_CORE_SELECTION_DUAL`) and 2 (build reruns cleanly) pass.
Differences from the steps below, and findings:

- **A3, the SD PHY.** Terasic's working U-Boot programs the SD PHY through
  its own `cdns,combophy` driver (`drivers/phy/cadence/phy-cadence-combophy.c`
  in `de25-standard-v2025.01`); upstream has no such driver and
  `sdhci-cadence6.c` writes five PHY and four HRS registers per speed mode
  from `cdns,phy-*-sd-ds/-hs` and `cdns,ctrl-*-sd-ds/-hs`. Computed from
  Terasic's DT fields, their registers are: DQS timing `0x00780000`,
  gate/loopback `0x81a40040`, DLL master `0x00a000fe`, **DLL slave `0`**,
  DQ timing `0x28000001`, HRS09 `0x1800c`, HRS10 `0x30000`, HRS16 `0`,
  HRS07 `0xa0000`. Upstream's DE25-Nano DT puts `0x00a000fe` in the DLL
  *slave* register (read DQS delay 254, write DQS delay 160 in DLL bypass
  mode) and leaves the master at the driver default - the likely reason
  the Nano's DT timed out on every SD command here. `linux/uboot/*-u-boot.dtsi`
  sets Terasic's values for both DS and HS. Fallbacks (1)-(3) of A3 stay.
  One difference left: Terasic ORs the DQS-timing bits into the register's
  reset value, upstream writes the value as is.
- **A2** includes B3's `CONFIG_PREBOOT` already: it skips on an FPGA-first
  board (`FPGA_CONFIG` = 3), and the card written in A8 is then ready for
  Phase B (B6: card first). No `CONFIG_SOCFPGA_RSU_MULTIBOOT` (the Nano's
  RSU work, Phase F).
- **A5** uses the Nano's plain layout (boot info, P1, UBOOT, CORE), not its
  newer RSU layout (Phase F). The FPGA-first P1 is 0x200000-0x2B0FFF
  (~0.7 MB; the bitstream of this small design is small), U-Boot at
  0xA00000-0xAE8D97.
- **A6** leaves out the web GUI install (Phase C) and
  `setup_alpine_rootfs.sh` (repartitions a card in a reader, with a
  hard-coded `/dev/sde` default on the Nano; `make_sdcard_image.sh` + `dd`
  or `sd_recover.py` does the same). Includes `eth-watchdog` and the clean
  shutdown order from §5.14/§5.14b.
- **A7, never the wrong board.** `push_to_board.default_console()` matches
  only `TERASIC_DE25-Standard` (if01) or CP2105 by-id names and never a
  `DE25-Nano` one; with nothing found the tools stop and list the ports
  (`--serial` or `DE25_STD_CONSOLE` then). With only the Nano attached, a
  fallback to the Nano's port would have let `sd_recover.py` rewrite the
  Nano's card. `sd_recover.py` also reads the running U-Boot's DT model
  (`fdt print / model`) and writes nothing unless it says DE25-Standard.
- **A1** timing: met; the tightest is CLOCK0_50 hold at 0.000 ns.
- `192.168.1.223` is still unconfirmed as free (§7).

Goal: power-on -> SPL -> ATF 2.14.1 -> U-Boot 2026.04 -> Linux 6.18.20 ->
Alpine, all from upstream sources plus this repo's DTs, FPGA-first, four
CPUs, U-Boot also in QSPI so a blank card still reaches a prompt.

**A1. FPGA project (`build_de25_soc.tcl`, HPS IP)**

- Set `QSPI_OWNERSHIP HPS` (the SPL and U-Boot read QSPI; with SDM
  ownership the SPL's first QSPI access stalls - §5.3).
- Add the HPS-first switch now, defaulting to FPGA-first for Phase A:
  ```tcl
  if {[info exists ::env(HPS_FIRST)] && $::env(HPS_FIRST) == 1} {
      set_global_assignment -name HPS_INITIALIZATION "HPS FIRST"
  } else {
      set_global_assignment -name HPS_INITIALIZATION "AFTER INIT_DONE"
  }
  ```
  (Phase B flips the default to HPS-first with `FPGA_FIRST=1` as the
  escape, exactly like `nano:build_de25_nano_uart.tcl`.)
- **A76 cores on:** in `fpga/hps/ip/hps_subsystem/hps_subsystem_intel_agilex_5_soc_0.ip`
  set the `<ipxact:value>` of `Pwr_a76_core2_on` and `Pwr_a76_core3_on` to
  `true`; in `fpga/hps/hps_subsystem.tcl` (lines 1343-1344) set both to `{1}`
  so re-running that script cannot turn them off again. This is a
  parameter, not an interface change, so editing the `.ip` is enough (the
  Platform Designer GUI is only needed when the HPS component's port list
  changes - `hps/README.md`). Then regenerate explicitly and verify the
  generated HDL (§5.1):
  ```bash
  ./build.sh fpga-project            # build/fpga, copies fpga/hps
  cd build/fpga
  quartus_ipgenerate --generate_ip_file \
      --ip_file=hps/ip/hps_subsystem/hps_subsystem_intel_agilex_5_soc_0.ip \
      --synthesis=verilog --clear_ip_generation_dirs de25_soc -c de25_soc
  grep -rho 'hps_a76_core_selection("[A-Z_]*")' hps/ip/hps_subsystem/hps_subsystem_intel_agilex_5_soc_0/ \
      # must print HPS_A76_CORE_SELECTION_DUAL
  ```
  Reference values (Terasic's Standard GHRD, `~/dev/de25_std/Demonstration/SoC_FPGA/GHRD/hps_subsys/ip/hps_subsys/agilex_hps.ip`):
  `Pwr_a76_core2_on/core3_on = true`, `Pwr_boot_core_sel = 0`.
- Build id now (used from Phase B on): copy `nano:write_build_id.sh` to
  `tools/`, make it write into `build/fpga/` (0b3), and in
  `build_de25_soc.tcl` add the same `exec write_build_id.sh` guard +
  `VHDL_FILE build_id_pkg.vhd` as the Nano tcl. Wire it to register 19 and the board variant to register
  18 in `fpga/register_block.vhd` (two read-only registers - small change,
  do it here so every later core has them).
- A1b (optional, decide now - it changes the periphery and therefore
  needs a new `.jic` every time it changes later): add `HPS_LED`/`HPS_KEY`
  (GPIO1 IO17/IO16) to the HPS pin mux. This changes the HPS component's
  ports, which needs the Platform Designer GUI (`hps/README.md`, "H2F
  User0 clock" trail). Skip unless wanted.
- Build: `./build.sh fpga` (`quartus_syn/fit/sta/asm de25_soc` in `build/fpga`).

Done: synthesis/fit clean; the generated HDL has `..._DUAL`;
`build/fpga/output_files/de25_soc.pin` exists (Phase E hashes it).

**A2. Build script (`linux/build_de25_linux.sh`, rewrite after `nano:linux/build_de25_nano_linux.sh`)**

Keep the Nano script's structure and its checks (each patch is followed
by a `grep` that fails the build if it did not apply). Differences:

| piece | value for the Standard |
|---|---|
| clones | `atf-altera`, `u-boot-altera`, `linux-altera` in `build/linux/src/` (0b3); outputs to `build/linux/out/`. The old `linux/build_output/` is deleted after the first good build |
| ATF | `socfpga_v2.14.1`; `git checkout -- .`; sed `config_ddr_size = 0x80000000;` -> `config_ddr_size = hw_ddr_size;` in `plat/intel/soc/agilex5/soc/agilex5_ddr.c` + grep check; `make PLAT=agilex5 ENABLE_LTO=0 SOCFPGA_UART_CONFIG=1 bl31` |
| U-Boot | `socfpga_v2026.04`; sed the `dualport` line in `drivers/ddr/altera/sdram_agilex5.c` to `plat->dualport = 0;  /* DE25-Standard: single port (Terasic) */` + grep check (adapt the Nano's grep pattern, which looks for "DE25-Nano") |
| U-Boot board files | copy `linux/uboot/socfpga_agilex5_de25_std.dts`, `linux/uboot/socfpga_agilex5_de25_std-u-boot.dtsi` into `arch/arm/dts/`, add `socfpga_agilex5_de25_std.dtb` to the `dtb-$(CONFIG_ARCH_SOCFPGA)` list in `arch/arm/dts/Makefile` (sed after the `socfpga_agilex5_de25_nano.dtb` line, grep check), copy `linux/uboot/socfpga_agilex5_de25_std_defconfig` into `configs/` (A3) |
| U-Boot config | `make socfpga_agilex5_de25_std_defconfig`; `scripts/config --set-str CONFIG_BOOTCOMMAND "bridge enable; run distro_bootcmd"`; check `CONFIG_SYS_SPI_U_BOOT_OFFS` = `0x00A00000`; Phase B adds the preboot |
| Linux | `socfpga-6.18.20-lts`; copy `linux/dts/socfpga_agilex5_de25_std.dts` into `arch/arm64/boot/dts/intel/`, add `dtb-$(CONFIG_ARCH_INTEL_SOCFPGA) += socfpga_agilex5_de25_std.dtb` to that Makefile (as the current script does for `socfpga_agilex5_de25.dtb`); `make defconfig`; then `scripts/config --enable` for `SENSORS_SOC64 FPGA_MGR_STRATIX10_SOC FPGA_BRIDGE FPGA_REGION OF_FPGA_REGION INTEL_STRATIX10_RSU RTC_DRV_PCF85363`; `make olddefconfig`; grep each of those plus `OF_OVERLAY OF_CONFIGFS` for `=y` (the rootfs carries no modules) |
| QSPI clock | in this repo's Linux DTS directly (A4), not by appending in the script |
| removed | toybox/initramfs, the 96 MB `sdcard.img`, both config fragments, the `STRICT_DEVMEM` change |
| outputs | `bl31.bin`, `u-boot.itb`, `spl/u-boot-spl-dtb.hex`, `Image`, `socfpga_agilex5_de25_std.dtb` |

**A3. U-Boot board support (`linux/uboot/`, new)**

Start from upstream's Nano files in `u-boot-altera/arch/arm/dts/`
(`socfpga_agilex5_de25_nano.dts`, `socfpga_agilex5_de25_nano-u-boot.dtsi`,
`configs/socfpga_agilex5_de25_nano_defconfig`) and Terasic's Standard
files (`gh api -H "Accept: application/vnd.github.v3.diff"
repos/terasic/u-boot-socfpga/commits/e905465722` gives all of them).

`socfpga_agilex5_de25_std_defconfig`:
```
#include <configs/socfpga_agilex5_defconfig>
CONFIG_DEFAULT_DEVICE_TREE="socfpga_agilex5_de25_std"
CONFIG_MMC_SPEED_MODE_SET=y
# CONFIG_ISO_PARTITION is not set
# CONFIG_EFI_PARTITION is not set
# CONFIG_SPL_MMC_UHS_SUPPORT is not set
# CONFIG_MMC_UHS_SUPPORT is not set
# CONFIG_SPL_MMC_IO_VOLTAGE is not set
# CONFIG_MMC_IO_VOLTAGE is not set
CONFIG_SYS_SPI_U_BOOT_OFFS=0x0a00000
```
(Upstream's `CONFIG_TARGET_SOCFPGA_AGILEX5_DE25_NANO=y` is not a defined
Kconfig symbol - nothing to copy. Terasic's `CONFIG_SYS_SPI_U_BOOT_OFFS=0x04000000`
is past the end of the 16 MB flash - do not use it.)

`socfpga_agilex5_de25_std.dts` = upstream Nano `.dts` with:
- `model = "SoCFPGA Agilex5 Terasic DE25-Standard";`
- `leds`: only `hps_led0` on `<&portb 17 GPIO_ACTIVE_LOW>` (Terasic), or
  drop the node while HPS_LED is not in the pin mux;
- no `&gpio0`, `&i2c0`, `&i2c3`, `&usb31`; `&usb0`/`&usbphy0` disabled
  (USB0 not in the pin mux); keep `&gpio1`, `&i2c1`, `&uart1`, watchdogs,
  timers, `&qspi` with `flash0` exactly as the Nano;
- **no `&sd_io_1v8_reg` GPIO** (GPIO1 port B bit 3 is a 1.8 V-switch
  control on the Nano; nothing like it is wired here).

`socfpga_agilex5_de25_std-u-boot.dtsi` = upstream Nano `-u-boot.dtsi`
with:
- `&mmc`: keep `disable-wp; cap-sd-highspeed; no-mmc; max-frequency`,
  `sdhci-caps`, the `cdns,phy-*-sd-ds/-sd-hs` and `cdns,ctrl-hrs*-sd-*`
  timing values; set `vqmmc-supply = <&sd_emmc_power>;` (fixed 3.3 V)
  and add `no-1-8-v;`; drop the `&sd_io_1v8_reg` block;
- `&gmac0`: `phy-mode = "rgmii";` (Terasic's Standard U-Boot), PHY at
  `reg = <1>`, `snps,dwxgmac-mdio` as the Nano; drop `&gmac2`;
- `memory` is filled in by the SPL from the EMIF handoff - no fixed node
  (Terasic's fixed `0x40000000` is the same 1 GB).

Terasic's old `combophy0` / `cdns,phy-use-*` / `cdns,hrs*` properties are
**not read** by upstream 2026.04 (its `drivers/mmc/sdhci-cadence6.c` uses
the mode-specific `cdns,phy-*-sd-ds` / `-sd-hs` tables). This is the main
risk of Phase A: the last time this repo ran 2026.04 U-Boot with the Nano's
DT, every SD command timed out. That attempt also had the Nano's 1.8 V
GPIO regulator and a different defconfig, so the cause is not known.

**[HW] A3 test order** (FPGA-first, card unchanged): JTAG-load the
`.sof` with the new SPL embedded
(`quartus_pfg -c build/fpga/output_files/de25_soc.sof build/images/de25_soc_hps.sof -o hps_path=build/linux/out/spl/u-boot-spl-dtb.hex`,
then `quartus_pgm -c "<cable>" -m jtag -o "p;build/images/de25_soc_hps.sof@1"`)
with `u-boot.itb` on a FAT card. Expect `DDR: size check success`, `DDR: init success`,
`Trying to boot from MMC1`, U-Boot banner with `Model: SoCFPGA Agilex5
Terasic DE25-Standard`, `DRAM: 1 GiB`, `mmc0` present, `mmc info` and
`fatls mmc 0:1` work, `sf probe` finds the MT25QU128.

If SD times out, in this order: (1) `max-frequency = <25000000>` and remove
the HS timing entries; (2) compare the controller registers U-Boot programs
(`md.l 0x10808000 0x40`) under Terasic's working `de25-standard-v2025.01`
U-Boot and under ours, and port the differences into the `cdns,*-sd-ds`
values; (3) **interim fallback**: build Terasic's `de25-standard-v2025.01`
U-Boot (`socfpga_agilex5_de25s_defconfig`, with `CONFIG_SYS_SPI_U_BOOT_OFFS=0x00A00000`,
`&qspi` enabled as in the Nano DT, the same `BOOTCOMMAND`/`PREBOOT`) and
keep ATF/Linux upstream. Record which one ships in `docs/linux_boot.md`.

**A4. Linux DTS (`linux/dts/socfpga_agilex5_de25_std.dts`, replaces `socfpga_agilex5_de25.dts`)**

Start from upstream `linux-altera/arch/arm64/boot/dts/intel/socfpga_agilex5_de25_nano.dts`
and Terasic's `socfpga_agilex5_de25s.dts` (Linux `de25-standard-6.12.11-lts`):
- `model = "SoCFPGA Agilex5 Terasic DE25-Standard"`, aliases `serial0 = &uart1`,
  `ethernet0 = &gmac0`, `i2c1 = &i2c1`;
- `&gmac0`: `phy-mode = "rgmii"`, `snps,dwmac-mdio`, PHY `reg = <1>`
  (open question §7: verify traffic, fall back to `rgmii-id`);
- `&mmc`: the upstream Nano block **but** `vqmmc-supply = <&sd_emmc_power>`
  and no `&sd_io_1v8_reg` override; keep `no-1-8-v`; drop the old
  `cdns,phy-use-*` list;
- `&qspi` + `flash@0` + `partitions` with `rsu-handle = <&qspi_boot>` as
  the Nano, **plus the reference clock fix** (§5.4):
  ```dts
  &qspi_clk {
  	clock-frequency = <500000000>;
  };
  ```
- `&temp_volt`: copy Terasic's Standard block (it lists the four die
  temperature channels including "Main Die corner top right max");
- `&i2c1 { rtc@51 { compatible = "nxp,pcf85263"; reg = <0x51>; }; }`
  (ADXL345 at 0x53 optional);
- `&uart1`, `&gpio1`, `&smmu`, `&watchdog0..4` okay; no `&usb0`, no `&spi0`
  (not in the pin mux).

**A5. QSPI image (`linux/make_jic.sh`, rewrite after `nano:linux/make_jic.sh`)**

`DEVICE=MT25QU128`, `FLASH_LOADER=A5ED013BB32AE4SCS`, `SOF=build/fpga/output_files/de25_soc.sof`,
`JIC=build/images/de25_std.jic`, `CORE_RBF=build/images/de25_std.core.rbf`,
`QSPI_UBOOT_OFFS=0x00A00000`, `QSPI_CORE_OFFS=0x00C00000`. Use the Nano's
`.pfg` route (BOOT_INFO, P1 with `hps_path`, UBOOT raw partition, CORE raw
partition when HPS-first). The manifest part is Phase E (E1); write it now
or then.

| QSPI (16 MB) | |
|---|---|
| `0x000000` | boot info |
| `0x200000` | phase 1 (FPGA-first: the whole bitstream, ~3 MB) + SPL |
| `0xA00000` | `u-boot.itb` |
| `0xC00000` | HPS-first only: 4 KB `core_size=0x...` header + core |

**A6. SD card image (`linux/tools/make_sdcard_image.sh` + `alpine_rootfs_config.sh`, copied from the Nano)**

| setting | Standard value |
|---|---|
| DTB | `socfpga_agilex5_de25_std.dtb` (also in `extlinux.conf`) |
| FAT label | `STDBOOT` |
| ext4 label | `std-root` |
| `BOARD_IP` / `BOARD_GW` (rename from `NANO_IP`) | `192.168.1.223` / `192.168.1.1` (confirm the address is free, §7) |
| hostname | `de25-std` |
| `extlinux.conf` append | `console=ttyS0,115200 root=/dev/mmcblk0p2 rw rootwait earlycon panic=-1 kvm-arm.mode=nvhe` (no `nosmp`) |
| `fstab` | `/dev/mmcblk0p1 /boot vfat rw,relatime,noauto 0 0` - the board runs with `/boot` unmounted; only `fpga_access.py` mounts it to write a core (the Nano relies on nothing calling `mount -a`; `noauto` makes it explicit) |
| `rc.local` | as Nano, plus: fixed MAC (below), `hwclock -s` (RTC) before `ntpd`, `hwclock -w` after a successful `ntpd -q` |
| stable MAC | generate one locally administered MAC at image build (`02:de:25:xx:xx:xx`, random tail), store it in `/etc/de25/mac`, and in `rc.local` run `ip link set eth0 address $(cat /etc/de25/mac)` before bringing eth0 up. U-Boot's `NET_RANDOM_ETHADDR` then only affects U-Boot's own TFTP |
| image | 768 MB, FAT 128 MB (~126 MB usable), rest ext4 |

**A7. Recovery path (`linux/tools/sd_recover.py`, `tftp_server.py`)**

Copy from the Nano; replace `push_to_nano.default_console()` with one that
finds the Standard's console by id (Phase 0 step 4), rename `--nano-ip` to
`--board-ip` (default `192.168.1.223`). Everything else (Windows Python
TFTP server under WSL2, CRC32 check, `gzwrite mmc 0`) is unchanged.

**[HW] A8. Bring-up order**

1. Program the FPGA-first `.jic` (`quartus_pgm -c "DE25-Standard [1-1-iface0]" -m jtag -o "pvi;build/images/de25_std.jic"`;
   the cable name as `jtagconfig` lists it on 2026-10-18). **Check the result before power-cycling**: the
   Nano once got "Erase failed on flash chip select 0 at address 0x00C00000" with the flash below it
   already erased - no boot; the same `.jic` programmed again worked.
   The card may be blank: the SPL falls back to U-Boot in QSPI.
2. Power-cycle; `python3 linux/tools/sd_recover.py` writes the Alpine
   image and boots it. First boot runs `apk add python3` (needs internet).
3. Check: `smp: Brought up 1 node, 4 CPUs` (two parts `0xd0b`),
   `/sys/class/hwmon/hwmon*/name` = `soc64hwmon`,
   `/sys/class/fpga_manager/fpga0` exists, `cat /proc/mtd` lists the QSPI,
   `hwclock -r` works (with a coin cell), ping the gateway, `apk update`.
4. QSPI bulk read check (§5.4): `dd if=/dev/mtd0 bs=64k skip=160 count=16 | sha256sum`
   three times = the same as the `u-boot.itb` bytes at `0xA00000` on the
   host (`dd if=build/linux/out/u-boot.itb ... | sha256sum`,
   padded to the same length). Not just the JEDEC id.
5. LWH2F from U-Boot and Linux: `md.l 0x20000010 1` -> `0000de25`
   (**only after `bridge enable`** - it is in `bootcmd`, so a stopped
   autoboot has the bridges in reset and the read is a Synchronous Abort
   and a CPU reset; seen 2026-10-18);
   in Linux a Python mmap read of register 1 (no SIGBUS).
6. **Reboot test only after a power-on boot** (§5.6): power-cycle,
   `reboot`, it must come back.

Fallback: the current Terasic-U-Boot card and the old `.jic`; or step A3's
interim Terasic U-Boot.

**A8 results (2026-10-18, card backed up first, `.jic` from `5221ca0`):**

| check | result |
|---|---|
| `.jic` over JTAG (`DE25-Standard [1-1-iface0]`) | erase, program, verify OK in 33 s; no erase failure |
| SPL 2026.04 from QSPI | DDR4 1 GiB calibrated; **SD works** (the A3 PHY values): loaded u-boot.itb from the card - first the old card's Terasic U-Boot 2025.01, after the rewrite our 2026.04. The Terasic one booted at all because the SPL and its ATF/U-Boot FIT are compatible |
| QSPI reference clock | **400 MHz** (`QSPI: Reference clock at 400000 kHz`), not the Nano's 500 - Linux DT changed to 400 MHz (§5.4) |
| `sd_recover.py` | from the Terasic U-Boot: model check, TFTP 21 MB, CRC32 match, `gzwrite` 805306368 bytes, boot; first boot `apk add python3` over the internet |
| Linux 6.18.20 | 4 CPUs (2x `0xd05` A55, 2x `0xd0b` A76), `soc64hwmon`, `fpga0`, `/proc/mtd` "u-boot" 16 MB; `stratix10-rsu` probe -14 as expected (no RSU layout) |
| QSPI bulk read | 3x the 953752 bytes at 0xA00000 = SHA-256 of the programmed `u-boot.itb`; the first 3 MB twice identical |
| Ethernet | KSZ9031 at reg 1, `rgmii` (not `-id`), 1 Gbps/Full; `192.168.1.223` free, ping both ways; fixed MAC from `/etc/de25/mac` |
| RTC | PCF85263 at `rtc0`, `hwclock -r` works; it came up at 2000-01-01 - no (or a flat) CR1220 cell; NTP sets it |
| LWH2F from Linux (after our U-Boot's `bridge enable`, `BRGMODRST` 0x0) | reg 1 `0000de25`, 2 = git hash `4c5aed81`, 3 loopback, 4 counts, 18 `53544400`, 19 = build id `6ad4f6d2`, 8 counts ~50 MHz; no SIGBUS. With the Terasic U-Boot `BRGMODRST` was 0xf (it does not enable the bridges) |
| reboot after a power-on boot | `re-mounted ... ro`, `Restarting system`, SPL -> U-Boot -> Linux -> eth0 up |
| `poweroff` | the shell stops answering (output not captured) |

Left over, not blocking: our U-Boot also tries an environment in UBI
(`Loading Environment from UBI ... Cannot find mtd partition "root"`) -
harmless noise from the Agilex 5 defconfig, nothing is saved; the
QSPI holds the `u-boot.itb` built before the 400 MHz DT change (U-Boot
unchanged in function); `build/images/de25_std.jic` is regenerated -
program it with the next `.jic` (Phase B).

### Phase B - HPS-first, preboot core loader, fpga-reload

Read `nano:docs/hps_first.md` and `nano:docs/hps_first_boot_research.md`
first.

**B1. Default to HPS-first** in `build_de25_soc.tcl`: `"HPS FIRST"` unless
`FPGA_FIRST=1`. Rebuild.

**B1b. Watchdog triggers a remote update**: HPS IP parameter
`Rst_sdm_wd_config` 0 -> 2 ("trigger remote update") in
`fpga/hps/hps_subsystem.tcl` and
`fpga/hps/ip/hps_subsystem/hps_subsystem_intel_agilex_5_soc_0.ip`, as the
Nano's `bd41771`. Needed only by Phase F's fallback, but it changes the HPS
configuration and so the periphery hash (§5.11): set now, before the first
manifest-carrying core (E1), no core built in B-E stops matching when RSU
comes. Without an RSU layout a watchdog timeout then has no other image to
load - check on the board that a plain-layout HPS-first boot still comes
up and that U-Boot's 30 s watchdog is serviced through to Linux
(`watchdog.open_timeout` default: no expiry until a program opens it).

**B2. `make_jic.sh`**: detect an HPS-first `.sof` with
`quartus_pfg -c "${SOF}" "${CORE_RBF}" -o hps_core_only=ON` (refused for
"AFTER INIT_DONE" images), write the QSPI core copy (4 KB text header
`core_size=0x...\n` padded with zeros, then the core) as raw partition
`CORE` at `0xC00000`, with the size checks from the Nano script.

**B3. U-Boot preboot** (in `build_de25_linux.sh`, as the Nano's, file name
changed):
```bash
scripts/config --enable CONFIG_USE_PREBOOT
scripts/config --set-str CONFIG_PREBOOT "if itest.l *0x10d120dc != 3; then if load mmc 0:1 \${loadaddr} de25_std.core.rbf && fpga load 0 \${loadaddr} \${filesize}; then echo core from SD; else sf probe && sf read \${loadaddr} 0xc00000 0x1000 && env import -t \${loadaddr} && sf read \${loadaddr} 0xc01000 \${core_size} && fpga load 0 \${loadaddr} \${core_size} && echo core from QSPI; fi; fi"
```
(compute the two offsets from `QSPI_CORE_OFFS` like the Nano script, and
grep `.config` afterwards). The `if load && fpga load; then ...; else <QSPI>; fi`
form matters: a card core that reads but does not load must still fall
back to QSPI. `0x10d120dc` is sysmgr `FPGA_CONFIG`; 3 = configured and in
user mode (FPGA-first images, a JTAG `.sof`, or after a software reboot).
`CONFIG_BOOTCOMMAND` stays `bridge enable; run distro_bootcmd`.

**B4. SD image**: copy the core to the FAT partition and to
`/lib/firmware/de25_std.core.rbf`, compile
`linux/tools/fpga_reload/core_reload.dts` (`firmware-name = "de25_std.core.rbf"`,
`config-complete-timeout-us = <30000000>`) to
`/lib/firmware/de25_std_core_reload.dtbo` with `dtc -@`, install
`/usr/sbin/fpga-reload` (Nano script with names changed; the
fallback id check reads register 1 = `0xDE25` and should also check
register 18 = `0x53544400`).

**B5. Kernel**: the FPGA options from A2 are already built in.

**[HW] B6. Install order** (as `nano:docs/hps_first.md`, "Install"):
1. **Card first** (`sd_recover.py`): U-Boot with the preboot + the core.
   On the FPGA-first board the preboot skips (FPGA_CONFIG = 3).
2. **Then QSPI**: the HPS-first `.jic`.
3. Power-cycle.

The other order (HPS-first `.jic`, old card) leaves the fabric
unconfigured: on the Standard the console still works (it is on HPS pins),
U-Boot's `bridge enable` refuses ("FPGA not ready"), Linux boots, and the
web stack must not touch LWH2F (C4 adds that check).

Done when: the console shows the SPL, then `FPGA reconfiguration OK!`
and `core from SD`; `md.l 0x10d120dc 1` = 3 at the U-Boot prompt; Linux
shows `Stratix10 SOC FPGA Manager registered` and `FPGA Region probed`;
`fpga-reload` prints `overlay applied, FPGA manager operating, ~2 s` and
`board id 0xde25`, twice in a row, Linux keeps running; with the card
core deleted, the next power-on prints `core from QSPI`.

**Phase B progress (built 2026-10-18, tested 2026-10-19):**
- B1: `HPS FIRST` is the default, `FPGA_FIRST=1` the fallback (tcl,
  build.sh, READMEs). B1b: `Rst_sdm_wd_config` 2 in the tcl and the `.ip`;
  the generated sopcinfo shows 2. Fit 619 ALMs, timing met (CLOCK0_50 hold
  slack 0.008). P1 0x200000-0x262FFF; CORE 0xC00000-0xCF7FFF; core 1011712
  bytes, build id 1792354926.
- B4: `linux/tools/fpga_reload/{core_reload.dts,fpga-reload}` (Nano's,
  plus the register-18 variant check); the SD image installs the core,
  its `.json`, the `.dtbo` and `/usr/sbin/fpga-reload`.
- B6 step 1: card written with `sd_recover.py` (booted on the FPGA-first
  flash, preboot skipped, `fpga0` + FPGA Region probed). Clean `poweroff`
  seen (`re-mounted ... ro`, `reboot: Power down`).
- B6 step 2: HPS-first `.jic` programmed, verify OK.
- B6 step 3, 2026-10-19: power-on HPS-first boots; sysmgr `FPGA_CONFIG` 3
  and `BRGMODRST` 0 in Linux; LWH2F reg 1 `0000de25`, 18 `53544400`,
  19 `6ad52a6e` (= the build, 1792354926); `fpga0` + FPGA Region probed
  (the manager's first probe defers: "couldn't get service channel").
  (The console of this first boot was not captured.)
- `fpga-reload` twice: `overlay applied, FPGA manager operating, 2.14 s`,
  id and variant right, Linux keeps running. **Bug fixed** (also in the
  Nano's copy): it exited 1 after a good load - `resume() { [ -n "$USERS" ]
  && kill ...; }` returns 1 with no /opt/de25web processes and busybox sh
  makes the EXIT trap's status the script's.
- Card core renamed, power-on: `Failed to load 'de25_std.core.rbf'`, header
  and 1011712 bytes from QSPI 0xC00000/0xC01000, `FPGA reconfiguration OK!`,
  `core from QSPI`, Linux up, the same build id. Card core restored.
- Open: B1b - what a watchdog expiry does with `Rst_sdm_wd_config` 2 and no
  RSU layout (someone at the switch).

Note for the Standard: between power-on and the core load the fabric I/O
is tri-stated, so the MAX6650 runs at its power-up default (loud) for a
few seconds and the LEDs are dark. That is expected.

Fallback: `FPGA_FIRST=1` build + its `.jic`; the U-Boot with the preboot
works with both (it skips when the fabric is configured).

### Phase C - register file v2 and the web GUI

**C1. FPGA (can start during Phase B)**

- Port `nano:source/led_blinkers.vhd` and `nano:source/blinkers/*.vhd`
  (`blinker_pkg`, `blinker_counter`, `blinker_scanner`, `blinker_breathing`,
  `blinker_sparkle`, `blinker_slot`). Make the LED count a constant in
  `blinker_pkg` (`c_leds = 10`) instead of the Nano's fixed eight; the
  scanner sweeps 0..9..0. Mode 0: `LEDR[8:0]` from register 5,
  `LEDR[9]` heartbeat. Registers 13-17 and 20 as §3.3.
- HEX driver (new, small): registers 21-26, common anode (segment pin low
  = lit), hex-digit decode table, blank mask, raw mode. Pins and the
  `1.2-V` I/O standard from `~/dev/de25_std/Demonstration/FPGA/golden_top/golden_top.qsf`
  (`HEX0[0]` BP81 ...); add them to `build_de25_soc.tcl` and ports to
  `de25_soc_top.vhd`. **This changes the periphery** (new pins): do it
  before Phase E's first manifest, or accept one more `.jic`.
- Decouple the LWH2F bridge reset from `CPU_RESET_n`: drive
  `axi_bridge_reset` from the power-on counter only; let the button reset
  only the user logic (or just read it as register 7 bit 4).
- Simulation: copy `nano:sim/led_blinkers_tb.vhd` to `fpga/sim/` and
  `nano:vunit_run_de25_nano_test.py` -> `fpga/vunit_run_de25_std_test.py`
  (output in `build/sim/`, run by `./build.sh sim`), adapt to 10 LEDs; add
  a HEX decode test.

**C2. `linux/webapp/fpga_access.py`** (copy the Nano's, then):
- constants: `CORE_NAME = "de25_std.core.rbf"`, `MANIFEST_NAME = "de25_std.core.json"`,
  `PENDING_NAME = "de25_std.core.pending"`, `OVERLAY_DTBO = "de25_std_core_reload.dtbo"`,
  register numbers per §3.3, `BOARD_ID = 0xDE25`, `BOARD_VARIANT = 0x53544400`
  (check both after a load);
- `WRITABLE` / `RESET_VALUES`: `REG_LOOPBACK, REG_LEDS, REG_FAN_KTACH, REG_BLINKER`
  plus the HEX registers 21-24, so a core reload writes them back;
- fan: the Standard's register 9 is KTACH. Put the conversion in one
  place (`rpm_to_ktach(rpm) = round(119040 / rpm) - 1`, clamped to 0..255;
  `ktach_to_rpm(k) = 119040 / (k + 1)`), and make the lease logic raise
  the fan to `SAFE_FAN_RPM = 4000` (never lower it). Remember: the MAX6650
  has no thermal fail-safe, so the lease is the only net when the loop
  dies (§5.17);
- `--sim`: `SimBridge` for 10 LEDs, 10 switches, 4 keys, HEX segments, a
  MAX6650 that follows the KTACH target with a 1.5 s lag; `ThermalPlant`
  sensor labels from the Standard's `&temp_volt` (they match the Nano's
  four) and a plant calibrated by rpm (re-fit on hardware in C6);
- startup guard (new, for HPS-first with a missing core): before the
  first LWH2F access, read rstmgr `BRGMODRST` (`0x10d1102c`; readable
  from Linux on this board, verified 2026-09-08) and refuse register
  traffic ("fabric not configured") while the LWH2F bit (bit 1) is set;
  re-check every few seconds. Never poke sysmgr/rstmgr *writes* from
  Linux (a raw bridge-enable write panicked this board, `linux/README.md`).

**C3. `linux/webapp/temp_control.py`**: same PI structure (positional,
conditional integration, bumpless auto), actuator in **rpm**:
`FAN_MIN_RPM = 1500`, `FAN_MAX_RPM = 6000` (Terasic `auto_fan.v` top;
confirm in C6), writes `rpm_to_ktach(u)` to register 9 with a 10 s lease.
Starting gains scaled from the Nano (`Kp 16 duty/°C` over 225 duty steps ->
`Kp ~ 320 rpm/°C`, `Ki ~ 11 rpm/(°C·s)`), then tuned against the sim and
the board. Setpoint 42 °C, config in `/opt/de25web/control.json`.
`soc64hwmon` is found by name under `/sys/class/hwmon`.

**C4. `linux/webapp/fpga_web.py`**: decode for the Standard (`levels`
10 entries from regs 14/15/20, `switches` 10, `keys` 4 (+ reset bit),
`hex` from 25/26, `fan.rpm` from reg 10 bits 23:8, `fan.target_rpm` from
reg 9, `fan.status` from reg 11), new `POST /api/hex {"value": ..}` and
`{"raw": [..6 bytes..]}`, `POST /api/fan {"rpm": ..}` instead of `duty`.
`/api/board` reports `board: "de25-std"` and `variant_ok`.

**C5. Board drawing `linux/webapp/static/board.svg`** (new, same approach
as `nano:linux/webapp/static/board.svg`): a top-view drawing after
**Figure 2-1** of `~/dev/de25_std/Manual/DE25-Standard_User_manual_revD.pdf`
(render the page with `pdftoppm -png -r 100 -f <page> -l <page>` and
place parts at the photo's positions). Static parts: PCB, HSMC, 40-pin
GPIO header, HDMI, audio jacks, video-in, Ethernet RJ45, USB-A x2, Type-C,
micro-SD, DDR4 x2, SDRAM, the FPGA (with the die-temperature labels at the
sensor corners, as the Nano's `#soc-sensors`), LCD module. Live parts
with these ids (`app.js` looks them up):

| element | ids | behaviour |
|---|---|---|
| red LEDs | `ledr0`..`ledr9`, classes `led`, `led-glow`, `led-body`, `data-led` | brightness from `levels`; click toggles a bit in mode 0 (not `ledr9`) |
| HEX displays | `hex0`..`hex5`, segments `hexN-a`..`hexN-g` | lit from `hex` |
| slide switches | `sw0`..`sw9` | class `up` |
| keys | `key0`..`key3`, `cpu-reset` | class `pressed` |
| fan | `fan`, `fan-rotor`, `fan-label` | rotor speed from rpm, label shows rpm |
| HPS LED | `hps-led` | static unless A1b was done |

`app.js`, `index.html`, `style.css`: port the Nano's, change the LED bar
to 10, add a HEX card (value input, raw segment toggles), the fan card in
rpm, the control plot's duty axis in rpm. Keep the "FPGA core" and "GUI
release" cards. `VERSION` starts at `1.0.0`.

**C6. Tools**: `install_webapp.py` (console by id, `--board-ip`, token to
`~/.de25web_token_std`), `gui_test.py` (default URL `http://192.168.1.223/`,
10 LEDs, HEX, fan in rpm, `--reload-core`).

**[HW] C7. Bring-up**: `install_webapp.py` on the running board (or a new
card image, which installs the GUI too); `gui_test.py` against the board;
measure the fan: read register 10 at KTACH targets for 1500, 2500, 4000,
6000 rpm for 30 s each, check `config_readback` = 0x29, and re-fit the sim
plant from a step response of the die temperature.

Done: every blinker on the board and in the GUI, HEX follows the API,
switches/keys live, fan rpm tracks the target, loop settles at 42 °C or
reports "saturated low" honestly in a cool room, `gui_test.py` passes
against board and `--sim`.

**Phase C progress (2026-10-19):**
- C1: blinkers with `c_leds` 10 (registers 13-17, 20); `hex_display.vhd`
  (21 value, 22 control: bit 0 raw, **bit 1 flip** - the six digits read
  from the other side of the board, HEXn -> HEX(5-n), each digit turned
  180 degrees -, bits 13:8 blank; 23/24 raw; 25/26 lit); HEX pins at 1.2 V
  from Terasic's `golden_top.qsf`. `CPU_RESET_n` decoupled: `por_reset`
  (counter only) drives the AXI side and `axi_bridge_reset`, the button
  resets only the user registers and reads as register 7 bit 4. Features
  register 16 = 0x3. `./build.sh sim`: `led_blinkers_tb`, `hex_display_tb`
  pass. 1398 ALMs, timing met. On the board: `123AbC` on the displays (the
  user reads them from the top edge: hence the flip), the LED sweep.
- C2-C5: `fpga_access.py`, `temp_control.py`, `fpga_web.py`, `board.svg`,
  `app.js`/`index.html`/`style.css` ported (details in
  `linux/webapp/README.md`). `/api/hex` takes value/raw/blank/flip; the
  HEX card has digit entry, blank buttons, segment clicks and a flip
  checkbox.
- C6: `install_webapp.py`, `deploy_web.py`, `gui_test.py`,
  `de25web-supervisor.sh`; the SD image installs the GUI
  (`alpine_rootfs_config.sh`: `/opt/de25web`, inittab respawn, token kept
  from `~/.de25web_token_std`). `gui_test.py` passes against `--sim`
  (desktop and phone width) and the board.
- On the board: `install_webapp.py` installed it; `deploy_web.py` updated
  it over the network (confirmed); `gui_test.py --reload-core` passes
  (reload 2.3 s, blinker mode and HEX value written back); `fpga-reload`
  from the console goes through `fpga_access.py` (2.14 s).
- **Bug found and fixed**: the first `--reload-core` hung the whole board
  (no ping, no console). The load itself finished; the first register read
  after it did not. The fabric's power-on reset (`g_por_cycles`, ~100 ms)
  holds LWH2F after configuration and BRGMODRST does not show it.
  `fpga_access.py` read register 1 at once; `fpga-reload` only survived
  because Python's start-up took longer. Both now wait 0.5 s (§5.9). The
  Nano's code reads straight after a load too.
- `push_to_board.py`/`install_webapp.py`: busybox `nc -l` never exits after
  the sender closes unless `-w 5 < /dev/null` (§5.16).
- `temp_control.py` logs routine regulating <-> saturated changes at most
  every 30 s (at the 1500 rpm floor the KTACH rounding flipped it every
  second).
- C7 fan (2026-10-19, loop off, 30 s per target; register 10 after 10 s):

  | target (KTACH) | measured rpm |
  |---|---|
  | 1507 (78) | 1560-1620 |
  | 2480 (47) | 2520-2580 |
  | 3968 (29) | 3840-4080, mean 3993 |
  | 5952 (19) | 5520-6060, still rising |
  | 11904 (9), beyond the fan | 6660-6720: the fan's top |

  Register 10 agrees with the target within ~4 % (60 rpm steps), so
  `rpm = 60 x Tach0Count` is right; `config_readback` 0x29. FAN_MAX_RPM
  6000 stays (headroom below the 6700 top). The MAX6650's own regulation
  is slow: ~250 rpm/s up, ~20 s from 6000 down to 1500 - an actuator lag
  the plant model should carry.
- C7 CPU_RESET (PB9) pressed with Linux running: Linux, the GUI and LWH2F
  unaffected; the user registers reset (HEX 123abc -> 0, LEDs 0x155 -> 0);
  register 7 bit 4 seen; the fan briefly sped up (the fabric set the
  MAX6650 up again) and the loop took it back to 1500 rpm. §5.18 closed.
- C7 thermal: the sim plant stays the first guess (decided 2026-10-19:
  not worth an accurate fit). On the board the die sits at 35-40 °C at
  1500 rpm in this room, so at 42 °C the loop reports "saturated low",
  which is the honest answer; the gains stay at Kp 320, Ki 11.
- Not run: the full-CPU-load check of `SAFE_FAN_RPM` (§5.17).

### Phase D - GUI updates over the network

Copy unchanged in logic: `nano:linux/board/de25web-supervisor.sh` (three
processes, release on test for 120 s, revert on no-confirm / 3 crashes /
restart during test, `previous` link, newest 4 releases kept),
`nano:linux/tools/deploy_web.py` (pack, `POST /api/update` with `X-Sha256`
and `X-Token`, wait, check version + board id, confirm). Additions for two
boards on one LAN:
- a `BOARD` file (`de25-std`) in each release; `/api/update` refuses a
  release whose `BOARD` differs from the running one; `deploy_web.py`
  checks `/api/board` -> `board` before uploading;
- `deploy_web.py` defaults: `--host 192.168.1.223`, `--token-file ~/.de25web_token_std`.

Test the supervisor cases locally first (the Nano did it with a copy of
the layout, busybox `sh`, `fpga_web.py --sim`, `DE25WEB_BASE/PORT/RUN/TEST_SECONDS`,
`DE25WEB_ARGS=--sim`; keep `DE25WEB_RUN` short - §5.20): good update, two
updates within the test time, no confirmation, a release that crashes, a
restart during the test, rollback onto a broken release. **[HW]** Then
one good update and one deliberately broken release on the board.

**Phase D progress (2026-10-19):**
- `linux/webapp/BOARD` (`de25-std`) in every release; `/api/update`
  refuses (400) a release whose `BOARD` is another board's or missing (a
  DE25-Nano release has none); `/api/version` reports `board`;
  `deploy_web.py` checks it before uploading (falling back to
  `/api/board` for older releases).
- **Fixed**: an upload while another release was still on test made that
  unconfirmed release `previous`, so a failed test reverted to a release
  nobody had confirmed, and it then stayed. `previous` now stays the last
  confirmed release; pruning keeps it.
- `linux/tools/supervisor_test.py`: the cases above against the real
  supervisor under busybox `sh` with `--sim` (good, two updates, two
  unconfirmed, no confirmation, crash, restart during the test, rollback
  onto a broken release, wrong board): all pass, ~2 min.
- On the board: `deploy_web.py` update confirmed; a release whose server
  exits at once was reverted after 3 exits (11 s after its start, the
  first release back answering after 17 s); a `de25-nano` release refused
  with 400. Loop and fan unaffected.

### Phase E - FPGA core updates over the network

Reference: `nano:docs/hps_first.md` "A new core over the network", commit
`be159b5`.

**E1. Manifest** (`make_jic.sh`, HPS-first only): `de25_std.core.json` next
to the core with `build_id` (from `build_id_pkg.vhd`; refuse if that file
is newer than the `.sof`), `board: "de25-std"`, `core_size`, `core_sha256`,
`periphery_sha256`, `git`, `built`. Periphery hash = SHA-256 over the
non-comment, non-empty lines of `build/fpga/output_files/de25_soc.pin` plus the
SHA-256 of `fpga/hps/ip/hps_subsystem/hps_subsystem_intel_agilex_5_soc_0.ip`
and `fpga/hps/ip/hps_subsystem/hps_subsystem_emif_io96b_hps_0.ip` (§5.11).
Install the manifest on the card next to `/lib/firmware/de25_std.core.rbf`.

**E2. `fpga_access.py` ops** (already in the copied file): `core`,
`reload`, `install_core` - refuse on size/SHA mismatch, on a different
periphery hash, and (new) on a different `board`; keep `.prev`; write the
`.pending` marker; load; check board id, variant and build id; write back
registers; on failure restore `.prev` and load it; on success write the
card copy (`mount /boot`, write `.new`, fsync, rename, `umount`);
recover a leftover `.pending` at startup. Register traffic stays paused
for the **whole** load, with no time limit (§5.9).

**E3. `fpga_web.py`**: `GET /api/fpga`, `POST /api/fpga` (bundle,
`X-Sha256`, `X-Token`, `X-Force`), `POST /api/fpga/reload`; GUI card.
**E4. `linux/tools/deploy_fpga.py`**: core names, host, token file;
`--pack-only`, `--reload`, `--force` (first install on a card whose core
has no manifest).

**[HW] E5. Tests** - see §6 (Phase E rows).

**Phase E progress (2026-10-19):**
- E1-E3 came with the Phase C port (manifest in `make_jic.sh`, the
  `fpga_access.py` ops with the `board` check, the API and GUI card).
  E4: `linux/tools/deploy_fpga.py` ported (host .223, `~/.de25web_token_std`,
  `build/images`, checks the manifest's and the board's `board`).
- Row 25: 100 of 100 reloads through `/api/fpga/reload`, 2.14 s mean
  (2.14-2.33), HEX `a5b6c7`, blinker scanner and fan target written back
  every time.
- Row 26: refused (409) before anything was touched: wrong periphery,
  truncated, corrupt (SHA), `de25-nano` manifest, too big, not a tarball;
  upload SHA mismatch 400, wrong token 403. Running/installed/previous
  unchanged.
- Row 29: a fresh build (1792429546, same periphery `b5d09be0b5b1`)
  installed by `deploy_fpga.py` in 2.14 s, register 19 matches, card copy
  SHA-256 = the manifest's; the old core kept as `.prev`.
- A load that fails after it was accepted (manifest with another build
  id): 500, the previous core loaded back (`rolled_back`). The `.prev` is
  used up by that: no previous until the next good install.
- Row 27: a leftover `.pending` (simulated: `.prev` files, a changed
  manifest, `fpga_access.py` restarted) - the previous core is the
  installed one again, `last_load` says so.
- `gui_test.py --reload-core` passes against the new core.
- Not run: row 28 (power cut during the card write; the write is `.new`
  + fsync + rename, and the QSPI fallback for a missing card core was
  shown in Phase B), row 30 (corrupt core, needs someone at the switch).
- **Found**: after ~105 reloads in quick succession the MAX6650 stuck in
  full-on (config readback 0x09 instead of 0x29, fan ~6600 rpm), with
  either core; fabric reloads re-ran the setup and it still read 0x09; a
  power cycle cleared it. Not reproduced by a slow-down alone nor by a
  reload during one. Also: every reload sends the fan to full speed for a
  few seconds - Terasic's setup writes Config 0x0A (software full-on)
  before 0x29. Follow-up: GUI warning, setup verify/retry and periodic
  Config/Alarm Status reads in the fabric, no 0x0A step (§5.17b).

### Phase F - later

- **RSU** (phase 1 + U-Boot + core updates with SDM fallback). Done and
  tested on the Nano 2026-10-18 (`60752c9`..`dfec54d`, R1-R7); port it
  step by step. Reference: `nano:docs/remote_system_update_plan.md`,
  `nano:docs/network_updates.md` (the recipes). Steps:
  - **F1 flash layout** (`make_jic.sh RSU=1`, the Nano's default): BOOT_INFO
    0x000000-0x20FFFF (RSU makes it 0x210000 long), FACTORY_IMAGE 0x220000
    (1 MB), SPT0/1 0x320000/0x328000, CPB0/1 0x330000/0x338000, P1 0x400000
    (1 MB), SSBL.FACTORY_IM 0x500000, SSBL.P1 0x600000, UBOOT 0xA00000,
    CORE.FACTORY_IM 0xC00000, CORE.P1 0xD10000. **Fixed addresses**:
    quartus_pfg 26.1.1 stops with an internal error on "auto" here. Check
    our sizes: FPGA-first P1 is ~0.7 MB today, HPS-first phase 1 ~0.4 MB;
    u-boot.itb ~0.9 MB fits 1 MB SSBL slots.
  - **F2 per-image U-Boot**: `CONFIG_SOCFPGA_RSU_MULTIBOOT`; the SPL loads
    `u-boot_<slot>.itb` from the card, else QSPI `SSBL.<slot>`;
    `make_sdcard_image.sh` writes `u-boot_P1.itb` and
    `u-boot_FACTORY_IMAGE.itb`.
  - **F3 bundle**: `make_jic.sh` also writes `de25_std_app.rpd` (start
    address 0, bitswapped); `linux/tools/make_rsu_bundle.py` (reproducible
    tar.gz: app.rpd, u-boot.itb, core + manifest, `rsu.json` with size +
    SHA-256 each; `--check`). Add `board: "de25-std"` to `rsu.json` and
    refuse a Nano bundle on the board (as D/E do).
  - **F3b a core per image**: `nano:linux/patches/u-boot-rsu-running-slot.patch`
    (`rsu running_slot <var>`); the preboot loads
    `de25_std_<slot>.core.rbf` from the card, else `CORE.<slot>`;
    `fpga_access.py` keeps cores in `/lib/firmware/rsu/<slot>/`.
  - **F4 userspace**: static `rsu_client` (altera-fpga/intel-rsu, pinned,
    + zlib 1.3.1) from `build_de25_linux.sh`, `/etc/librsu.rc` `root qspi
    /dev/mtd1`. **The Linux DT needs two QSPI partitions**: "u-boot"
    0x0-0x31FFFF read-only (boot info + factory image; nothing in Linux
    can write it) and "root" from SPT0 0x320000 - librsu reads "Bad SPT0
    magic number" from one partition at 0x0, which is what
    `linux/dts/socfpga_agilex5_de25_std.dts` has today (A4, plain layout).
  - **F5 boot confirmation**: B1b's `Rst_sdm_wd_config` 2;
    `nano:linux/board/rsu-confirm.sh` (first line of rc.local) pets the
    watchdog until `/api/board` says `"id_ok": true`, then confirms; not
    healthy after 300 s -> the SDM loads the factory image. The factory
    image only reports (shared rootfs). Kernel `watchdog.open_timeout=120`
    in extlinux.conf.
  - **F6 network update**: `fpga_access.py` op `install_rsu` behind
    `POST/GET /api/rsu`, `linux/tools/deploy_rsu.py`, the GUI "FPGA image"
    card. Order: check everything, erase P1 first, SSBL.P1 + CORE.P1, card
    and /lib/firmware copies, image last with `--add --verify`, then
    `reboot_image` = P1's address (`rsu_client --request` of the running
    slot does not reload it).
  - **[HW] F7 fault tests** as the Nano's R7: no token / wrong SHA /
    truncated or corrupt parts / core bundle / too big refused before any
    write; power cut after the P1 erase boots the factory image and a
    re-deploy from there works; a hung or never-healthy P1 falls back. Not
    a corrupt image with a matching manifest (SDM hang risk, §5.8).
  - Nano notes to keep: librsu's relocation differs from quartus_pfg's in
    two pointer bytes, so `--verify` fails against a `.jic`-written slot
    (passes after `--add`; both boot); after a slot switch the console is
    silent until the preboot has loaded the core (HPS-first).
- **Phase F progress (2026-10-19):** F1-F6 built (`c52c00b`): RSU layout
  by default for HPS-first (FPGA-first's ~3 MB bitstream does not fit a
  1 MB slot, RSU=0 there), `de25_std_app.rpd` 0.8 MB, bundle 2 MB.
  - Card written with `sd_recover.py` on the plain flash: boots as before
    (no SPT: the preboot uses the plain names). First boot found two
    image faults, fixed in `124d736`: eth0 stalled after the warm reboot
    and `rc.local`'s `ntpd`/`apk add python3` ran before `eth-watchdog`
    could bounce it (no python3 -> no GUI -> `rsu-confirm` would have let
    the watchdog fire: stopped with TERM at 47 s); and a new random MAC per
    image left the LAN's ARP caches on the old one. Now: network work in
    the background after the gateway answers, gratuitous ARP, MAC kept in
    `~/.de25_std_mac`. The stratix10-rsu sysfs files are absent on a plain
    flash (present with RSU).
  - RSU `.jic` programmed (verify OK), power cycle: `rsu_spl_mmc_filename,
    filename: u-boot_P1.itb`, `core de25_std_P1.core.rbf from SD`,
    `rsu-confirm: image 0x00400000 healthy after 13 s - confirmed`;
    `rsu_client --count` 6, P1 0x400000 priority 1; `/lib/firmware/
    de25_std.core.rbf -> rsu/P1/...`; `/api/rsu` slot P1, confirmed, no
    failures; `gui_test.py --reload-core` passes with the FPGA image card.
    The SPL banner prints twice ("Bloblist at 72000 not found" between).
  - `deploy_rsu.py` end to end (bundle 1792432492 over the same build):
    written in 16.0 s (erase P1, SSBL.P1, CORE.P1, card, /lib/firmware,
    write + verify P1), reboot, SPL `u-boot_P1.itb`, `core
    de25_std_P1.core.rbf from SD`, link up at 5 s, `rsu-confirm` confirmed
    at 12 s; the tool saw it 61 s after the upload. `/api/rsu` now shows
    "P1 holds build 1792432492" (the `.jic`-written P1 had no rsu.json).
  - F7 refusals, `linux/tools/rsu_refusal_test.py`: 13/13 refused before
    any erase, board unchanged after each (no/wrong token 403, wrong SHA
    and over 32 MiB 400; random bytes, cut archive, core bundle, nano
    board, wrong kind, truncated/corrupt/missing part, app.rpd over P1's
    1 MB with a matching manifest 409). It found a client fault: the board
    answers a header refusal (token, size) at once and closes without
    reading the body, and urllib - still sending - got a broken pipe
    instead of the 403. `deploy_web.request` (used by deploy_web/fpga/rsu)
    now sends the headers, waits 1 s for an early answer, then the body;
    all three print the 403 with a wrong token.
  - Next: the watchdog fallback (kill rsu-confirm - also closes B1b) and a
    power cut after the P1 erase (someone at the switch).
- **Partial reconfiguration** of the blinkers:
  `nano:docs/partial_reconfiguration_plan.md` (written for the Nano; the
  same structure applies with 10 LEDs).
- **Ethernet hardening**: see §5.14; take over whatever the Nano finds.
- Optional GUI items: ADT7461 board temperature, ADXL345, HPS LED/KEY.

---

## 5. Gotchas from the Nano work, and Standard-specific ones

### 5.1 Stale generated IP
Editing an `.ip` (the Nano: `Pwr_a76_core2_on/_core3_on`) changed nothing
until the IP was regenerated: the generated HDL still selected
`HPS_A76_CORE_SELECTION_OFF`, the Nano project's policy was "Never
Regenerate IPs", and Linux printed `CPU2: failed to come online` /
`failed in unknown state : 0x0` (ATF's PSCI CPU_ON reports success
without checking power). Also, the tcl that created the subsystem
(`hps_subsys.tcl`) still had `{0}` and would have reverted the `.ip`.
Avoid: set the parameter in the `.ip` **and** `hps/hps_subsystem.tcl`;
regenerate explicitly (`quartus_ipgenerate --generate_ip_file --ip_file=<ip>
--synthesis=verilog --clear_ip_generation_dirs de25_soc -c de25_soc`);
grep the generated synth file for `HPS_A76_CORE_SELECTION_DUAL` before
fitting. This repo's `ALWAYS_REGENERATE_IP` helps but is not a proof.

### 5.2 HPS-first specifics
- Build with `HPS_INITIALIZATION "HPS FIRST"`; the `.jic` then holds only
  phase 1 (SDM firmware, HPS I/O, DDR I/O, SPL). The core is
  `quartus_pfg -c x.sof x.core.rbf -o hps_core_only=ON` (or `-o hps=ON`
  with `hps_path`, which also writes the `.hps.rbf`).
- Nothing loads the core unless U-Boot does: `CONFIG_PREBOOT` (B3), only
  when `FPGA_CONFIG` (`0x10d120dc`) != 3, SD FAT first, QSPI copy with a
  4 KB `core_size=` header for `env import` second, and the QSPI fallback
  must also run when `fpga load` of the SD core fails.
- On the Nano the console (UART1 through the fabric) is silent until the
  core is loaded; first line ` FPGA reconfiguration OK!`. **Not so on the
  Standard** (UART1 on HPS pins), but fabric I/O (LEDs, HEX, fan I2C,
  `GPIO_D` UART) is dead until then.
- `CONFIG_BOOTCOMMAND` needs `bridge enable` before Linux; without it the
  first LWH2F access in Linux is a SIGBUS (the web GUI exits with 135).
  This is also what the Standard hit on 2026-09-08 - not `STRICT_DEVMEM`.
- A core belongs to its phase 1 (same HPS I/O, DDR config, Quartus
  version). Card first, then `.jic` (B6).

### 5.3 QSPI ownership
`QSPI_OWNERSHIP HPS` is required for the SPL/U-Boot to read QSPI; with
SDM ownership the first QSPI controller access stalls the bus (the Nano's
SPL hung or was reset by its watchdog after `WDT: Started watchdog`).

### 5.4 Linux QSPI reference clock
The dtsi fixes `qspi_clk` at 200 MHz; the SDM gives the controller 500 MHz
(U-Boot prints `QSPI: Reference clock at 500000 kHz`; sysmgr boot scratch
`0x10d12200` holds it in kHz). Linux then divided for the wrong clock and
ran the flash at ~250 MHz: JEDEC id shifted by one bit (`90 5d 8c`
instead of `20 bb 18`), bulk reads different every time. Fix:
`&qspi_clk { clock-frequency = <500000000>; };`. Verify with a **bulk
read of known content** compared on the host, three times - a wrong
`cdns,read-delay` can pass the id read and still corrupt data. Check the
U-Boot line on the Standard too; if it differs, use its value.
**Standard, 2026-10-18:** the SPL prints `QSPI: Reference clock at 400000 kHz`;
`linux/dts/socfpga_agilex5_de25_std.dts` sets 400 MHz.

### 5.5 ATF and U-Boot DDR patches
ATF: `config_ddr_size = hw_ddr_size` (else `DDR: Configured DDR size is
greater than the hardware size - HANG` on 1 GB boards); build with
`SOCFPGA_UART_CONFIG=1` (console on UART1 - true for the Standard too).
U-Boot: `plat->dualport = 0` for the single-port IO96B EMIF - Terasic's
DE25-Standard U-Boot makes exactly that change, so apply it.

### 5.6 "Reboot hangs" is a JTAG artifact
A session started by a JTAG `.sof` load cannot `reboot`: the SPL came over
JTAG, the SDM accepts `REBOOT_HPS` but has nothing to restart the HPS
from - silence after `reboot: Restarting system`. After a power-on boot
from QSPI, `reboot` works. Days were lost on ATF/kernel/QSPI theories.
Test reboot only after a power cycle.

### 5.7 After a software reboot the fabric stays configured
`REBOOT_HPS` restarts only the HPS; the preboot sees `FPGA_CONFIG` = 3 and
skips; the running core stays (including one loaded by `fpga-reload`).

### 5.8 A corrupt core hangs the SDM
A core with 64 bytes flipped and a manifest made to match it did not fail
the load: it never returned, and JTAG stopped answering. Only a power
cycle recovered. Rollback cannot help; the SHA-256 check against the
manifest, before anything is touched, is the guard. Never run that test
without someone at the power switch.

### 5.9 LWH2F during reconfiguration
An LWH2F access while the fabric reconfigures can hang the CPU. All
register access goes through one process (`fpga_access.py`), which pauses
traffic for the **entire** load with no time limit (a 120 s limit expired
during a hung load and the next read hung the CPU). Clients must not
resend non-idempotent requests after a read timeout. Without the GUI,
`fpga-reload` SIGSTOPs every `/opt/de25web` process around the load.

**And for ~100 ms after it** (Standard, 2026-10-19): the fabric's own
power-on reset (`register_block.vhd`, `g_por_cycles`) holds the LWH2F
bridge after configuration, invisible in BRGMODRST; a read in that window
hung the whole board (no ping, no console, power cycle). `fpga_access.py`
and `fpga-reload` wait 0.5 s (`POST_LOAD_SETTLE_S`) before the first access.
(The Standard's fabric UART, a second master, was removed in 0b.)

### 5.10 Do not raw-poke the bridges from Linux
On this board a hand-written write to `SYSMGR_FPGA_BRIDGE_CTRL`
(`0x10d1205c`) from Linux crashed the kernel with an SError. Use U-Boot's
`bridge enable` (it checks `FPGA_CONFIG` first) and the kernel's FPGA
manager; reads of rstmgr are fine.

### 5.11 Compatibility key: periphery hash, not phase-1 hash
Two builds of the same periphery differ in the phase-1 bitstream (~182
bytes of per-build hashes), and the SDM loads either build's core. Use a
periphery hash: the fitter `.pin` table (non-comment lines; it names the
Quartus version and the device) + the HPS and EMIF `.ip` files. Build id
= Unix time stamped into `build_id_pkg.vhd`, readable in register 19; the
manifest carries the same number and it is checked after every load.

### 5.12 Interrupted install, card writes
Write a `.pending` marker before loading, remove it after success or
rollback; on startup, a leftover marker means restore `.prev`. Keep the
card's FAT partition unmounted normally (`noauto`), mount only to write
the core copy: write `.new`, fsync, rename, unmount. The card copy is only
written after a good load, so a power cut leaves the old or the new core.

### 5.13 Small FAT partition
128 MB (~126 MB usable): two ~48 MB kernels do not fit. Keep backups
(old `Image`, `.dtb`, `u-boot.itb`) on the ext4 rootfs.

### 5.14 Ethernet
U-Boot's `NET_RANDOM_ETHADDR` gives a new MAC every boot (A6 sets a fixed
one in Linux). On the Nano (Linux 6.18.20, XGMAC + KSZ9031), about 1 in 5
warm reboots (none seen after power-on) eth0 has link but passes no
traffic, in two forms: the RX DMA stops (SMMU `F_TRANSLATION` faults on
the EMAC descriptor rings at the first open, then a fatal bus error;
frames reach the MAC and overflow its FIFO, `rx_packets` stays 0), or
transmitted frames are lost after the MAC (the MAC counts them, the host
never sees the ARP replies). Ruled out there: the old kernel's DMA running
across the reboot (stopping eth0 before `reboot` did not help) and the PHY
delay mode (`rgmii-id` breaks the Nano's link every time - its board
carries the delays; check the Standard's own PHY wiring before choosing).
`ip link set eth0 down; ip link set eth0 up` clears both. Copy the Nano's
workaround: `linux/board/eth-watchdog.sh`, installed as
`/usr/sbin/eth-watchdog` and respawned from inittab - it pings the gateway
(every 5 s for 2 minutes after boot, then every 30 s), bounces eth0 after
3 misses, restores the default route (a link down flushes it) and logs to
the kernel log. Test warm reboots in a loop (15+) before relying on
network-confirmed reboots (RSU). Adopt the Nano's root-cause fix when it
exists.

### 5.14b Clean shutdown (busybox init)
Busybox init runs the `::shutdown` actions before it kills any process.
With the web GUI running (logs open for writing), `::shutdown:/bin/umount
-a -r` cannot remount / read-only, so every reboot resets a read-write
root. On the Nano a run of ~20 test reboots broke the ext4 journal ("error
loading journal", -74, boot loop) and the card had to be rewritten. Use the
Nano's inittab order: `killall5 -15`, `sleep 2`, `killall5 -9`, then
`umount -a -r`; check the console shows `re-mounted ... ro` before
`reboot: Restarting system`. Do this before any reboot loop testing.

### 5.15 Clock and DNS at boot
The Nano has no RTC: the clock starts at 1970, `apk` fails TLS until
`ntpd` has run, and DNS may fail the first seconds (`sleep 2` before
`ntpd -q` in `rc.local`). The Standard has a PCF85263A RTC with a coin
cell holder: `hwclock -s` early gives a sane clock if a cell is fitted;
keep NTP for accuracy and `hwclock -w` after it.

### 5.16 Driving the board console from scripts
- Alpine's prompt emits `ESC[6n` (cursor position query), which breaks
  naive reply parsing; strip escape sequences and use run-once markers
  such as `echo X$((1+1))Y` (the echoed command contains `$((1+1))`, only
  the output contains `X2Y`).
- No scp/ssh: push files with `nc` (board listens, host connects), the
  listener started over the console as `nc -l -p PORT -w 5 < /dev/null >
  FILE`: without `-w` and stdin from `/dev/null` busybox `nc` never exits
  after the sender closes.
- The board-side socket timeout is short (5 s): stage large files in
  `/tmp`.
- Never `pkill -f` a pattern that also matches the command line doing the
  killing.

### 5.17 MAX6650 has no thermal fail-safe (Standard)
Unlike the Nano's AMC6821, nothing on the fan chip raises the fan on
over-temperature. The 10 s lease in `fpga_access.py` (raise to 4000 rpm)
and the loop's "no temperature for 5 samples -> fan up" rule are the only
nets. Do not lower `SAFE_FAN_RPM` below what holds the die at a safe
temperature under full load (measure in C7).

### 5.17b MAX6650 stuck in full-on (Standard)
Seen once (Phase E, after ~105 back-to-back core reloads): Config read
back 0x09 (mode 00 = software full-on) where 0x29 was written; every later
fabric setup was acknowledged and still read 0x09; only a power cycle
(the chip stays powered across fabric reloads) cleared it. Safe (the fan
at full speed), but the loop has no control then. Since then: the GUI and
`temp_control.py` warn when Config is not 0x29; the fabric clears the bus
before each setup, reads Config/Alarm Status/GPIO Status about once a
second and sets the chip up again when Config is wrong (register 11, see
`docs/de25_std_fan.md`); Terasic's Config 0x0A step is gone, so a reload
no longer sends the fan to full speed.

### 5.18 CPU_RESET_n resets the LWH2F bridge side (Standard)
`axi_bridge_reset <= system_reset`, and `system_reset` follows the
button. Fixed in C1 (the bridge side runs from the power-on counter only);
confirmed in C7: pressing it with Linux running resets only the user
registers.

### 5.19 WSL2 host
USB devices must be attached with `usbipd.exe attach --wsl --busid <id>`
after every replug or `wsl --shutdown`. JTAG cable names change with the
USB port - check `jtagconfig` every session and name the cable in
`quartus_pgm` (several boards may be attached). The board cannot reach a
server inside WSL's NAT: `sd_recover.py` runs the TFTP server on Windows
Python.

### 5.20 Unix socket path limit
Socket paths are limited to ~108 bytes: keep `DE25WEB_RUN` and simulation
run directories short (e.g. `/tmp/de25web-sim`).

### 5.21 Web stack design (keep it)
Three processes: `fpga_access.py` (sole `/dev/mem` user; one lock;
pause/resume; fan lease dead-man switch; core loads), `temp_control.py`
(PI loop on the hottest SoC sensor via `soc64hwmon`, needs
`CONFIG_SENSORS_SOC64=y`), `fpga_web.py` (HTTP, never touches
`/dev/mem`). A supervisor outside the releases (test/confirm/revert).
Token-protected updates. `--sim` everywhere for development without the
board. Headless-Chromium `gui_test.py`.

### 5.22 Kernel options built in (no modules on the rootfs)
`SENSORS_SOC64`, `FPGA_MGR_STRATIX10_SOC`, `FPGA_BRIDGE`, `FPGA_REGION`,
`OF_FPGA_REGION`, `OF_OVERLAY`, `OF_CONFIGFS`, `INTEL_STRATIX10_RSU`;
Standard: `RTC_DRV_PCF85363`. Grep `.config` for `=y` in the script.

### 5.23 SD on upstream U-Boot (Standard)
See A3: upstream 2026.04's SD driver uses different DT properties from
Terasic's fork, and the Nano's DT assumes a 1.8 V switch GPIO the
Standard does not have.

---

## 6. Testing checklist

Run the simulation and host-side checks at every change; the **[HW]** rows
need the board.

| # | phase | test | pass |
|---|---|---|---|
| 1 | A | generated HPS HDL | `HPS_A76_CORE_SELECTION_DUAL` |
| 2 | 0b/A | `./build.sh all` from a fresh clone, then again | every patch grep passes; outputs present; nothing written outside `build/` |
| 3 | A [HW] | power-on boot, card present | SPL -> ATF -> U-Boot (`DE25-Standard`, 1 GiB) -> Linux -> Alpine shell, unattended |
| 4 | A [HW] | blank card | SPL falls back to QSPI U-Boot (`Trying to boot from SPI`), `sd_recover.py` writes and boots the card |
| 5 | A [HW] | CPUs | `smp: Brought up 1 node, 4 CPUs`, `/proc/cpuinfo` parts 0xd05 x2, 0xd0b x2 |
| 6 | A [HW] | QSPI in Linux | JEDEC `20 bb 18`; bulk read of `u-boot.itb` region matches the host, 3 times |
| 7 | A [HW] | reboot after a power cycle | comes back; never judge reboot after a JTAG start |
| 8 | A [HW] | network | static IP, fixed MAC, ping gateway, `apk update` (TLS), 10 power cycles with link each time |
| 9 | A [HW] | RTC | `hwclock -r` sane; with a cell, time survives power-off |
| 10 | A [HW] | LWH2F | U-Boot `md.l 0x20000010 1` = `0000de25`; Linux mmap read, no SIGBUS |
| 11 | B [HW] | HPS-first power-on | `FPGA reconfiguration OK!`, `core from SD`, `0x10d120dc` = 3 |
| 12 | B [HW] | card core missing | `core from QSPI` |
| 13 | B [HW] | card core damaged (truncated file) | QSPI fallback still loads |
| 14 | B [HW] | `fpga-reload` x2 | `overlay applied`, `operating`, ~2 s, `board id 0xde25`; Linux keeps running |
| 15 | B [HW] | reboot after power-on boot in HPS-first | comes back; preboot skips (fabric still configured) |
| 16 | C | VUnit | blinkers (10 LEDs), HEX decode, fan model pass |
| 17 | C | `--sim` stack + `gui_test.py` | passes, screenshots desktop and phone width |
| 18 | C [HW] | `gui_test.py` on the board | passes; every blinker; LED click; HEX; switches/keys live |
| 19 | C [HW] | fan | rpm tracks KTACH targets 1500..6000; `config_readback` 0x29 |
| 20 | C [HW] | control loop | settles at 42 °C (or reports saturated low); kill `temp_control.py` -> lease raises the fan within 10 s; supervisor restarts it bumplessly |
| 21 | C [HW] | missing core guard | HPS-first with no core anywhere: `fpga_access.py` reports "fabric not configured", no hang |
| 22 | D | supervisor cases (local) | good update, two updates in the test window, no confirm, crashing release, restart during test, rollback onto broken - all end on a good release |
| 23 | D [HW] | `deploy_web.py` good + broken release | good one confirmed; broken one reverted within 120 s |
| 24 | D | cross-board release | refused (BOARD mismatch) |
| 25 | E [HW] | reload loop | 100 of 100 via `/api/fpga/reload`, ~2.1 s each, blinker mode / HEX / fan kept |
| 26 | E [HW] | wrong periphery, truncated core, Nano core | refused (409) before anything is touched |
| 27 | E [HW] | interrupted install | leftover `.pending` -> `.prev` restored at next start |
| 28 | E [HW] | power cut while writing the card copy | card keeps old or new core; if missing, QSPI core loads |
| 29 | E [HW] | end to end | fresh build (new build id, same periphery) deployed with `deploy_fpga.py`, card copy written, register 19 matches |
| 30 | E [HW] | **corrupt core with matching manifest** | **only with a person at the power switch**; expected: SDM hang, power cycle recovers; confirms the SHA-256 guard is the only defence. Optional - the Nano already showed the behaviour |

---

## 7. Open questions to resolve on hardware

| question | how to answer |
|---|---|
| Does upstream U-Boot 2026.04 read the SD card with the A3 DT? | A3 test; fallbacks listed there |
| `phy-mode = "rgmii"` or `"rgmii-id"` on the Standard (Terasic uses `rgmii`, this repo's DT `rgmii-id`) | with each: ping, then a 100 MB `wget` and `ip -s link` error counters in U-Boot (`tftpboot`) and Linux |
| Which `/dev/serial/by-id/` entry is the HPS console (CP2105 vs FT2232H / USB-Blaster III - depends on the board revision; Terasic's working U-Boot branch says "revC") | Phase 0 step 4; also read the board's silkscreen revision |
| JTAG cable name for this board | `jtagconfig` |
| Is `192.168.1.223` free on the LAN? | ask the user / `ping` before use |
| Does the SDM report 500 MHz for the QSPI reference clock here too? | **No: 400 MHz** (SPL, 2026-10-18); the Linux DT uses it |
| Is a CR1220 cell fitted? | `hwclock -r` after a power-off |
| Fan: max rpm, and is reg 10's `rpm = 60 x Tach0Count` right with the 0.5 s count window (Count register 0x01)? | **~6700 rpm top; yes** - register 10 tracks the MAX6650's own regulated target within ~4 % (C7) |
| Safe fan rpm under full CPU load (no MAX6650 fail-safe) | not run yet: `yes > /dev/null` on the 4 cores, fan at 1500 vs 4000 rpm, watch the die sensors |
| Is MAX6650 GPIO1 (configured as FULL-ON input) wired to an over-temperature signal on the board? | schematic `~/dev/de25_std/Schematic/DE25-Standard.pdf` |
| Does the ethernet RX stall seen on the Nano happen here? | 20 warm reboots + 20 power cycles with the health check logging |
| Is rstmgr `BRGMODRST` readable from Linux userspace in HPS-first mode (C2 guard)? | **Yes** (Phase B: 0 in Linux; the guard runs in `fpga_access.py` on the board). It does not show the fabric's own ~100 ms bridge reset after a load (§5.9) |
| HEX and blinker additions: do they fit the periphery you want to freeze before Phase E? | **Done**: the HEX pins went in with C1, before any manifest-carrying `.jic` |
| With `Rst_sdm_wd_config` 2 (B1b) and the plain layout, does a watchdog timeout just reset or hang the board? | B6: let U-Boot's watchdog expire at its prompt once (`wdt stop` not run, wait 30 s), someone at the power switch |
