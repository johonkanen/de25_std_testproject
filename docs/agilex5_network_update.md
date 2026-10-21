# Network updates on an Agilex 5 SoC board - how to add them to a new project

Instructions for giving a new Agilex 5 HPS + FPGA project the three
updates this repository has: a new web GUI, a new FPGA core, or a whole
new FPGA image, all over Ethernet, each with an automatic way back. Follow
the steps in order; each ends with a check that proves it on the board.

The worked example is this repository (Terasic DE25-Standard,
`A5ED013BB32AE4SCS`, 16 MB MT25QU128 QSPI, Linux on the SD card). Every
step names the file that does it here. The DE25-Nano repository
(`~/dev/de25_nano_testproject`) did it first, and its
`docs/remote_system_update_plan.md` has the background. The history and
the measurements are in [plan_upstream_hps_first_webgui.md](plan_upstream_hps_first_webgui.md)
(Phases B, D, E, F and §5).

## What you end up with

| what changed | update | host tool | reboot | if it goes wrong |
|---|---|---|---|---|
| the web GUI's Python/HTML | GUI release | `linux/tools/deploy_web.py` | no, the GUI restarts | the supervisor reverts to the previous release |
| fabric logic only (same pins, HPS, DDR, Quartus) | FPGA core | `linux/tools/deploy_fpga.py` | no, a ~2 s pause | the previous core is loaded back |
| HPS IP, pins, DDR, Quartus version, SPL, U-Boot | whole image (RSU) | `linux/tools/deploy_rsu.py` | yes, into the new image | the watchdog falls back to the factory image |

Not over the network: the kernel, device tree and root filesystem (they
come from the SD card), and the factory image (JTAG only, on purpose: it is
the image that always works).

How the whole-image update works, in short:
- The QSPI holds a **factory image** and an **application image** (P1).
  Each is a complete phase 1 (SDM firmware, HPS I/O, DDR I/O, SPL).
- The SDM's decision firmware boots the highest-priority application image
  that has not failed, else the factory image. The SPT tables hold the slot
  map and the CPB tables the priorities; there are two copies of each.
- An image fails when its configuration fails, or when the HPS watchdog
  expires before Linux says it is healthy. A bad image costs one automatic
  fallback, not a dead board.
- Each image carries its own U-Boot and its own FPGA core. The SPL loads
  the U-Boot of the image it came from, and that U-Boot loads the image's
  core.
- Linux writes P1 only, never the factory image or the boot info.

## 0. Decisions before you start

- **HPS-first** (`HPS_INITIALIZATION "HPS FIRST"`). It is required for both
  core updates and RSU: the FPGA core is then a separate file that U-Boot
  and Linux load, and phase 1 is small (~0.8 MB). An FPGA-first bitstream
  (~3 MB here) does not fit a 1 MB slot.
- **QSPI of 16 MB or more.** The layout below uses about 14 MB.
- **A register file over the lightweight HPS-to-FPGA bridge (LWH2F)**,
  with three read-only registers the software checks after every load:
  - a board id (register 1 here);
  - a board variant (register 18, `"STD\0"`);
  - a build id (register 19: the Unix time of the build, stamped into
    `build_id_pkg.vhd` by the build).
- **A board name string** (`de25-std` here). Every bundle and release
  carries it, and the board refuses one for another board. Two boards
  on one LAN will happen.

## 1. The FPGA design

In the project settings (here `fpga/build_de25_soc.tcl`):

```tcl
set_global_assignment -name QSPI_OWNERSHIP HPS
set_global_assignment -name HPS_INITIALIZATION "HPS FIRST"
```

- `QSPI_OWNERSHIP HPS`: the SPL, U-Boot and Linux must reach the QSPI.
  With SDM ownership, the SPL's first QSPI access stalls the bus.
- In the HPS IP (here `fpga/hps/hps_subsystem.tcl`), set
  `Rst_sdm_wd_config` to `2`, "trigger remote update". A watchdog expiry
  then makes the SDM fall back to the next image instead of just resetting
  the HPS. Without it, item 3 of the tests below cannot pass.
  - After editing the HPS `.ip`, regenerate it explicitly. Platform
    Designer can show a stale interface list (plan §5.1).
- **The fabric's own power-on reset holds the LWH2F slave side for a short
  time after configuration** (about 100 ms here, `g_por_cycles` in
  `fpga/register_block.vhd`). This hold is not visible in the HPS reset
  manager. A read inside that window hung the whole board, so the software
  waits after every load (section 6).
- Peripheral drivers in the fabric should set their chips up again after
  a reload. A core load glitches their buses (the MAX6650 fan
  controller here, plan §5.17b: bus recovery and a periodic config check).

