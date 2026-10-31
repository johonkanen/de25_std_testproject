# Network updates on an Agilex 5 SoC board - how to add them to a new project

Instructions for giving a new Agilex 5 HPS + FPGA project network updates
of everything on the board: the web GUI, the FPGA core, and the whole
image - QSPI image, U-Boot, kernel, device tree and root filesystem - as
signed [RAUC](https://rauc.io) bundles over Ethernet, each with an automatic
way back. Follow the steps in order; each ends with a check that proves it
on the board.

The worked example is this repository (Terasic DE25-Standard,
`A5ED013BB32AE4SCS`, 16 MB MT25QU128 QSPI, Linux on the SD card). Every
step names the file that does it here. The DE25-Nano repository
(`~/dev/de25_nano_testproject`) did the RSU part first, and its
`docs/remote_system_update_plan.md` has the background. The history and
the measurements are in [plan_upstream_hps_first_webgui.md](plan_upstream_hps_first_webgui.md)
(Phases B, D, E, F and §5) and [plan_rauc.md](plan_rauc.md) (RAUC, A/B).
The RAUC part step by step, with every file and the traps we hit:
[agilex5_rauc_setup.md](agilex5_rauc_setup.md).

## What you end up with

Every update is a RAUC bundle (`linux/tools/make_bundle.py`), signed with a
key only the build PC has, uploaded with `linux/tools/deploy_bundle.py` (or
the GUI's Update card) to `POST /api/bundle`:

| what changed | bundle | reboot | if it goes wrong |
|---|---|---|---|
| the web GUI's Python/HTML | `make_bundle.py gui` | no, the GUI restarts | the supervisor reverts to the previous release |
| fabric logic only (same pins, HPS, DDR, Quartus) | `make_bundle.py core` | no, a ~2 s pause | the previous core is loaded back |
| anything else: HPS IP, pins, DDR, Quartus version, SPL, U-Boot, kernel, DT, rootfs | `make_bundle.py image` | yes, into the other application image | the watchdog falls back to the image that ran before |

The board refuses a bundle whose signature does not chain to its CA, whose
content does not match its dm-verity hash tree, or that names another board.

Not over the network: the factory image and its rootfs (JTAG and the SD
card only, on purpose: it is what always works).

How the whole-image update works, in short:
- The QSPI holds a **factory image** and two **application images**, P1 and
  P2. Each is a complete phase 1 (SDM firmware, HPS I/O, DDR I/O, SPL), with
  its own U-Boot and FPGA core beside it.
- **Each image boots its own rootfs** on the card (factory `p2`, P1 `p3`,
  P2 `p5`); what differs per board or changes at run time lives on a shared
  data partition (`p6`).
- The SDM's decision firmware boots the highest-priority application image
  that has not failed, else the factory image. An image fails when its
  configuration fails, or when the HPS watchdog expires before Linux says
  it is healthy. A bad image costs one automatic fallback to the other one.
- RAUC installs an image bundle into the group (rootfs + QSPI image) that
  is **not** running: it disables that image first, writes its rootfs, then
  its QSPI image, makes it the top priority and the board reboots into it.
  Its boot backend maps RAUC's primary/good/bad onto the SDM's priorities.
- Linux never writes the factory image, its rootfs or the boot info.

## 0. Decisions before you start

- **HPS-first** (`HPS_INITIALIZATION "HPS FIRST"`). It is required for both
  core updates and RSU: the FPGA core is then a separate file that U-Boot
  and Linux load, and phase 1 is small (~0.8 MB). An FPGA-first bitstream
  (~3 MB here) does not fit a 1 MB slot.
- **QSPI of 16 MB or more.** The layout below (A/B: factory, P1, P2) ends at 0xF2FFFF, about 15 MB.
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
| P2 | 0x700000 | 0x7FFFFF | empty; the first image update writes it |
| SSBL.P2 | 0x800000 | 0x8FFFFF | P2's `u-boot.itb` (empty at first) |
| UBOOT | 0xA00000 | 0xAFFFFF | `u-boot.itb` for an SPL without RSU multiboot (`CONFIG_SYS_SPI_U_BOOT_OFFS`) |
| CORE.FACTORY_IM | 0xC00000 | 0xD0FFFF | 4 KB header `core_size=0x...` + the factory image's core |
| CORE.P1 | 0xD10000 | 0xE1FFFF | the same for P1 |
| CORE.P2 | 0xE20000 | 0xF2FFFF | the same for P2 (empty at first) |

- Names are at most 16 characters. That is why it is `SSBL.FACTORY_IM`,
  not `SSBL.FACTORY_IMAGE`.
- The `.pfg` has two bitstreams (Factory and App1) built from the same
  `.sof`, with `hps_path` set to the SPL hex file. Phase 1 of P1 goes in
  `page="1"`. The `u-boot.itb` and the header + core are raw files
  (`bitswap="1"`), each assigned to both of its partitions. The P2
  partitions get no assignment.
- Check the sizes in the script: `u-boot.itb` ≤ 1 MB, header + core ≤
  0x110000.
- The flash loader is the **full** device string
  (`A5ED013BB32AE4SCS`). An abbreviated one resolved to a different JTAG
  IDCODE on the Nano.

### 2c. The application image for updates

A second quartus_pfg call writes the image an update puts into P1 or P2:

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
  `u-boot_P1.itb`, `u-boot_P2.itb` or `u-boot_FACTORY_IMAGE.itb`), then in QSPI
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
- `CONFIG_BOOTCOMMAND`: `bridge enable` (without it, Linux's first LWH2F
  access is a SIGBUS), then the running image's rootfs: `rsu running_slot`
  gives `FACTORY_IMAGE` -> `mmc 0:2`, `P1` -> `0:3`, `P2` -> `0:5`; the kernel
  and DT come from that rootfs's `/boot`, and `root=/dev/mmcblk0pN` names it
  (RAUC finds the booted slot from it). A rootfs without `/boot/Image`
  falls back to distro boot (the FAT's `extlinux.conf`). `scripts/config`
  puts the string through `sed`: no `&` in it (an `&&` turned into the old
  value), nested `if`s instead; the build checks the line.
- The SPL starts HPS watchdog 0 with a 30 s timeout (`WDT: Started
  watchdog ... (30s timeout)`). Leave it running: it is the safety net
  until Linux confirms the image.

**Check (after section 8):** the console shows
`rsu_spl_mmc_filename, filename: u-boot_P1.itb`,
`core <board>_P1.core.rbf from SD`, `rootfs mmc 0:3` and
`Kernel command line: ... root=/dev/mmcblk0p3`.

## 4. Kernel and device tree

Build these in (the root filesystem carries no modules):
- `INTEL_STRATIX10_RSU`;
- `FPGA_MGR_STRATIX10_SOC`, `FPGA_BRIDGE`, `FPGA_REGION`,
  `OF_FPGA_REGION`, `OF_OVERLAY`, `OF_CONFIGFS` (core reload);
- the QSPI drivers (`SPI_CADENCE_QUADSPI`, `MTD_SPI_NOR`);
- for RAUC bundles: `BLK_DEV_DM`, `DM_VERITY`, `CRYPTO_SHA256`, with
  `SQUASHFS`, `SQUASHFS_ZLIB` and `BLK_DEV_LOOP`.

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
- Kernel command line (U-Boot sets it, section 3): `watchdog.open_timeout=120`. The kernel keeps the
  SPL's watchdog fed only until a program opens it, or until this timeout
  runs out.

**Check:** `/sys/devices/platform/stratix10-rsu.0/` exists. Its files only
appear with an RSU layout in the flash. Also `cat /proc/mtd` shows
`u-boot` and `root`.

## 5. Root filesystem and the card

`linux/tools/make_rootfs_base.sh`, `alpine_rootfs_config.sh` and
`make_sdcard_image.sh`:

- **The card (MBR):** `p1` FAT (each image's `u-boot_<slot>.itb` and
  `<board>_<slot>.core.rbf`, a fallback kernel and `extlinux.conf`), `p2`
  the factory image's rootfs, `p3` P1's, `p4` extended with `p5` P2's and
  `p6` data. One rootfs image (`build/images/rootfs.ext4`) goes into all
  three slots and into image bundles; RAUC grows it to the partition
  (`resize=true`).
- **The rootfs is the same on every board** and gets nothing at first
  boot: python3 and e2fsprogs(-extra) are installed when the image is built
  (`make_rootfs_base.sh`: `apk --root --arch aarch64` in an x86 Alpine
  container). Its `/boot` holds the kernel and DT U-Boot loads.
- **Board state on `/data`** (`p6`, checked with `e2fsck -p` and mounted
  from inittab), behind links: `/opt/<board>web` (the GUI: releases, token,
  settings, supervisor), `/etc/<board>` (MAC, address), `/lib/firmware/rsu`
  (each image's core), and RAUC's state and artifact repositories
  (`/data/rauc`).
- **`rsu_client`, static** (`altera-fpga/intel-rsu`, a pinned commit, with
  static zlib). One static binary runs on musl. `/etc/librsu.rc`:
  ```
  log med stderr
  root qspi /dev/mtd1
  rsu-dev /sys/devices/platform/stratix10-rsu.0
  ```
- **RAUC** (`linux/build_rauc.sh`: 1.15.2, static, built in Docker; Alpine's
  is older than artifact repositories): `/usr/bin/rauc`,
  `/etc/rauc/system.conf` (`linux/board/rauc/system.conf`: slot groups
  P1 = `rootfs.0` + `qspi.0`, P2 = `rootfs.1` + `qspi.1`, the factory rootfs
  as read-only `recovery.0`, artifact repositories `gui` and `core`), the CA
  as `/etc/rauc/keyring.pem` (`linux/tools/rauc_keys.sh` makes the keys,
  outside the repository), and two handlers:
  - `bootloader` (RAUC's custom boot backend): `get-primary`/`set-primary`/
    `get-state`/`set-state` on `rsu_client`; `set-primary` also writes the
    RSU driver's `reboot_image` (a warm reboot reloads the running image
    otherwise) and clears the SDM's failure record if that image failed
    last; `get-primary` skips the failed image;
  - `post-install`: hands a GUI release to the GUI (localhost
    `POST /api/update`, then waits for the supervisor's verdict) and a core
    to `fpga_access.py`, and asks for the reboot after an image.
- **`/usr/sbin/rsu-confirm`** (`linux/board/rsu-confirm.sh`), started
  **first** in `/etc/rc.local`, in the background:
  - It opens `/dev/watchdog0` and feeds it every 5 s while it waits for
    "healthy". Here, healthy means `GET /api/board` on localhost answers
    `"id_ok": true`. That one answer proves the kernel, rootfs, GUI,
    register service, LWH2F and FPGA core all work.
  - When healthy, it writes `confirmed <image> <s>` to `/run/rsu-confirm`,
    resets the RSU retry counter and runs `rauc status mark-good`. It keeps
    feeding the watchdog, so a later hang still trips it.
  - When not healthy within `DEADLINE` (300 s), it stops feeding, and the
    SDM falls back.
  - On the factory image it only reports and always feeds the watchdog,
    because there is nothing below the factory image.
  - On TERM (shutdown) it disarms the watchdog with the magic close `V`.
    A KILL leaves it armed, and that is what the fallback test uses.
- **The card's FAT partition stays unmounted** (`noauto` in fstab). It is
  mounted only to write a file: write `.new`, fsync, rename, unmount.
- **Write before you point at it.** A GUI release unpacked seconds before
  the HPS stopped came back with every file 0 bytes after the power cycle
  (ext4 journal recovery), and `current` pointed at it. Every file a later
  boot depends on is fsync'd, with its directory, before a link names it.
- **Network that survives a reboot:**
  - Keep the MAC fixed (U-Boot's random MAC changes every boot; here it is
    kept in `~/.de25_std_mac` and lands on `/data`).
  - Send a gratuitous `arping -U` at boot.
  - Do the network work in the background after the gateway answers
    (`ntpd`).
  - Run `eth-watchdog`, which bounces an eth0 that passes no traffic.
- **The update token:** a file on the host (`~/.de25web_token_std`) and
  `/opt/de25web/token` on the board. Every upload needs it as `X-Token`;
  the signature is what decides whether a bundle is installed.

## 6. The update service on the board (`linux/webapp/`)

Three processes, started by `linux/board/de25web-supervisor.sh` (installed
once, outside every release):
- **`fpga_access.py`** is the only process that maps the LWH2F
  (`/dev/mem`). It serves register reads and writes over a Unix socket and
  does every load and every QSPI write, so it can stop all register traffic
  around one.
- **`temp_control.py`** is the application (the fan loop here).
- **`fpga_web.py`** is HTTP; it talks to the other two.

Rules that cost a hung board when broken:
- **No LWH2F access during a core load, and none for 0.5 s after it**
  (`POST_LOAD_SETTLE_S`). The pause has no time limit: a 120 s limit
  once expired during a hung load, and the next read hung the CPU.
- Do not write the bridge registers from Linux by hand (an SError here).
  Read the reset manager's `BRGMODRST` to see whether the fabric is up,
  and refuse register access while it is not.
- **Check before touching anything.** RAUC checks the signature, the
  verity hash tree and the board name; `fpga_access.py` still checks size,
  SHA-256 against the manifest, kind, and the periphery hash (for a core)
  or the slot sizes (for an image) before it erases or loads. A corrupt
  core with a matching manifest hung the SDM, and only a power cycle helped.

The endpoints:

| endpoint | does |
|---|---|
| `POST /api/bundle` | a `.raucb` (`X-Token`, `X-Sha256`; up to 512 MB, streamed to `/data/upload`). Starts `rauc install` in its own session (a GUI release restarts this server mid-install) and answers 202. The handlers then: a **GUI release** goes on test like any release and is kept only once confirmed; a **core** is loaded with `.pending`/`.prev`, checked (board id, variant, build id) and rolled back on failure; an **image** has been written by RAUC into the group not running - the rootfs, then the QSPI image through the bundle's install hook (`fpga_access.py install_rsu` with the slot: erase first, SSBL and CORE, the card files, the image last, verified) - and the board reboots into it after `rauc install` exits 0 |
| `GET /api/bundle` | that install: running, exit code, its output, whether a reboot follows |
| `POST /api/update/confirm`, `/api/update/rollback`, `/api/fpga/reload` | keep the GUI release on test (only once all three processes answer), go back to the previous one, load the installed core again |
| `GET /api/version`, `/api/fpga`, `/api/rsu` | the board name and GUI release; the running core build; the running and failed image, the confirmation, each application image (P1, P2) |

`POST /api/update` itself answers only on localhost (the post-install
handler). Uploads from before RAUC (`POST /api/fpga`, `/api/rsu`) are gone.

Refuse what the headers already show (no or wrong token, too big, an
install running) **before reading the body**, and close the connection.
The host side must then send its headers, wait a moment for an early
answer, and send the body only if none came (`request()` in
`linux/tools/board_http.py`). Otherwise it gets a broken pipe instead of
the 403.

## 7. The host tools (`linux/tools/`)

| tool | does |
|---|---|
| `rauc_keys.sh` | the development CA and code-signing key, once, in `~/.de25_rauc_keys` |
| `make_bundle.py gui\|core\|image` | a signed bundle; `image` = `rootfs.ext4` + the QSPI image (`make_rsu_bundle.py`: `rsu.json` + `app.rpd` + `u-boot.itb` + the core and its `.json`) + the install hook. GUI and core are artifacts and may ride along |
| `deploy_bundle.py` | checks the signature and the board name, uploads, follows `rauc install`, confirms a GUI release on test, and follows an image's reboot until the new image is confirmed - or reports the fallback. `--status` |
| `rauc_backend_test.py`, `rauc_handler_test.py`, `supervisor_test.py`, `gui_test.py` | the tests below |

A core only fits its phase 1, so an image bundle is all or nothing: the
image, its U-Boot, its core and its rootfs always come from one build.

## 8. First install on a board

1. Build: FPGA, then U-Boot/kernel/`rsu_client` (`./build.sh linux`), RAUC
   (`./build.sh rauc`), the `.jic` (which also writes the core, its manifest
   and `<board>_app.rpd`), the keys (`rauc_keys.sh`), then the card image
   (`./build.sh sdcard`, Docker for the rootfs base).
2. **QSPI:** `quartus_pgm -c "<cable>" -m jtag -o "pvi;build/images/<board>.jic"`.
   Check it says the operation succeeded. A failed erase leaves the
   flash unbootable; program it again. JTAG programming stops the HPS:
   nothing written on the board in the seconds before survives unless it
   was synced.
3. **Card:** `sd_recover.py` (over TFTP from U-Boot; 3.2 GB here), or a card
   reader.
4. Power-cycle. A `reboot` after a JTAG `.sof` load never comes back,
   because the SPL came over JTAG; test reboots only after a power-on boot.
5. `python3 linux/tools/deploy_bundle.py --status` should say
   `image P1, 'confirmed 0x00400000 ..'`, P1 priority 1 and running, P2
   `[disabled]`; `rauc status` on the board: booted `rootfs.0` (P1).

## 9. Tests that prove it

Run these once per new project, in this order. Those with a power cut or a
killed confirmation need someone at the power switch. Results here:
[plan_rauc.md](plan_rauc.md) "Status".

| # | test | expected (DE25-Standard result) |
|---|---|---|
| 1 | cold boot | SPL takes `u-boot_P1.itb`, `core <board>_P1.core.rbf from SD`, `rootfs mmc 0:3`, `rsu-confirm ... confirmed` (12 s) |
| 2 | host: `rauc_backend_test.py`, `rauc_handler_test.py`, `supervisor_test.py` | all pass (stand-ins for `rsu_client` and `rauc install`, the real supervisor with `--sim`) |
| 3 | GUI and core bundles | GUI release confirmed (11-12 s); a new core loaded in ~2 s, build id checked; a core whose manifest names another build: loaded, check failed, previous core back |
| 4 | bad bundles | another CA, a flipped payload byte (dm-verity: "data block ... is corrupted"), another board (`compatible`), an unconfirmed GUI release: refused or rolled back, `rauc install` fails, nothing changes |
| 5 | image bundle into P2, then into P1 | written into the group not running, reboot, confirmed: about 165 s from upload to confirmation each way |
| 6 | watchdog fallback: `kill -KILL` rsu-confirm on a new P2 | "watchdog did not stop!", the SDM loads P1, P2 recorded failed, RAUC shows P2 bad; a new install into P2 afterwards is confirmed |
| 7 | power cut during the rootfs write of an image install | the other image boots, confirmed; the interrupted one is disabled (RAUC marked it bad first); the next install into it is confirmed |

**Never** load a damaged core or image with a manifest made to match it,
unless someone is at the power switch (plan §5.8).

## 10. Recovery

| situation | do |
|---|---|
| fell back to the other image | it runs and answers; install a fixed image bundle (it goes into the failed slot, and `set-primary` clears the failure record) |
| another image by hand | `echo <offset> > /sys/devices/platform/stratix10-rsu.0/reboot_image; reboot` (P1 0x400000, P2 0x700000, factory 0x220000) |
| an image install cut short | that slot is disabled, the other image boots; install again |
| a core update failed | the previous core is back, or it is put back at the next start of `fpga_access.py` |
| a GUI release that cannot run | the supervisor reverts it (test time, crashes, empty files) |
| the board hangs, JTAG times out | power-cycle |
| nothing boots | program the `.jic` over JTAG and write the card with `sd_recover.py` |

On the board: `rauc status`, `rsu_client --log`, `cat /run/rsu-confirm`,
`/usr/lib/rauc/bootloader get-primary`,
`dmesg | grep 'rsu-confirm\|FPGA core\|eth-watchdog'`.

## 11. Porting checklist

Names and numbers that are board-specific in this repository:
- the board name (`de25-std`, also RAUC's `compatible`), the file prefix
  (`de25_std`), and the RSU bundle kind (`de25_std_rsu`);
- the board id, variant and build id registers and their values;
- the QSPI device and size, the flash loader string, and the QSPI
  reference clock;
- the partition addresses (sections 2b and 4) and the card layout (section
  5, `system.conf`, the boot command in `build_de25_linux.sh`, `IMAGES` in
  the GUI's `app.js`);
- the RAUC keys (a development CA lives on the build PC; a product needs
  one kept elsewhere);
- `QSPI_UBOOT_OFFS` and `QSPI_CORE_OFFS`, which must match the U-Boot
  build;
- the board IP address, the token file, the console port, and the JTAG
  cable name;
- the files the core load must check and the registers it must write back
  (`fpga_access.py`);
- what "healthy" means (`healthy()` in `rsu-confirm.sh`).
