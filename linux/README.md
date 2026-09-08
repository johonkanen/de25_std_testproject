# linux/ — roll-your-own Linux for `de25_soc`

A **first-cut** Linux build for the minimal `de25_soc` FPGA design (Agilex 5,
all FPGA↔HPS bridges disabled). Structure follows Altera's
`agilex5e-ed-gsrd` "roll-your-own" script.

> ✅ **The build runs end to end** (Quartus 26.1.1, `QPDS26.1.1_REL_GSRD_PR`)
> and produces every artifact below.
> ✅ **Booted to a live root shell on hardware**, via SD card, kernel
> 6.18.20 — see [Session status (2026-09-08)](#session-status-2026-09-08)
> below. This required **Terasic's own u-boot-socfpga fork**
> (`de25-standard-v2025.01`), not the upstream `socfpga_agilex5_de25_nano`
> DT this fragment/script still point at — **`de25_uboot.config-fragment`
> and `build_de25_linux.sh` have not been updated to that fork yet**; the
> SD boot that actually worked used a separately-built U-Boot (see below).
> The Linux kernel's own `socfpga_agilex5_de25.dts` booted fine as-is
> (EMAC0/KSZ9031 came up, SD/MMC read the rootfs) — its board-specific
> guesses (RGMII skew, USB PHY/hub, I2C map) are unverified beyond that.

## Files

| file | what |
|------|------|
| `build_de25_linux.sh` | orchestrator — toolchain shim, ATF, U-Boot, kernel, toybox initramfs, `sdcard.img` |
| `dts/socfpga_agilex5_de25.dts` | **Linux** device tree (EMAC0/KSZ9031, SD/MMC, UART1 console, USB0, I2C1, SPIM0; **no bridge nodes**) |
| `de25_uboot.config-fragment` | onto `socfpga_agilex5_defconfig` — DT = upstream `socfpga_agilex5_de25_nano`, SD boot, no NAND, bootcmd |
| `de25_kernel.config-fragment` | onto arm64 `defconfig` — `CONFIG_MICREL_PHY` etc. |

## Prerequisites

Linux host, internet, ~25 GB free, and:
```
git wget xz-utils bc bison flex libssl-dev python3 mtools dosfstools
```
Quartus 26.1.1 in `PATH` (for the `quartus_pfg` JIC step).

The script auto-downloads the **ARM GNU `aarch64-none-linux-gnu`** toolchain
(the landley musl one the Altera reference uses lacks the LTO plugin ATF
needs). Overrides:

| env | for |
|-----|-----|
| `CROSS_TOOLCHAIN=<dir>` | use an existing toolchain (dir with `bin/aarch64-none-linux-gnu-gcc`) instead of downloading |
| `MTOOLS_BIN=<dir>` | where `mformat`/`mcopy` live if `mtools` isn't installed system-wide |
| `SOF=<path>` | FPGA `.sof` (default `output_files/de25_soc.sof`) |
| `QPDS_REF=<tag>` | git tag on the altera-fpga repos (match your Quartus version) |

## Build

```
# 1. FPGA (from the repo root)
python3 hps/disable_bridges.py
qsys-generate hps/ip/hps_subsys/agilex_hps.ip     --synthesis=VHDL --part=A5ED013BB32AE4SCS
qsys-generate hps/ip/qsys_top/emif_io96b_hps.ip   --synthesis=VHDL --part=A5ED013BB32AE4SCS
python3 hps/gen_hps_min.py
quartus_sh -t build_de25_soc.tcl
quartus_syn de25_soc && quartus_fit de25_soc && quartus_asm de25_soc

# 2. Linux
./linux/build_de25_linux.sh
```

Outputs in `linux/build_output/` (sizes from a real run):

| file | ~size | from |
|------|------:|------|
| `bl31.bin` | 60 KB | ARM Trusted Firmware, `PLAT=agilex5` |
| `u-boot.itb` | 830 KB | U-Boot proper (FIT, contains BL31) |
| `spl/u-boot-spl-dtb.hex` | 530 KB | first-stage loader → goes in the JIC |
| `Image` | 48 MB | Linux kernel (arm64 `defconfig` + fragment) |
| `socfpga_agilex5_de25.dtb` | 23 KB | this repo's Linux DT |
| `initramfs.cpio` | 7 MB | toybox `mkroot` rootfs |
| `sdcard.img` | 96 MB | FAT32: `Image` + `.dtb` + `u-boot.itb` + `initramfs.cpio` |

## Boot media

Agilex 5 boots HPS-first: the **SPL + FPGA bitstream go in a JIC** (QSPI),
the **kernel + rootfs go on the SD card**.

```
./linux/make_jic.sh          # -> linux/build_output/de25_soc.jic (verified: 0 errors)
```

`make_jic.sh` runs `quartus_pfg` for the DE25-Standard's **Micron MT25QU128**
(128Mb/16MB — confirmed by `quartus_pgm`'s own JTAG autodetect; an earlier
MT25QU512/512Mb assumption was wrong and never flash-verified) QSPI flash
and device `A5ED013BB32AE4SCS`. Then:

1. `dd` `sdcard.img` to the SD card
2. attach the board (on WSL2, `usbipd attach` the on-board USB-Blaster II —
   see [`../program.sh`](../program.sh)), then
   `quartus_pgm -c 1 -m jtag -o "pvi;linux/build_output/de25_soc.jic"`
3. set MSEL for QSPI + HPS-first per the DE25-Standard manual §"Set the MSEL"
4. power-cycle; console on the HPS UART (CP2105) @ 115200

Boot flow: SDM → SPL (DDR) → ATF BL31 → U-Boot → `booti` Image + dtb +
initramfs → shell in RAM.

## From here

- **Real rootfs**: build Buildroot or drop a Debian arm64 tarball onto an
  ext4 partition 3, then in `de25_uboot.config-fragment` change
  `root=/dev/ram0` → `root=/dev/mmcblk0p3 rootwait` and remove the
  `initramfs.cpio` fatload from `CONFIG_BOOTCOMMAND`.
- **Pure-SD boot** (no QSPI): write the SPL/bitstream combo to an SD
  partition of type `0xA2` instead of the JIC — see the Altera GSRD
  `flash_image.pfg` for the layout.
- **DT hardening**: fill in the KSZ9031 MDIO address, `rgmii` vs
  `rgmii-id` skew, SD card-detect GPIO, USB3300 PHY + USB251xb hub reset,
  and the I2C device tree from the DE25-Standard schematic.
- **HPS↔FPGA comms**: if you ever need it, re-enable `LWH2F_Width` in
  `hps/disable_bridges.py`, add the bridge back to the Qsys wiring and a
  `soc2fpga`/`lwsoc2fpga` node to the DT.

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