**Check:** the `.sof` builds. `quartus_pfg -c x.sof x.core.rbf -o hps_core_only=ON`
writes a core, which proves the design is HPS-first.

## 2. The QSPI image (`linux/make_jic.sh`)

### 2a. The core and its manifest

`quartus_pfg -c de25_std.sof de25_std.core.rbf -o hps_core_only=ON`, and a
`de25_std.core.json` next to it:

| field | meaning |
|---|---|
| `board` | the board name |
| `build_id` | the same number as the build id register |
| `core_size`, `core_sha256` | checked before anything is loaded |
| `periphery_sha256` | the compatibility key (below) |
| `git`, `built` | for people |

**The compatibility key is a periphery hash, not a hash of phase 1.** A
core loads only on top of the phase 1 it was built with: the same pins, HPS
and DDR configuration, and Quartus version. Two builds of the same
periphery still differ in the phase-1 bitstream by about 182 bytes of
per-build hashes. Hash these instead:
- the fitter's `.pin` table, without its comment lines (it names the
  Quartus version and the device);
- the HPS and EMIF `.ip` files.

The board refuses a core whose `periphery_sha256` differs from the one
installed (plan §5.11).

### 2b. The RSU layout

Write the `.pfg` with **fixed addresses throughout**. With `"auto"`, quartus_pfg
26.1.1 fails with an internal error. The layout here, for 16 MB:

| partition | from | to | contents |
|---|---|---|---|
| BOOT_INFO (reserved) | 0x000000 | 0x20FFFF | boot info + decision firmware (it needs 0x210000) |
| FACTORY_IMAGE | 0x220000 | 0x31FFFF | phase 1 + SPL |
| SPT0, SPT1, CPB0, CPB1 (reserved) | 0x320000 | 0x33FFFF | 32 KB each |
| P1 | 0x400000 | 0x4FFFFF | phase 1 + SPL, the same build at first |
| SSBL.FACTORY_IM | 0x500000 | 0x5FFFFF | the factory image's `u-boot.itb` |
| SSBL.P1 | 0x600000 | 0x6FFFFF | P1's `u-boot.itb` |
| UBOOT | 0xA00000 | 0xAFFFFF | `u-boot.itb` for an SPL without RSU multiboot (`CONFIG_SYS_SPI_U_BOOT_OFFS`) |
| CORE.FACTORY_IM | 0xC00000 | 0xD0FFFF | 4 KB header `core_size=0x...` + the factory image's core |
| CORE.P1 | 0xD10000 | 0xE1FFFF | the same for P1 |

- Names are at most 16 characters. That is why it is `SSBL.FACTORY_IM`,
  not `SSBL.FACTORY_IMAGE`.
- The `.pfg` has two bitstreams (Factory and App1) built from the same
  `.sof`, with `hps_path` set to the SPL hex file. Phase 1 of P1 goes in
  `page="1"`. The `u-boot.itb` and the header + core are raw files
  (`bitswap="1"`), each assigned to both of its partitions.
- Check the sizes in the script: `u-boot.itb` ≤ 1 MB, header + core ≤
  0x110000.
- The flash loader is the **full** device string
  (`A5ED013BB32AE4SCS`). An abbreviated one resolved to a different JTAG
  IDCODE on the Nano.

### 2c. The application image for updates

A second quartus_pfg call writes the image an update puts into P1:

```bash
quartus_pfg -c de25_std.sof de25_std_app.rpd -o hps_path=u-boot-spl-dtb.hex \
    -o mode=ASX4 -o start_address=0x00 -o bitswap=ON
```

It starts at address 0, and librsu relocates it into the slot. It differs
from the P1 copy inside the `.jic` by two pointers and a block CRC, so do
not cut it out of the `.jic`.

**Check:** the `.jic` builds, and its `.map` shows the partitions at the
addresses above.

## 3. U-Boot and the SPL (`linux/build_de25_linux.sh`)

- `CONFIG_SOCFPGA_RSU_MULTIBOOT=y`: the SPL loads the U-Boot of the image
  the SDM booted. It looks on the card first (`u-boot_<slot>.itb`, i.e.
  `u-boot_P1.itb` or `u-boot_FACTORY_IMAGE.itb`), then in QSPI
  `SSBL.<slot>`. Without an RSU layout it falls back to
  `CONFIG_SYS_SPI_U_BOOT_OFFS`.
- Apply `linux/patches/u-boot-rsu-running-slot.patch`. It adds
  `rsu running_slot [var]`, which sets `rsu_slot` to the running image's
  name and `rsu_slot_core` to the offset of its `CORE.<name>` partition.
