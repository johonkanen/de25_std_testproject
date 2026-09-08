# linux/ — roll-your-own Linux for `de25_soc`

A **first-cut** Linux build for the minimal `de25_soc` FPGA design (Agilex 5,
all FPGA↔HPS bridges disabled). Structure follows Altera's
`agilex5e-ed-gsrd` "roll-your-own" script; the device tree follows Terasic's
`socfpga_agilex5_de25_nano.dts`, minus anything that touches the fabric.

> ⚠️ **Not run on hardware.** Everything builds, the DT compiles against the
> Agilex 5 kernel tree, but the board-specific values (Ethernet PHY MDIO
> address, RGMII skew, USB PHY/hub, SD detect, I2C map) are copied from the
> DE25-Nano and must be checked against the DE25-Standard schematic. Iterate
> on the DT over the HPS UART console.

## Files

| file | what |
|------|------|
| `build_de25_linux.sh` | orchestrator — toolchain, ATF, U-Boot, kernel, initramfs, `sdcard.img` |
| `dts/socfpga_agilex5_de25.dts` | Linux device tree (EMAC0/KSZ9031, SD/MMC, UART1 console, USB0, I2C1, SPIM0; **no bridge nodes**) |
| `dts/socfpga_agilex5_de25-u-boot.dtsi` | U-Boot/SPL additions (boot order, SD-PHY tuning, memory size) |
| `de25_uboot.config-fragment` | merged onto `socfpga_agilex5_defconfig` — SD boot, no NAND, bootcmd |
| `de25_kernel.config-fragment` | merged onto arm64 `defconfig` — `CONFIG_MICREL_PHY` etc. |

## Prerequisites

Linux host, internet, ~25 GB free, and:
```
git wget xz-utils bc bison flex libssl-dev python3 mtools dosfstools
```
Quartus 26.1.1 in `PATH` (for the `quartus_pfg` JIC step). The script
downloads its own aarch64 musl toolchain.

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
./linux/build_de25_linux.sh          # SOF=... QPDS_BRANCH=... to override
```

Outputs land in `linux/build_output/`: `bl31.bin`, `u-boot.itb`,
`spl/u-boot-spl-dtb.hex`, `Image`, `socfpga_agilex5_de25.dtb`,
`initramfs.cpio`, `sdcard.img`.

## Boot media

Agilex 5 boots HPS-first: the **SPL + FPGA bitstream go in a JIC** (QSPI),
the **kernel + rootfs go on the SD card**.

```
quartus_pfg -c output_files/de25_soc.sof linux/build_output/de25_soc.jic \
    -o device=MT25QU128 -o flash_loader=A5ED013BB32AE4SCS \
    -o hps_path=linux/build_output/u-boot-socfpga/spl/u-boot-spl-dtb.hex \
    -o mode=ASX4 -o hps=1
```
Confirm `-o device=` against the DE25-Standard's QSPI flash part
(`~/dev/de25_std/Datasheet/QSPI Flash/`). Then:

1. `dd` `sdcard.img` to the SD card
2. `quartus_pgm -c 1 -m jtag -o "pvi;linux/build_output/de25_soc.jic"`
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
