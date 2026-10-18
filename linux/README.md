# linux/ — Linux for the DE25-Standard (`de25_soc`)

Altera upstream boot stack plus this repo's board files, no Terasic forks
(plan: [../docs/plan_upstream_hps_first_webgui.md](../docs/plan_upstream_hps_first_webgui.md),
Phase A):

| piece | source |
|---|---|
| ATF BL31 | `altera-fpga/arm-trusted-firmware` `socfpga_v2.14.1`, patched: `config_ddr_size = hw_ddr_size` |
| U-Boot SPL + proper | `altera-fpga/u-boot-socfpga` `socfpga_v2026.04`, patched: single-port EMIF; board files from `uboot/` |
| kernel | `altera-fpga/linux-socfpga` `socfpga-6.18.20-lts`, DT from `dts/` |
| rootfs | Alpine 3.24 aarch64 minirootfs on SD partition 2 (ext4) |

Neither upstream tree has a DE25-Standard, so this directory carries them.

## Files

| file | what |
|---|---|
| `build_de25_linux.sh` | clones, patches and builds ATF, U-Boot, kernel (`./build.sh linux`) |
| `make_jic.sh` | QSPI image: phase 1 + SPL, U-Boot at 0xA00000, HPS-first core at 0xC00000 (`./build.sh jic`) |
| `uboot/socfpga_agilex5_de25_std{.dts,-u-boot.dtsi,_defconfig}` | U-Boot board support; the `-u-boot.dtsi` carries the SD PHY values of Terasic's working U-Boot |
| `dts/socfpga_agilex5_de25_std.dts` | Linux device tree (EMAC0, SD, UART1, I2C1 + RTC, QSPI with the 500 MHz reference clock, SoC sensors) |
| `tools/make_sdcard_image.sh`, `tools/alpine_rootfs_config.sh` | the SD card image, without root (`./build.sh sdcard`) |
| `tools/sd_recover.py`, `tools/tftp_server.py` | write the card from U-Boot over TFTP |
| `tools/push_to_board.py` | push a file to the running board (`nc`, driven over the console) |
| `board/eth-watchdog.sh` | bounces eth0 when it passes no traffic (from the DE25-Nano) |

Everything is written to `build/`: clones in `build/linux/src/`, binaries
in `build/linux/out/`, images (`.jic`, `sdcard.img.gz`) in `build/images/`.

## Build

```
./build.sh fpga        # FPGA-first .sof (HPS_FIRST=1 for an HPS-first one)
./build.sh linux       # CROSS_TOOLCHAIN=<dir> to use an existing aarch64 toolchain
./build.sh jic
./build.sh sdcard
```

Host packages: `git wget bc bison flex libssl-dev python3 dtc mtools
fakeroot e2fsprogs fdisk`, Quartus Pro 26.1.1, `pyserial` for the tools.

## Install (needs the board)

1. Program the `.jic`: `quartus_pgm -c "<cable>" -m jtag -o "pvi;build/images/de25_std.jic"`.
   The card may be blank: the SPL falls back to U-Boot in QSPI.
2. Power-cycle, then `python3 linux/tools/sd_recover.py --serial <console>`
   writes `build/images/sdcard.img.gz` to the card from U-Boot and boots it.
   It refuses unless the running U-Boot's device tree says DE25-Standard.
3. The board comes up at `192.168.1.223` (`BOARD_IP=` at image build),
   hostname `de25-std`, a fixed MAC from `/etc/de25/mac`, `/boot`
   unmounted.

Not yet tested on hardware - see the plan, A8, for the bring-up order and
checks. The old Terasic-U-Boot card and the 2026-09-08 binaries
(`~/de25_std_known_good_2026-09-08/`) are the fallback.

## History

The sections below are the 2026-09 bring-up log, with the in-tree build
and Terasic's U-Boot fork; the files they name are in git history.

## Session status (2026-09-09) — LWH2F root cause found and fixed