- `CONFIG_PREBOOT` loads the running image's core, only when the fabric is
  not configured already (`FPGA_CONFIG`, `0x10d120dc`, is not 3; after a
  warm reboot the old core stays). It tries the card file
  `<board>_<slot>.core.rbf` first, then QSPI `CORE.<slot>` through its
  4 KB header, and it falls back to QSPI when the card's file fails to
  load too. The exact script is in `build_de25_linux.sh`. The script
  checks the resulting `.config` for each of these settings and stops if
  one is missing.
- `CONFIG_BOOTCOMMAND="bridge enable; run distro_bootcmd"`. Without
  `bridge enable`, Linux's first LWH2F access is a SIGBUS.
- The SPL starts HPS watchdog 0 with a 30 s timeout (`WDT: Started
  watchdog ... (30s timeout)`). Leave it running: it is the safety net
  until Linux confirms the image.

**Check (after section 8):** the console shows
`rsu_spl_mmc_filename, filename: u-boot_P1.itb` and
`core <board>_P1.core.rbf from SD`.

## 4. Kernel and device tree

Build these in (the root filesystem carries no modules):
- `INTEL_STRATIX10_RSU`;
- `FPGA_MGR_STRATIX10_SOC`, `FPGA_BRIDGE`, `FPGA_REGION`,
  `OF_FPGA_REGION`, `OF_OVERLAY`, `OF_CONFIGFS` (core reload);
- the QSPI drivers (`SPI_CADENCE_QUADSPI`, `MTD_SPI_NOR`).

Device tree (here `linux/dts/socfpga_agilex5_de25_std.dts`):

```dts
partitions {
    compatible = "fixed-partitions";
    #address-cells = <1>;
    #size-cells = <1>;
    rsu-handle = <&qspi_boot>;
    qspi_boot: partition@0 { label = "u-boot"; reg = <0x0 0x00320000>; read-only; };
    qspi_rsu: partition@320000 { label = "root"; reg = <0x00320000 0x00ce0000>; };
};
```

- The second partition (`/dev/mtd1`) **must start at SPT0**: librsu reads
  the SPT from the start of its root partition ("Bad SPT0 magic number"
  otherwise). The first one, boot info and the factory image, is read-only.
- Set `&qspi_clk { clock-frequency = <...>; }` to what the SPL prints
  (`QSPI: Reference clock at 400000 kHz` here, 500 MHz on the Nano). A
  wrong value shifts the JEDEC id by a bit and corrupts bulk reads. Verify
  by reading known flash content three times and comparing it on the host.
- `&watchdog0 { status = "okay"; };`
- Kernel command line: `watchdog.open_timeout=120`. The kernel keeps the
  SPL's watchdog fed only until a program opens it, or until this timeout
  runs out.

**Check:** `/sys/devices/platform/stratix10-rsu.0/` exists. Its files only
appear with an RSU layout in the flash. Also `cat /proc/mtd` shows
`u-boot` and `root`.

## 5. Root filesystem

`linux/tools/alpine_rootfs_config.sh` and `linux/tools/make_sdcard_image.sh`:

- **`rsu_client`, static** (`altera-fpga/intel-rsu`, a pinned commit, with
  static zlib). One static binary runs on musl. `/etc/librsu.rc`:
  ```
  log med stderr
  root qspi /dev/mtd1
  rsu-dev /sys/devices/platform/stratix10-rsu.0
  ```
- **`/usr/sbin/rsu-confirm`** (`linux/board/rsu-confirm.sh`), started
  **first** in `/etc/rc.local`, in the background:
  - It opens `/dev/watchdog0` and feeds it every 5 s while it waits for
    "healthy". Here, healthy means `GET /api/board` on localhost answers
    `"id_ok": true`. That one answer proves the kernel, rootfs, GUI,
    register service, LWH2F and FPGA core all work.
  - When healthy, it writes `confirmed <image> <s>` to `/run/rsu-confirm`
    and resets the RSU retry counter. It keeps feeding the watchdog, so
    a later hang still trips it.
  - When not healthy within `DEADLINE` (300 s: a first boot installs
    python3), it stops feeding, and the SDM falls back.
  - On the factory image it only reports and always feeds the watchdog,
    because there is nothing below the factory image.
  - On TERM (shutdown) it disarms the watchdog with the magic close `V`.
    A KILL leaves it armed, and that is what the fallback test uses.
