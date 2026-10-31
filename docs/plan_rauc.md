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
| whole image (QSPI P1 + its U-Boot + its core) and its rootfs | slot class `image` (P1, custom install hook: `rsu_client`) + slot class `rootfs` (`rootfs.1`), one slot group | `rauc install`, `bootloader=custom` backend on `rsu_client` | yes | SDM + watchdog fall back to the factory image, which boots `rootfs.0` |
| factory image + `rootfs.0` | not RAUC slots (read-only for RAUC) | JTAG / SD card, on purpose | | |

The coupling in the last rows is the main design choice: **each QSPI image
boots its own rootfs.** The factory image's U-Boot boots `rootfs.0`, P1's
U-Boot boots `rootfs.1`. A P1 + `rootfs.1` pair that never confirms is
rolled back by the mechanism that already works and is tested (watchdog ->
SDM decision firmware -> factory image -> `rootfs.0`), so U-Boot needs no
boot counter and there is one A/B mechanism, not two.

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

## Step 2 - the whole image and its rootfs as one RAUC slot group

1. **SD card**: FAT, `rootfs.0`, `rootfs.1`, `data` (ext4: RAUC's state,
   artifact repositories, GUI releases, token, MAC, SSH host keys). The
   rootfs becomes the same for every card; everything board-specific
   moves to `data`. One reflash.
2. **U-Boot**: the image's U-Boot boots the rootfs of its slot (factory ->
   `rootfs.0`, P1 -> `rootfs.1`), from the kernel and DT in that rootfs's
   `/boot`. The image name is already known in U-Boot (`rsu running_slot`
   in the PREBOOT script).
3. **RAUC slots**: `[slot.rootfs.1]` (ext4) with `parent=image.1`;
   `[slot.image.1]` of `type=custom`, its install hook writes P1, its
   U-Boot and its core with the same order and checks as `POST /api/rsu`
   today (erase P1 first, write and verify P1 last, slot size, periphery
   hash). The factory pair is listed read-only.
4. **`bootloader=custom`** backend on `rsu_client` / sysfs: `get-primary`,
   `set-primary` (`reboot_image`), `get-state` / `set-state` (good = the
   `rsu-confirm` notify, bad = erase/disable P1). `rsu-confirm` calls
   `rauc status mark-good` when healthy.
5. **Bundle**: `make_bundle.py image` puts `app.rpd`, `u-boot.itb`, the
   core and the rootfs image in one signed bundle.

Done when, on the board (needs someone at the power switch):
- an image bundle installs, reboots into P1 + `rootfs.1`, and is confirmed;
- a P1 whose rootfs never gets healthy falls back to factory + `rootfs.0`
  through the watchdog;
- a power cut during the install leaves a booting board;
- the kernel and the rootfs changed with no SD card in hand.

## Open questions

- RAUC's `type=custom` slot with a parent: check that 1.15.2 installs the
  two slots of a group in the order we need (P1 erased before the rootfs
  is written, P1 written last), or do both in one hook.
- Rootfs size per slot (the card image's rootfs partition is 639 MB now;
  1 GB per slot is plenty).
- Production keys: the development CA lives on the build PC.
- Retire the old endpoints and tools after step 2, or keep the token
  endpoints for boards on old images.

## Status

| step | state |
|---|---|
| 1.1 RAUC build | done 2026-10-31: `linux/build_rauc.sh`; static aarch64 (8.7 MB, runs under qemu) and x86_64 (bundle creation); Alpine has no static libeconf, so its sources are compiled in (its `read_file` renamed: it clashes with RAUC's) |
| 1.2 kernel options | done: `BLK_DEV_DM`, `DM_VERITY`, `CRYPTO_SHA256` built in, checked with `SQUASHFS`, `SQUASHFS_ZLIB`, `BLK_DEV_LOOP` |
| 1.3 keys | done: `linux/tools/rauc_keys.sh` |
| 1.4 - 1.6 | written; on the host: `rauc_handler_test.py` 6/6 (GUI confirmed and repeated, GUI unconfirmed -> reverted, upload refusals 403/400/409/501, core refused/loaded/repeated, `deploy_bundle.py` end to end with a foreign-CA bundle refused, unknown repository); `supervisor_test.py` still 8/8. `rauc install` itself (signature, verity, `compatible` on the board) is untested until the board runs the new image |
| 1.7 on the board | 2026-10-31, in place over the console (no new card): new kernel on the FAT partition (the FAT has no room for two kernels, so the old one is in `/boot/Image.prev` on the rootfs), RAUC files on the rootfs, one `reboot`: P1 confirmed after 11 s, `rauc status` shows the booted `rootfs.0`. RAUC refused to start until `/var/lib/rauc/gui` and `/core` existed - `make_sdcard_image.sh` now creates them. `./build.sh sdcard` carries all of it |
| 1 on the board | 2026-10-31, `deploy_bundle.py`: GUI bundle installed and confirmed (12 s); core bundle of the running build: "already running" (3 s); another CA: refused (`unable to get local issuer certificate`); a flipped payload byte: refused (`verity: data block 4 is corrupted`, the install fails); `compatible=de25-nano`: rejected; a GUI release never confirmed: reverted by the supervisor after its 120 s, `rauc install` fails. The GUI never changed on a refusal |
| 2 | |

Still open in step 1:
- a core bundle that really loads a new build on the board (only the
  "already running" path ran there; loading and rollback ran with `--sim`);
- a combined GUI + core bundle on the board;
- the old endpoints and tools: retire them, or keep them for old images.

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