The whole detour below (2026-09-08) was in service of testing LWH2F access
from a full, privileged boot chain since a from-scratch bare-metal test
kept hanging on it. Picking back up from that session's last lead (the FPGA
reports itself config-ready, but nothing in the boot chain was calling the
bridge-enable sequence): U-Boot has a builtin `bridge enable [mask]`
command (`arch/arm/mach-socfpga/misc_soc64.c`'s `do_bridge_reset()`) that
does this properly, gated on `is_fpga_config_ready()`. Using it from a live
U-Boot prompt (`bridge enable 0x2` for LWH2F) cleared `RSTMGR_BRGMODRST`
cleanly with no error — but reading the actual LWH2F register right after
(`md.l 0x20000010 1`) still hung the board completely, identically to the
original bare-metal symptom.

That ruled out "missing software step" and pointed at this project's own
RTL. `de25_soc_top.vhd` drives `axi_bridge_reset` — the fabric-side reset
input to the HPS's own `lwhps2fpga` hard macro — with `not system_reset`.
That signal is **active-high** (same file drives the fan controller's
active-high `reset` port with plain `system_reset`, no inversion, a few
lines below) — so it was inverted: the hard macro was released from reset
instantly at FPGA configuration and then held in **permanent** reset for
the entire rest of normal operation, the exact opposite of the intended
"delay the release" behaviour. No amount of widening the power-on-reset
counter (`g_por_cycles`, tried 21ms → 100ms) could ever have fixed this,
since the signal being delayed was never actually reaching the macro's
reset input as a reset assertion in the first place.

Fix: `axi_bridge_reset <= system_reset;` (drop the `not`). Rebuilt,
reprogrammed, and confirmed immediately from the same U-Boot prompt:
```
=> bridge enable 0x2
=> md.l 0x20000010 1
20000010: 0000de25
=> mw.l 0x20000030 0xcafef00d 1
=> md.l 0x20000030 1
20000030: cafef00d
```
Register 1 (constant id), register 3 (loopback write/read-back), and
register 4 (read-strobe counter, incrementing across reads) all work
exactly as they do over the fabric UART. **The LWH2F bridge itself is
fixed and hardware-confirmed working.**

**Update, later the same day — also resolved.** The *original* bare-metal
test (`hps/baremetal_lwh2f_regs/`, since removed - see git history) kept hanging on its own self-test read
even with the RTL fix. Installing a real EL3 exception vector table (never
present before - `VBAR_EL3` stayed at its power-on-reset value of `0x0`)
showed it wasn't a hang at all: a clean synchronous external abort
(`ESR_EL3` EC=0x25, DFSC=0x10), the same fault class as Linux's `SIGBUS`.
Root cause: the ARM cores' own AXI master ports into the NoC (Arteris Ncore
CCU crossbar, `caiu0`/`ncaiu0` at `0x1C000000`/`0x1C001000` - unrelated to
any register in `hps_address_map.h`) need a routing/window table entry
programmed before a LWSOC2FPGA-targeted transaction has anywhere to go at
all. ATF's `init_ncore_ccu()` does this unconditionally, very early in
BL2, entirely separate from the bridge-enable sequence. Replicating those
same three register writes in the bare-metal test before the read fixed it
completely - confirmed on hardware (`self-test: register 1 (id) =
0x0000DE25 -> PASS`, plus a manual write/read round-trip). See
the removed `hps/baremetal_lwh2f_regs/README.md` (git history) for the full trail, including why a
real JTAG debugger halt wasn't viable in this environment (tried first).

## Session status (2026-09-08)

Long detour from the original LWH2F bare-metal-hang investigation, in
service of testing LWH2F access from a full, privileged boot chain instead
of from-scratch bare metal. Summary, newest-relevant first:

