# linux/ — roll-your-own Linux for `de25_soc`

A **first-cut** Linux build for the minimal `de25_soc` FPGA design (Agilex 5,
all FPGA↔HPS bridges disabled). Structure follows Altera's
`agilex5e-ed-gsrd` "roll-your-own" script.

> ✅ **The build runs end to end** (Quartus 26.1.1, `QPDS26.1.1_REL_GSRD_PR`)
> and produces every artifact below.
> ⚠️ **Not booted on hardware.** U-Boot/SPL use the upstream
> `socfpga_agilex5_de25_nano` DT; only the Linux kernel gets this repo's
> `socfpga_agilex5_de25.dts`, whose board-specific values (KSZ9031 MDIO
> address, RGMII skew, USB PHY/hub, SD detect, I2C map) are still guesses —
> verify against the DE25-Standard schematic and iterate over the HPS UART
> console.

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

`make_jic.sh` runs `quartus_pfg` for the DE25-Standard's **Micron MT25QU512**
QSPI flash (`~/dev/de25_std/Datasheet/QSPI Flash/`) and device
`A5ED013BB32AE4SCS`. Then:

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