- **The card's FAT partition stays unmounted** (`noauto` in fstab). It is
  mounted only to write a file: write `.new`, fsync, rename, unmount.
  The card holds `u-boot_P1.itb`, `u-boot_FACTORY_IMAGE.itb`,
  `<board>_P1.core.rbf`, `<board>_FACTORY_IMAGE.core.rbf` (plus the plain
  names for an SPL without RSU).
- **The core in Linux:** `/lib/firmware/rsu/<slot>/<board>.core.rbf` and
  `.json`, one directory per image. `/lib/firmware/<board>.core.rbf` is a
  link to the running image's. `fpga-reload` and a configfs device-tree
  overlay (`linux/tools/fpga_reload/`) make the kernel's FPGA manager load
  that file.
- **Network that survives a reboot:**
  - Keep the MAC fixed (U-Boot's random MAC changes every boot; here it is
    kept in `~/.de25_std_mac` and set by the rootfs).
  - Send a gratuitous `arping -U` at boot.
  - Do the network work in the background after the gateway answers
    (`ntpd`, `apk add`).
  - Run `eth-watchdog`, which bounces an eth0 that passes no traffic.
  - A stalled link at first boot once kept python3 from being installed,
    so the GUI never came up and the confirmation could not succeed.
- **The update token:** a file on the host (`~/.de25web_token_std`) and
  `/opt/de25web/token` on the board. Every write needs it as `X-Token`.

## 6. The update service on the board (`linux/webapp/`)

Three processes, started by `linux/board/de25web-supervisor.sh`:
- **`fpga_access.py`** is the only process that maps the LWH2F
  (`/dev/mem`). It serves register reads and writes over a Unix socket and
  does every load, so it can stop all register traffic around one.
- **`temp_control.py`** is the application (the fan loop here).
- **`fpga_web.py`** is HTTP; it talks to the other two.

Rules that cost a hung board when broken:
- **No LWH2F access during a core load, and none for 0.5 s after it**
  (`POST_LOAD_SETTLE_S`). The pause has no time limit: a 120 s limit
  once expired during a hung load, and the next read hung the CPU.
- Do not write the bridge registers from Linux by hand (an SError here).
  Read the reset manager's `BRGMODRST` to see whether the fabric is up,
  and refuse register access while it is not.
- **Check before touching anything.** Size, SHA-256 against the manifest,
  board name, kind, and the periphery hash (for a core) or the slot sizes
  (for RSU). A corrupt core with a matching manifest hung the SDM, and only
  a power cycle helped.

The endpoints (all writes need `X-Token` and `X-Sha256` of the body):

| endpoint | does |
|---|---|
| `POST /api/update` | GUI release: unpacked to `releases/<name>`, started on test; `POST /api/update/confirm` keeps it. Without a confirmation within the test time, or after 3 exits, the supervisor reverts. `previous` stays the last *confirmed* release. |
| `POST /api/fpga` | core bundle (`<board>.core.rbf` + `.json`): `.pending` marker, old core kept as `.prev`, load, check board id, variant and build id, put the writable registers back. On failure it loads `.prev` back. The card copy is written only after a good load. A leftover `.pending` at start-up means restore `.prev`. |
| `POST /api/rsu` | RSU bundle (below). Order: **erase P1 first** (from then on a power cut boots the factory image), then SSBL.P1, CORE.P1, the card files, `/lib/firmware/rsu/P1`, and **write + verify P1 last**. Then `echo <P1 offset> > .../stratix10-rsu.0/reboot_image` and reboot. `X-No-Reboot: 1` only writes. |
| `GET /api/version`, `/api/fpga`, `/api/rsu` | the board name and GUI release; the running core build; the running and failed image, the confirmation, what P1 holds |

Refuse what the headers already show (no or wrong token, too big)
**before reading the body**, and close the connection. The host side must
then send its headers, wait a moment for an early answer, and send the body
only if none came (`request()` in `linux/tools/deploy_web.py`). Otherwise
it gets a broken pipe instead of the 403.

## 7. The host tools (`linux/tools/`)