- **SD card access was completely broken** (ATF and U-Boot SPL alike —
  every SD command timed out) because this project's U-Boot build reused
  the **DE25-Nano's** device tree, which lacks the DE25-**Standard**'s
  board-specific Cadence combo-PHY calibration values. Fixed by building
  U-Boot from **Terasic's own fork**,
  [`terasic/u-boot-socfpga`](https://github.com/terasic/u-boot-socfpga)
  branch `de25-standard-v2025.01`, defconfig
  `socfpga_agilex5_de25s_defconfig` — SD access then worked immediately.
  **TODO**: point `de25_uboot.config-fragment` / `build_de25_linux.sh` at
  this fork instead of upstream `altera-fpga/u-boot-socfpga` +
  `socfpga_agilex5_de25_nano`.
- With that fork's SPL + a locally-rebuilt `bl31.bin` (had to patch a
  genuine ATF bug — `agilex5_ddr.c` hardcodes a 2GB DDR-size sanity check
  that hangs BL2 on this board's 1GB) + a fresh `u-boot.itb`, got a **full
  first-ever Linux boot** on this hardware: kernel 6.18.20, toybox
  userspace, live root shell over `/dev/ttyUSB2`.
- Also found along the way: the DE25-Standard's QSPI flash is **Micron
  MT25QU128** (16MB), not MT25QU512 (64MB) as this project had assumed
  everywhere — fixed in `make_jic.sh`.
- **Back to the original LWH2F question**, tested live from the booted
  Linux shell via `devmem`:
  - Reading the LWH2F bridge window (`0x20000010`) SIGBUS'd. Traced to
    `CONFIG_STRICT_DEVMEM` — disabled it in `de25_kernel.config-fragment`,
    rebuilt/redeployed the kernel, confirmed the new build was running.
    **Still SIGBUS'd.**
  - Comparison test: `rstmgr` (`0x10d11000`, a DT-claimed, known-good
    register) reads fine via `devmem`'s normal `mmap()` path. LWH2F
    (`0x20000010`) SIGBUS's on that *same* path with `STRICT_DEVMEM`
    confirmed off — a genuine synchronous external abort delivered to
    userspace, not a devmem software policy issue. (`devmem --no-mmap`,
    the `read()`-syscall path, faults on *everything* including `rstmgr` —
    that's just how `read()` on `/dev/mem` behaves here, not informative.)
  - Tried manually replicating the bare-metal bridge-enable register
    sequence (rstmgr handshake + `SYSMGR_FPGA_BRIDGE_CTRL` enable bit) by
    hand via `devmem` writes from the live Linux shell. The final write —
    setting the LWSOC2FPGA enable bit in `SYSMGR_FPGA_BRIDGE_CTRL`
    (`0x10d1205c`) — **crashed the board with a fatal SError** (kernel
    panic, not just SIGBUS). **Don't do this** — U-Boot's own bridge-enable
    path (`do_bridge_reset()` in `arch/arm/mach-socfpga/misc_soc64.c`)
    gates on `is_fpga_config_ready()` first and refuses to touch the
    bridges if it's false; the raw poke skipped that gate.
  - `is_fpga_config_ready()` reads `SYSMGR_SOC64_FPGA_CONFIG`
    (`0x10d12000 + 0xdc`), checking the `FPGA_COMPLETE | EARLY_USERMODE`
    bits — no SDM mailbox call needed, just a plain register read.
    Checked it live at the U-Boot prompt, right after a fresh JTAG
    `.sof` load: **`0x10d120dc` reads `0x3`** (both bits set — FPGA
    genuinely reports itself ready), while **`RSTMGR_BRGMODRST`
    (`0x10d1102c`) reads `0xf`** — every bridge still held in reset. So
    the FPGA *is* recognized as configured; the bridges are just never
    actually enabled anywhere in our current boot flow (nothing in SPL,
    ATF BL2/BL31, or U-Boot up to the prompt calls the enable sequence —
    `do_bridge_reset()` only fires from the Ethernet driver probe or an
    `fpga load` command, neither of which our flow triggers).
  - **Next step**: from that exact fresh-JTAG, FPGA-config-ready U-Boot
    prompt state, drive the *real* `do_bridge_reset(1, ~0)` sequence
    (either by calling it from a tiny added U-Boot command, or by hand via
    `md`/`mw` replicating `socfpga_bridges_reset()` in
    `reset_manager_s10.c` exactly, including the flush-handshake ordering)
    and see if LWH2F becomes accessible. If it does, the bare-metal hang
    was simply a missing bridge-enable call (fixable). If it still faults
    even with `FPGA_CONFIG` ready and the bridge nominally enabled, that
    points at something else entirely (NOC firewall permissions, fabric
    routing, or the bridge width/wiring itself).

Board left powered on at the `SOCFPGA_AGILEX5 #` U-Boot prompt (not booted
into Linux), freshly JTAG-programmed with `out_terasic_test.sof`
(Terasic's SPL + the patched `bl31.bin` embedded via `hps_path`).
