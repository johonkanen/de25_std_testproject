# Plan: RAUC for the network updates

Move the DE25-Standard's three network updates (GUI release, FPGA core,
whole QSPI image) onto [RAUC](https://rauc.io) bundles, the way
`~/dev/zynq_mini_example_project` does it (its `doc/network_update.md`), and
add the update the board cannot do today: kernel, device tree and root
filesystem over the network.

Started 2026-10-31. The current system is described in
[agilex5_network_update.md](agilex5_network_update.md); it keeps working
until each step below replaces a piece of it.

## Why

| | today | with RAUC |
|---|---|---|
| authenticity | a shared token (`X-Token`) and a SHA-256 in the request: stops accidents, not an attacker on the LAN | bundles signed with X.509; the board holds only the CA certificate and installs only what chains to it |
| integrity | SHA-256 of the upload, our own manifests | dm-verity over the whole bundle, checked on every read during the install |
| kernel, DT, rootfs | SD card only (take it out, or `sd_recover.py`) | an A/B rootfs slot pair, with automatic fallback |
| formats and tools | three bundle formats, three host tools, three endpoints | one bundle format (`.raucb`), one install path; HTTP install and hawkBit possible later |

What stays ours: the trial-and-rollback logic (the supervisor's release
test, `fpga_access.py`'s `.pending`/`.prev` core load with its board id,
variant and build id checks, `rsu-confirm`'s watchdog). RAUC calls it; it
does not replace it.

## Target layout

| layer | RAUC object | installed by | reboot | rollback |
|---|---|---|---|---|
| GUI release | artifact repository `gui` (type `trees`) | post-install handler -> the supervisor's existing test/confirm | no | the supervisor reverts to `previous` |
| FPGA core | artifact repository `core` (type `trees`) | post-install handler -> `fpga_access.py` (`install_core`) | no, ~2 s pause | `.prev` loaded back |
| whole image (an application image in QSPI + its U-Boot + its core) and its rootfs | slot groups `P1` (`rootfs.0` + `qspi.0`) and `P2` (`rootfs.1` + `qspi.1`): A/B | `rauc install` into the group not running; `qspi.N` written by the bundle's install hook (`rsu_client`), `bootloader=custom` backend on `rsu_client` | yes | the SDM + watchdog fall back to the other application image, and below both to the factory image |
| factory image + its rootfs | `recovery.0`, read-only: never a target | JTAG / SD card, on purpose | | |

The coupling in the last rows is the main design choice: **each QSPI image
boots its own rootfs** (factory -> `p2`, P1 -> `p3`, P2 -> `p5` on the
card). An image + rootfs pair that never confirms is rolled back by the
mechanism that already works and is tested (watchdog -> SDM decision
firmware -> the next image by priority), so U-Boot needs no boot counter
and there is one A/B mechanism, not two.

(The first version of this plan had factory + P1 only. RAUC writes only
the slot group that is *not* booted, and never a read-only one, so a board
running P1 would have had nothing RAUC may write. The QSPI has room for P2,
so it is A/B; decided 2026-10-31.)

## Step 1 - RAUC on the board, GUI and core as artifacts (no reboot paths change)

1. **Build RAUC** for the board: version 1.15.2 (as the Zynq project's
   Buildroot), static, musl. Alpine has only 1.10.1, in edge, without
   artifact repositories. Built by `linux/build_rauc.sh` in an x86_64
   Alpine container (Docker) with clang cross-compiling against an aarch64
   Alpine sysroot (`apk --arch aarch64`), because this host cannot run
   arm64 containers (no binfmt). Options: no D-Bus service, no network or
   streaming (bundles are uploaded to the board), no JSON, no GPT, no
   PKCS#11.
   The same script builds a static x86_64 `rauc` for the host (bundle
   creation, needs `mksquashfs`).
2. **Kernel**: build in `DM_VERITY`, `BLK_DEV_DM` and `CRYPTO_SHA256`
   (now off or modules; the rootfs has no modules). `SQUASHFS` and
   `BLK_DEV_LOOP` are already in. Checked by `build_de25_linux.sh` like the
   other options.
3. **Keys**: a development CA and a code-signing certificate, made once
   by `linux/tools/rauc_keys.sh` in `~/.de25_rauc_keys/` (outside the
   public repository). Only the CA certificate goes into the image as
   `/etc/rauc/keyring.pem`.
4. **`/etc/rauc/system.conf`** (`linux/board/rauc/system.conf`:
   `compatible=de25-std`, `bootloader=noop` for now,
   `data-directory=/var/lib/rauc` until step 2 adds a data partition,
   `[keyring] check-purpose=codesign`, the booted rootfs as a read-only
   slot - RAUC refuses everything until it recognises the booted slot -
   and the artifact repositories `gui` and `core`).
   The board has an RTC (PCF85263A) and NTP, so the default certificate
   time check should work; `use-bundle-signing-time=true` if not.
5. **Post-install handler** (`linux/board/rauc/post-install`, python3,
   on the rootfs - outside every GUI release, like the supervisor):
   activates only what the bundle carries (its `manifest.raucm`, as the
   Zynq project learned), GUI first, then the core. Each one already
   active is skipped. Neither path needed a change in the GUI release:
   - GUI: the artifact tree is packed reproducibly (same tree, same
     release name) and posted to the local `POST /api/update`, which
     installs it on test and restarts the GUI; the handler then waits for
     the supervisor's verdict - confirmed: exit 0, reverted: exit 1;
   - core: the tree is packed as a tar and given to `fpga_access.py`'s
     `install_core` over `fpga.sock`, with every check it does today.
6. **Upload**: `POST /api/bundle` in `fpga_web.py` (token, size and
   "already running" refused before the body, then the SHA-256). It
   starts `rauc install` **in its own session** and answers 202 at once:
   a GUI release in the bundle restarts `fpga_web.py` mid-install, and the
   install must outlive it. `GET /api/bundle`: running, exit code, output.
   **Host side**: `make_bundle.py gui|core|gui core` makes signed `.raucb`
   files in `build/images/`; `deploy_bundle.py` checks the signature
   locally, uploads, follows the log, and confirms a GUI release on test
   (as `deploy_web.py` does). The old endpoints stay until step 1 is proven.
7. **Getting there**: the new kernel and rootfs need one SD card write
   (`make_sdcard_image.sh`, then `sd_recover.py` or the card in a PC).

Done when, on the board:
- GUI and core bundles install over the network, no reboot, and are kept;
- a bundle signed by another key, a bundle with a flipped byte, and a
  bundle for another board (`compatible`) are refused before anything
  changes;
- a core that fails its checks and a GUI release that fails its test roll
  back, and `rauc install` reports the failure;
- the old tools still work (until they are retired).

## Step 2 - A/B: P1 and P2, each with its own rootfs

What RAUC does in an install (read in its 1.15.2 source): pick the slot
group that is not booted (`select_inactive_slot_class_member`), mark it
**bad** through the boot backend before writing anything, write the images
in the bundle's order, then make it **primary**. Mapped onto RSU:

| RAUC | RSU (`rsu_client`, `/sys/devices/platform/stratix10-rsu.0`) |
|---|---|
| mark the target bad (before writing) | disable the target slot: a power cut from here boots the other image |
| write `rootfs.N` | ext4 image onto the card partition |
| write `qspi.N` (last) | the bundle's install hook: erase the slot, the image's U-Boot into `SSBL.<slot>`, its core into `CORE.<slot>`, the card files `u-boot_<slot>.itb` / `de25_std_<slot>.core.rbf`, then the image into the slot, verified - the order and checks of today's `POST /api/rsu` |
| make it primary | the slot to the top priority |
| `rauc status mark-good` (from `rsu-confirm` once healthy) | `rsu_client --notify` as today; the slot stays |
| booted slot | `root=` from U-Boot (`/dev/mmcblk0pN`) |

1. **QSPI** (`make_jic.sh`, one `.jic` over JTAG): add `P2` 0x700000,
   `SSBL.P2` 0x800000, `CORE.P2` 0xE20000-0xF2FFFF to today's layout,
   nothing else moves. P2 starts empty; the first image update fills it.
   The SPL and U-Boot find `SSBL.<slot>` / `CORE.<slot>` / `u-boot_<slot>.itb`
   by name already (`linux/patches/u-boot-rsu-running-slot.patch`).
2. **U-Boot**: boot the kernel and DT from the rootfs of the running image
   (`rsu running_slot`: `FACTORY_IMAGE` -> `p2`, `P1` -> `p3`, `P2` -> `p5`;
   `/boot/Image`, `/boot/<dtb>`) with `root=/dev/mmcblk0pN`; the FAT's
   `extlinux.conf` stays as the fallback if that fails.
3. **SD card** (MBR): `p1` FAT (U-Boots, cores, a fallback kernel),
   `p2` factory rootfs, `p3` `rootfs.0` (P1), `p4` extended:
   `p5` `rootfs.1` (P2), `p6` data (ext4: RAUC's state and artifact
   repositories, the GUI under `/opt/de25web` - releases, token,
   `control.json` - the MAC). One rootfs image for every slot and board:
   nothing board-specific in it, python3 installed at build time (Alpine
   aarch64 packages through `apk --root --arch aarch64`, as for RAUC), not
   at first boot.
4. **RAUC** (`system.conf`): `bootloader=custom`; `[slot.recovery.0]`
   (`p2`, read-only, bootname `FACTORY_IMAGE`), `[slot.rootfs.0]` (`p3`,
   bootname `P1`), `[slot.rootfs.1]` (`p5`, bootname `P2`),
   `[slot.qspi.0]` / `[slot.qspi.1]` with `parent=rootfs.0/1`. The
   factory rootfs is its own class, so it is never picked as a target.
5. **Boot backend** (`bootloader-custom-backend`): `get-primary`,
   `set-primary`, `get-state`, `set-state` on `rsu_client` (`--list`,
   `--enable`, `--disable`, the fail record).
6. **Bundle**: `make_bundle.py image` - `rootfs.ext4` + the QSPI files
   (`app.rpd`, `u-boot.itb`, core + `.json`, as in today's RSU bundle) +
   the install hook; signed like the others. GUI and core artifacts may
   ride along.
7. **Reboot**: after a good install the post-install handler (or
   `deploy_bundle.py`) reboots into the new primary;
   `deploy_bundle.py` follows it to the confirmation, as `deploy_rsu.py`
   does.

Done when, on the board (needs someone at the power switch):
- an image bundle installs into the slot not running, reboots into it, and
  is confirmed; the next one goes into the other slot;
- an image + rootfs pair that never gets healthy falls back through the
  watchdog to the other application image;
- a power cut during the install leaves a board that boots;
- the kernel and the rootfs changed with no SD card in hand.

## Open questions

- Answered 2026-10-31 from the 1.15.2 source: RAUC marks the target bad
  before writing (= P1/P2 disabled first) and writes the images in the
  bundle's order (the QSPI image last); an image with `hooks=install`
  in the bundle is written by the hook instead of RAUC.
- Rootfs size per slot (the card image's rootfs partition is 639 MB now;
  1 GB per slot is plenty).
- Production keys: the development CA lives on the build PC.
- Retire the old endpoints and tools after step 2, or keep the token
  endpoints for boards on old images: retired 2026-10-31 (below).

## Status

| step | state |
|---|---|
| 1.1 RAUC build | done 2026-10-31: `linux/build_rauc.sh`; static aarch64 (8.7 MB, runs under qemu) and x86_64 (bundle creation); Alpine has no static libeconf, so its sources are compiled in (its `read_file` renamed: it clashes with RAUC's) |
| 1.2 kernel options | done: `BLK_DEV_DM`, `DM_VERITY`, `CRYPTO_SHA256` built in, checked with `SQUASHFS`, `SQUASHFS_ZLIB`, `BLK_DEV_LOOP` |
| 1.3 keys | done: `linux/tools/rauc_keys.sh` |
| 1.4 - 1.6 | written; on the host: `rauc_handler_test.py` 6/6 (GUI confirmed and repeated, GUI unconfirmed -> reverted, upload refusals 403/400/409/501, core refused/loaded/repeated, `deploy_bundle.py` end to end with a foreign-CA bundle refused, unknown repository); `supervisor_test.py` still 8/8. `rauc install` itself (signature, verity, `compatible` on the board) is untested until the board runs the new image |
| 1.7 on the board | 2026-10-31, in place over the console (no new card): new kernel on the FAT partition (the FAT has no room for two kernels, so the old one is in `/boot/Image.prev` on the rootfs), RAUC files on the rootfs, one `reboot`: P1 confirmed after 11 s, `rauc status` shows the booted `rootfs.0`. RAUC refused to start until `/var/lib/rauc/gui` and `/core` existed - `make_sdcard_image.sh` now creates them. `./build.sh sdcard` carries all of it |
| 1 on the board | 2026-10-31, `deploy_bundle.py`: GUI bundle installed and confirmed (12 s); core bundle of the running build: "already running" (3 s); another CA: refused (`unable to get local issuer certificate`); a flipped payload byte: refused (`verity: data block 4 is corrupted`, the install fails); `compatible=de25-nano`: rejected; a GUI release never confirmed: reverted by the supervisor after its 120 s, `rauc install` fails. The GUI never changed on a refusal |
| 1 cores on the board | 2026-10-31, a new FPGA build (1793422905, same periphery hash; `./build.sh fpga` + `jic` 4 min 31 s): core bundle loaded in 2.15 s, checked, card copy written, the old build kept as previous (6 s in all); GUI + core bundle (GUI `1.0.0+9ac2e21`, core 1792432492 from the old RSU bundle): GUI confirmed first, then the core loaded (12 s); a valid core whose manifest names another build id: loaded, check failed, previous core loaded back, `rauc install` failed, board id still answers. Board left on 1793422905 |
| 2 | done 2026-10-31: A/B (P1 + P2), all of "Done when" shown on the board |
| 2.1 QSPI | `make_jic.sh` (AB=1): `P2` 0x700000, `SSBL.P2` 0x800000, `CORE.P2` 0xE20000, empty; nothing else moved (checked in the `.map`) |
| 2.2 U-Boot | `CONFIG_BOOTCOMMAND`: `rsu running_slot` -> `mmc 0:2/3/5`, `/boot/Image` + DT from there, `root=/dev/mmcblk0pN`; FAT `extlinux.conf` (factory rootfs) as the fallback. `scripts/config` puts the string through `sed`: an `&&` in it turned into the old value (`&` = the match) - nested `if`s instead, and the build checks the line |
| 2.3 card | `make_sdcard_image.sh`: MBR p1 FAT 256 MB, p2/p3/p5 rootfs 768 MB (one `rootfs.ext4` of 512 MB, `resize=true`), p6 data 512 MB; `make_rootfs_base.sh` puts python3 and e2fsprogs(-extra) in at build time (docker, `apk --root --arch aarch64`); board state behind links into `/data` (`/opt/de25web`, `/etc/de25`, `/lib/firmware/rsu`, RAUC's `/data/rauc`) |
| 2.4 - 2.5 RAUC | `system.conf` (custom backend, `recovery.0` + groups P1/P2), `linux/board/rauc/bootloader` (host test `rauc_backend_test.py` 24/24 against a stand-in `rsu_client`) |
| 2.6 bundle | `make_bundle.py image`: `rootfs.ext4`, `qspi.tar.gz` (the RSU bundle) with `hooks=install` (`linux/board/rauc/image-hook` -> `fpga_access.py install_rsu` with the slot); `install_rsu` writes P1 or P2, never the running one when both exist (P1 as before without P2); the hook refuses an `fpga_access.py` from before |
| 2.7 reboot | the handler leaves a marker, the `/api/bundle` runner reboots after `rauc install` exits 0; uploads stream to `/data/upload` (up to 512 MB); `deploy_bundle.py` follows the reboot to the confirmation; `rsu-confirm` also runs `rauc status mark-good` |
| 2 on the board | 2026-10-31. Move to A/B: the `.jic` over JTAG (65 s, verified), power cycle, the card with `sd_recover.py` (3.2 GB `gzwrite`, CRC checked), power cycle: P1 boots `mmc 0:3`, `/data` mounted, confirmed at 12 s; `rauc status`: booted rootfs.0 (P1), P2 bad (empty), recovery.0 good. Image bundle (46 MB) into P2: rootfs 96 s + resize, QSPI P2 16 s, reboot, P2 (`u-boot_P2.itb`, `mmc 0:5`) confirmed at 12 s, 168 s in all; the next one into P1 the same way back. Confirmation killed on a new P2: watchdog, the SDM loaded **P1** (not factory), P2 recorded failed, RAUC P2 bad; a new install into P2 after that: confirmed, failure record cleared. Power cut at 53 % of the rootfs write into P2: back on P1, confirmed, P2 disabled (RAUC marked it bad first), `/data` clean; the next install into P2 confirmed |


Still open in step 1:
- the old endpoints and tools: retired 2026-10-31. `POST /api/fpga` and
  `POST /api/rsu` are gone; `POST /api/update` answers only on localhost
  (the post-install handler) and refuses the network with a pointer to
  `/api/bundle`; `deploy_web.py`, `deploy_fpga.py`, `deploy_rsu.py` and
  `rsu_refusal_test.py` are deleted (their packing code is in
  `payloads.py`, the early-answer request in `board_http.py`,
  `deploy_rsu.py --status` is `deploy_bundle.py --status`); the page's
  three upload cards are one Update card for `.raucb` files.
  `rauc_handler_test.py`'s `refusals` checks the old uploads from a
  non-loopback address.
  The page's Update card in a real browser (`gui_test.py --bundle`, headless
  Chromium, the file picked into the input): a GUI release (page reloaded
  into it and confirmed it, 10 s) and two real core loads (7 s, 6 s), each
  refused first with a wrong token. An image bundle through the page too
  (46 MB, hashed in the page's JavaScript): wrong token refused, then
  installed into P1 in 126 s, "the board reboots", the page came back by
  itself on P1 and showed it confirmed, 167 s from the click.

Board findings in step 2 (all fixed):
- A GUI release installed seconds before the HPS stopped (the JTAG
  programming) came back with every file 0 bytes after the power cycle,
  and `current` pointed at it: the GUI looped until `current` was put back
  by hand, 27 s before the watchdog. `Releases.install` fsyncs the files,
  their directories and the links now; the supervisor reverts a release
  with empty files (`supervisor_test.py` case `empty_files`).
- The handler did not recognise slot images (`[image.rootfs]`, no `/`):
  the first image install wrote both slots and made P2 primary, then
  failed in the handler (case `image_marker` now).
- A warm `reboot` reloads the running image, not the new primary: P2 was
  primary and the board came back on P1. `set-primary` writes the RSU
  driver's `reboot_image` now.
- After a fallback the failed image keeps its priority, so `get-primary`
  named it; it skips the SDM's failed image now, and `set-primary` clears
  the failure record when that image is made primary again.
- An upload cut short by a power cut stayed on `/data` (46 MB): removed
  when the GUI starts.
- On the host: a tool's output to a file is buffered, so a wait on that
  file missed the window for the power cut; the board's own install log
  (`GET /api/bundle`) is what to wait on.

Board findings:
- An install that fails while copying (the flipped byte) leaves a
  `.artifact-<name>-<hash>.tmp` directory in the repository (the Zynq
  project saw the same). Harmless; nothing points at it.
- After a revert, the GUI's `previous` link points at the reverted
  release (the supervisor's behaviour since Phase D, not RAUC's).
- The flipped-byte test needs new content: RAUC skips an artifact it
  already holds without reading it, so a corrupt copy of an installed
  bundle "succeeds" without using anything from it.

Host findings:
- `rauc info` checks the signature only; a flipped payload byte shows up
  at install time (dm-verity), so that refusal is a board test.
- OpenSSL 3.0 on this PC has no `-purpose codesign`; RAUC checks it itself.
- With `convert=tar-extract` the PC unpacks the tars when it makes the
  bundle: the board installs ready trees and needs no GNU tar.