| tool | does |
|---|---|
| `make_rsu_bundle.py` | `rsu.json` (format, kind `<board>_rsu`, board, build_id, periphery_sha256, git, built, each file's size and SHA-256) + `app.rpd` + `u-boot.itb` + the core and its `.json`. Reproducible: fixed member order and mtime. `--check BUNDLE` verifies one. |
| `deploy_rsu.py` | checks `/api/version`'s board name, uploads, follows the reboot until `/api/rsu` says P1 is confirmed with the bundle's build id, or reports the fallback. `--status`, `--no-reboot`. |
| `deploy_fpga.py` | packs the core bundle, uploads it, and checks the build id that answers. |
| `deploy_web.py` | packs `linux/webapp/` as a release (with a `BOARD` file), uploads it, waits for the restart, checks it, confirms it. |
| `rsu_refusal_test.py`, `supervisor_test.py`, `gui_test.py` | the tests below |

A core only fits its phase 1, so a whole-image bundle is all or nothing:
the image, its U-Boot and its core always come from one build.

## 8. First install on a board

1. Build: FPGA, then U-Boot/kernel/`rsu_client`, then the `.jic` (which
   also writes the core, its manifest and `<board>_app.rpd`), then the
   card image with the token.
2. **Card first:** `sd_recover.py` (over TFTP from U-Boot), or a card reader.
3. **Then QSPI:** `quartus_pgm -c "<cable>" -m jtag -o "pvi;build/images/<board>.jic"`.
   Check it says the operation succeeded. A failed erase leaves the
   flash unbootable; program it again.
4. Power-cycle. A `reboot` after a JTAG `.sof` load never comes back,
   because the SPL came over JTAG; test reboots only after a power-on boot.
5. `python3 linux/tools/deploy_rsu.py --status` should say
   `image P1, build ..., confirm 'confirmed 0x00400000 ..'`.

## 9. Tests that prove it

Run these once per new project, in this order. The last three need someone
at the power switch. Results here: plan "Phase D/E/F progress".

| # | test | expected (DE25-Standard result) |
|---|---|---|
| 1 | cold boot | SPL takes `u-boot_P1.itb`, `core <board>_P1.core.rbf from SD`, `rsu-confirm ... confirmed` (12-13 s) |
| 2 | `supervisor_test.py` (host) | 8 GUI-release cases pass: good, two updates, unconfirmed, crash, restart, broken rollback, wrong board |
| 3 | `deploy_web.py`, `deploy_fpga.py` | new release confirmed; core loaded in ~2 s, build id matches; 100 reloads in a row |
| 4 | bad core bundles | refused, 400/403/409, nothing loaded |
| 5 | `deploy_rsu.py` end to end | P1 written (14-16 s), reboot, confirmed (53-61 s in all) |
| 6 | `rsu_refusal_test.py` | 13 bad RSU bundles refused before any erase, board unchanged |
| 7 | watchdog fallback: `kill -KILL` rsu-confirm on P1 | "watchdog did not stop!", expiry, factory image boots and reports healthy; `/api/rsu` shows P1 failed |
| 8 | power cut after the P1 erase (`rsu_client --erase <P1 slot>`, then power off) | factory image boots, "P1 is empty"; `deploy_rsu.py` from there restores P1; a cold boot picks P1 again |
| 9 | wrong-board bundles and releases | refused (400 for a GUI release, 409 for a core or RSU bundle) |

**Never** load a damaged core or image with a manifest made to match it,
unless someone is at the power switch (plan §5.8).

## 10. Recovery

| situation | do |
|---|---|
| fell back to the factory image | it runs and answers; deploy a fixed bundle. `rsu_client --clear-error-status` clears the record (a power cycle does too) |
| back to P1 by hand | `rsu_client --clear-error-status; echo 0x400000 > /sys/devices/platform/stratix10-rsu.0/reboot_image; reboot` |
| the factory image by hand | `echo 0x220000 > /sys/devices/platform/stratix10-rsu.0/reboot_image; reboot` |
| an RSU update cut short | P1 is erased or incomplete, so the factory image boots; run `deploy_rsu.py` again |
| a core update failed | the previous core is back, or it is put back at the next start of `fpga_access.py` |
| the board hangs, JTAG times out | power-cycle |
| nothing boots | program the `.jic` over JTAG and write the card with `sd_recover.py` |

On the board: `rsu_client --log`, `cat /run/rsu-confirm`,
`dmesg | grep 'rsu-confirm\|FPGA core\|eth-watchdog'`.

## 11. Porting checklist

Names and numbers that are board-specific in this repository:
- the board name (`de25-std`), the file prefix (`de25_std`), and the RSU
  bundle kind (`de25_std_rsu`);
- the board id, variant and build id registers and their values;
- the QSPI device and size, the flash loader string, and the QSPI
  reference clock;
- the partition addresses (sections 2b and 4, `P1_SIZE` in
  `rsu_refusal_test.py`, `FACTORY`/`P1` in `deploy_rsu.py`);
- `QSPI_UBOOT_OFFS` and `QSPI_CORE_OFFS`, which must match the U-Boot
  build;
- the board IP address, the token file, the console port, and the JTAG
  cable name;
- the files the core load must check and the registers it must write back
  (`fpga_access.py`);
- what "healthy" means (`healthy()` in `rsu-confirm.sh`).
