# RAUC on an Agilex 5 SoC board - setup guide

How to give an Agilex 5 HPS + FPGA board signed, fail-safe network updates
with [RAUC](https://rauc.io): the web application, the FPGA core, and the
whole image (QSPI image, U-Boot, FPGA core, kernel, device tree, root
filesystem) as A/B updates that fall back by themselves.

The worked example is this repository (Terasic DE25-Standard,
`A5ED013BB32AE4SCS`, 16 MB MT25QU128 QSPI, Alpine Linux on the SD card).
Every step names the file that does it here. The design decisions and the
board measurements are in [plan_rauc.md](plan_rauc.md); the rest of the
update system (FPGA design settings, RSU layout basics, the web service)
is in [agilex5_network_update.md](agilex5_network_update.md).

**Before you start** you need what that guide's sections 1-4 set up: an
HPS-first design with `QSPI_OWNERSHIP HPS` and the HPS watchdog set to
"trigger remote update", an RSU flash layout, U-Boot with RSU multiboot,
the kernel's `stratix10-rsu` driver, `rsu_client`, and a health check
(`rsu-confirm`) that feeds the watchdog until the board is healthy.

Contents:

1. [The design](#1-the-design)
2. [Build RAUC](#2-build-rauc)
3. [Kernel](#3-kernel)
4. [Signing keys](#4-signing-keys)
5. [QSPI: a second application image](#5-qspi-a-second-application-image)
6. [U-Boot: each image boots its own rootfs](#6-u-boot-each-image-boots-its-own-rootfs)
7. [SD card: rootfs slots and a data partition](#7-sd-card-rootfs-slots-and-a-data-partition)
8. [system.conf](#8-systemconf)
9. [The boot backend](#9-the-boot-backend)
10. [Handlers and hooks](#10-handlers-and-hooks)
11. [Bundles](#11-bundles)
12. [Getting a bundle onto the board](#12-getting-a-bundle-onto-the-board)
13. [First install](#13-first-install)
14. [Tests](#14-tests)
15. [Traps we hit](#15-traps-we-hit)
16. [Porting checklist](#16-porting-checklist)

---

## 1. The design

### What RAUC does in an install

Read from RAUC 1.15.2's source (`src/install.c`), and it decides the layout:

1. Pick the **slot group that is not booted** (one slot of each root
   class: the inactive one, a "failed" one first). A booted slot and a
   `readonly` slot are never targets.
2. Mark the target **bad** through the boot backend - *before* writing
   anything.
3. Write the bundle's images **in the order of the manifest**.
4. Mark the target **active** (primary) through the boot backend.
5. Run the `post-install` handler.

So RAUC needs at least two writable slot groups and a booted one it can
recognise. "Factory image + P1, update P1 while it runs" does not work:
running P1, RAUC has nothing it may write.

### The layout

| group | QSPI (application image + its U-Boot + its core) | rootfs (card) | written by |
|---|---|---|---|
| factory (`recovery.0`, read-only) | `FACTORY_IMAGE`, `SSBL.FACTORY_IM`, `CORE.FACTORY_IM` | `mmcblk0p2` | JTAG and the card only - it is what always works |
| P1 (`rootfs.0` + `qspi.0`) | `P1`, `SSBL.P1`, `CORE.P1` | `mmcblk0p3` | RAUC, when P2 runs |
| P2 (`rootfs.1` + `qspi.1`) | `P2`, `SSBL.P2`, `CORE.P2` | `mmcblk0p5` | RAUC, when P1 runs |

plus a data partition (`mmcblk0p6`, `/data`) shared by all of them.

**Each QSPI image boots its own rootfs.** That couples the two A/B
mechanisms into one: the SDM's decision firmware already boots the
highest-priority image that has not failed and falls back when the
watchdog expires before Linux says it is healthy. RAUC only has to steer
the SDM's priorities; U-Boot needs no boot counter.

### RAUC mapped onto the SDM's remote system update

| RAUC | RSU (`rsu_client`, `/sys/devices/platform/stratix10-rsu.0`) |
|---|---|
| booted slot | `root=/dev/mmcblk0pN`, set by the image's U-Boot |
| mark the target bad | `rsu_client --disable <slot>`: a power cut from here boots the other image |
| write the rootfs | RAUC itself (ext4 image onto the partition, grown with `resize2fs`) |
| write the QSPI image | the bundle's install hook: erase the slot, U-Boot into `SSBL.<slot>`, core into `CORE.<slot>`, the card files, the image last, verified |
| mark active / primary | `rsu_client --enable <slot>` (top priority) **and** the slot's offset into `reboot_image` |
| mark good | `rsu-confirm` once healthy: `rsu_client --reset-retry-counter`, `rauc status mark-good` |
| a slot's state | bad if disabled/erased or the SDM's recorded failed image |

### Two kinds of bundle content

| content | RAUC object | reboot | way back |
|---|---|---|---|
| the web application | artifact repository `gui` (`type=trees`) | no | the application's own test/revert (here: the GUI supervisor) |
| the FPGA core | artifact repository `core` (`type=trees`) | no, a ~2 s pause | the previous core loaded back |
| the whole image | slot group P1 or P2 | yes, into it | the watchdog: the SDM loads the other image |

Artifacts install without touching any slot, so they work on the running
system. The post-install handler hands each one to the code that tests and
keeps or reverts it.

---

## 2. Build RAUC

`linux/build_rauc.sh` (`./build.sh rauc`) builds RAUC **1.15.2, static**,
twice: `build/rauc/rauc-aarch64` for the board and `build/rauc/rauc-host`
(x86_64) for making bundles.

Why build it:
- Alpine has RAUC only in edge, at 1.10.1. **Artifact repositories need a
  newer RAUC.**
- A static binary runs on the musl rootfs without extra packages.

How (this host cannot run arm64 containers - no binfmt):
- an **x86_64 Alpine container** (Docker, `--platform linux/amd64`);
- an **aarch64 sysroot** fetched with
  `apk add --root /sysroot --arch aarch64 --initdb --no-scripts --keys-dir /usr/share/apk/keys/aarch64 -X .../main -X .../community -U ...`
  (`--keys-dir` matters: without it apk 3 cannot verify the foreign index);
- **clang** cross-compiling against it (`--target=aarch64-alpine-linux-musl
  --sysroot=... -fuse-ld=lld`), meson with a cross file;
- packages: `glib-dev glib-static openssl-dev openssl-libs-static libffi-dev
  pcre2-dev pcre2-static zlib-dev zlib-static gettext-static util-linux-dev
  util-linux-static libeconf-dev`;
- **libeconf compiled in from source**: Alpine's static `libblkid` needs it
  and Alpine ships it only shared. Compile it with
  `-Dread_file=econf_read_file_` - its `read_file()` clashes with RAUC's;
- link args `-static -leconf` in the meson cross/native file (not
  `-Dc_link_args=a,b`: meson does not split that);
- options: `-Dservice=false -Dnetwork=false -Dstreaming=false
  -Djson=disabled -Dgpt=disabled -Dpkcs11_engine=false -Dtests=false`, and
  `-Dcreate=false` for the board (bundles are made on the PC).

Sources are pinned by SHA-256 (`rauc-1.15.2.tar.xz`, `libeconf-0.8.3`).
The PC also needs `mksquashfs`/`unsquashfs` (squashfs-tools) for bundles.

**Check:** `qemu-aarch64-static build/rauc/rauc-aarch64 --version` and
`build/rauc/rauc-host --version` print `rauc 1.15.2`; `file` says both are
statically linked. The board binary is about 8.7 MB stripped.

---

## 3. Kernel

Bundles are squashfs images checked by dm-verity. Build in (the rootfs has
no modules):

```
BLK_DEV_DM  DM_VERITY  CRYPTO_SHA256      (off or modules in defconfig)
SQUASHFS  SQUASHFS_ZLIB  BLK_DEV_LOOP     (usually there already)
```

`linux/build_de25_linux.sh` enables them with `scripts/config` and checks
each one in the final `.config`.

**Check:** on the board `ls /sys/module | grep dm_verity`, and
`grep squash /proc/filesystems`.

---

## 4. Signing keys

`linux/tools/rauc_keys.sh` makes, once, in `~/.de25_rauc_keys` (never in
the repository):

| file | use |
|---|---|
| `ca.cert.pem` | goes into the image as `/etc/rauc/keyring.pem` |
| `ca.key.pem` | signs signing certificates, nothing else |
| `signing.cert.pem`, `signing.key.pem` | sign bundles; the certificate carries `extendedKeyUsage=codeSigning` |

- The board config sets `check-purpose=codesign`. Without that, RAUC's
  default purpose check rejects a code-signing certificate ("unsuitable
  certificate purpose").
- OpenSSL before 3.2 has no `-purpose codesign` for `openssl verify`; check
  the extension instead.
- Keep the keys when you rebuild: a new CA makes every board refuse your
  bundles until its image is replaced.
- The board here has an RTC and NTP, so certificate times are checked
  against "now". A board that boots at 1970 needs
  `use-bundle-signing-time=true` in `[keyring]`.
- A product needs its CA kept somewhere other than the build PC.

**Check:** `rauc-host -c <conf with the keyring> info bundle.raucb` shows
the chain; a bundle signed with another CA (`rauc_keys.sh /tmp/other`)
fails with `unable to get local issuer certificate`.

---

## 5. QSPI: a second application image

`linux/make_jic.sh` (`AB=1`, the default) adds three empty partitions in
the free space; nothing else moves:

| partition | from | to |
|---|---|---|
| P2 | 0x700000 | 0x7FFFFF |
| SSBL.P2 | 0x800000 | 0x8FFFFF |
| CORE.P2 | 0xE20000 | 0xF2FFFF |

They get no assignment in the `.pfg`: P2 stays empty until the first image
update. The SPL and U-Boot find `SSBL.<slot>`, `CORE.<slot>` and the card's
`u-boot_<slot>.itb` / `<board>_<slot>.core.rbf` by the running image's
name already (RSU multiboot, `linux/patches/u-boot-rsu-running-slot.patch`),
so P2 needs no U-Boot code. The Linux MTD partition `root` (`/dev/mtd1`,
from SPT0 to the end of the flash) covers the new partitions.

Changing the partition table needs the `.jic` over JTAG once.

**Check:** the `.map` shows P2, SSBL.P2 and CORE.P2 at those addresses;
`rsu_client --count` / `--list N` on the board lists them, P2 `[disabled]`.

---

## 6. U-Boot: each image boots its own rootfs

`CONFIG_BOOTCOMMAND` (`linux/build_de25_linux.sh`):

```
bridge enable; setenv rootpart 2;
if rsu running_slot rsu_slot; then
  if test ${rsu_slot} = P1; then setenv rootpart 3;
  elif test ${rsu_slot} = P2; then setenv rootpart 5; fi; fi;
echo rootfs mmc 0:${rootpart};
if load mmc 0:${rootpart} ${kernel_addr_r} /boot/Image; then
  if load mmc 0:${rootpart} ${fdt_addr_r} /boot/<board>.dtb; then
    setenv bootargs console=ttyS0,115200 rw rootwait earlycon panic=-1 kvm-arm.mode=nvhe watchdog.open_timeout=120 root=/dev/mmcblk0p${rootpart};
    booti ${kernel_addr_r} - ${fdt_addr_r}; fi; fi;
echo no /boot/Image on mmc 0:${rootpart} - distro boot; run distro_bootcmd
```

(one line in the real file)

- The kernel and DT live **in the rootfs** (`/boot`), so an image bundle
  updates them with it.
- `root=` is how RAUC knows the booted slot (it matches `device=` in
  `system.conf`).
- A rootfs without `/boot/Image` (a card from before) falls back to distro
  boot from the FAT, so the new U-Boot also boots an old card.
- **No `&` in the string.** `scripts/config --set-str` puts the value
  through `sed`, where `&` is the matched text: `&&` turned into copies of
  the old `CONFIG_BOOTCOMMAND`, and the build failed in `autoconf.h`.
  Nested `if`s instead, and check the line afterwards (exactly one
  `CONFIG_BOOTCOMMAND`, the expected start and end).
- No double quotes inside either: the value goes into `.config` as it is.
- U-Boot reads DOS extended partitions (`mmc 0:5`).
- With `CONFIG_ENV_IS_IN_FAT`, make sure no saved `uboot.env` on the FAT
  overrides the built-in command.

**Check:** the console shows `rsu_spl_mmc_filename, filename: u-boot_P1.itb`,
`rootfs mmc 0:3`, and `Kernel command line: ... root=/dev/mmcblk0p3`.

---

## 7. SD card: rootfs slots and a data partition

`linux/tools/make_sdcard_image.sh` (MBR):

| partition | size here | contents |
|---|---|---|
| p1 FAT | 256 MB | each image's `u-boot_<slot>.itb` and `<board>_<slot>.core.rbf`, a fallback kernel + DT + `extlinux.conf` |
| p2 | 768 MB | the factory image's rootfs (`recovery.0`) |
| p3 | 768 MB | `rootfs.0` (P1) |
| p4 | | extended |
| p5 | 768 MB | `rootfs.1` (P2) |
| p6 | 512 MB | data (`/data`) |

**One rootfs image for every slot and every board** -
`build/images/rootfs.ext4`, 512 MB, written into p2, p3 and p5 and carried by
image bundles; RAUC grows it to the partition (`resize=true`, which needs
`resize2fs` on the board).

- **Nothing installed at first boot.** Every slot gets the same image, so
  packages go in at build time: `linux/tools/make_rootfs_base.sh` extracts
  the Alpine minirootfs and runs
  `apk add --root <tree> --arch aarch64 --no-scripts --keys-dir <tree>/etc/apk/keys --repositories-file <tree>/etc/apk/repositories -U python3 e2fsprogs e2fsprogs-extra`
  in an x86_64 Alpine container (`resize2fs` is in `e2fsprogs-extra`).
- **Board state on `/data`**, behind links in the rootfs:

  | in the rootfs | on `/data` | what |
  |---|---|---|
  | `/opt/<app>` | `/data/<app>` | the application, its releases, token, settings |
  | `/etc/<board>` | `/data/<board>` | MAC, IP address |
  | `/lib/firmware/rsu` | `/data/firmware/rsu` | each QSPI image's FPGA core and manifest |
  | (none) | `/data/rauc` | RAUC's `central.raucs`, the artifact repositories |

  The per-slot core directory on `/data` is what lets an image update leave
  the core for the slot it writes, whatever rootfs that slot gets.
- **Mount `/data` early**, from inittab: `e2fsck -p /dev/mmcblk0p6`, then
  `mount /data`, before `rc.local`.
- **No root line in fstab**: the root is whichever partition U-Boot named.
- **The artifact repository directories must exist** (`/data/rauc/gui`,
  `/data/rauc/core`): RAUC refuses to start without them ("Failed to
  initialize artifact repos").
- The FAT stays unmounted except while a file is written; mounted on
  `/boot` it covers the rootfs's own `/boot` - harmless while Linux runs.

The card image is written once (`linux/tools/sd_recover.py`: TFTP from
U-Boot, `gzwrite`; 3.2 GB here). From then on everything goes over the
network.

**Check:** `debugfs -R 'stat /boot/Image' build/images/rootfs.ext4`, the
links (`stat /opt/<app>` shows a fast link to `/data/...`), and on the
board `mount | grep -E 'mmcblk0p(3|6)'`.

---

## 8. system.conf

`linux/board/rauc/system.conf` → `/etc/rauc/system.conf`:

```ini
[system]
compatible=de25-std
bootloader=custom
data-directory=/data/rauc

[keyring]
path=/etc/rauc/keyring.pem
check-purpose=codesign

[handlers]
post-install=/usr/lib/rauc/post-install
bootloader-custom-backend=/usr/lib/rauc/bootloader

[slot.recovery.0]
device=/dev/mmcblk0p2
type=ext4
bootname=FACTORY_IMAGE
readonly=true

[slot.rootfs.0]
device=/dev/mmcblk0p3
type=ext4
bootname=P1
resize=true

[slot.rootfs.1]
device=/dev/mmcblk0p5
type=ext4
bootname=P2
resize=true

[slot.qspi.0]
device=/dev/mtd1
type=raw
parent=rootfs.0

[slot.qspi.1]
device=/dev/mtd1
type=raw
parent=rootfs.1

[artifacts.gui]
path=/data/rauc/gui
type=trees

[artifacts.core]
path=/data/rauc/core
type=trees
```

- **`compatible`** is the board name: a bundle for another board is
  rejected ("Compatible mismatch").
- **The bootnames are the SPT names** (`P1`, `P2`, `FACTORY_IMAGE`): the
  boot backend passes them straight to `rsu_client`.
- **The factory rootfs is its own class** (`recovery`), read-only. In class
  `rootfs` it could be picked as the inactive member and then refused as
  read-only.
- **`qspi.N` are `raw` slots on `/dev/mtd1`** with a parent. RAUC never
  writes them itself: the bundle's image for them carries `hooks=install`
  (section 10). Two slots on one device is fine in 1.15.2 (no duplicate
  check).
- **`data-directory` on `/data`**: RAUC's status must survive a rootfs
  being replaced.

**Check:** on the board `rauc status`:

```
Booted from: rootfs.0 (P1)
Activated: rootfs.0 (P1)
[recovery.0] (/dev/mmcblk0p2, ext4, inactive)   boot status: good
[rootfs.1]   (/dev/mmcblk0p5, ext4, inactive)   boot status: bad     <- P2 still empty
[rootfs.0]   (/dev/mmcblk0p3, ext4, booted)     boot status: good
```

On the PC, the config parses with `rauc-host -c <copy with local paths> info
<bundle>` (it needs writable `data-directory` and repository paths).

---

## 9. The boot backend

`linux/board/rauc/bootloader` (python3) → `/usr/lib/rauc/bootloader`. RAUC
calls it with:

| call | does |
|---|---|
| `get-primary` | print the image the SDM boots next: the enabled one of P1/P2 with the best priority (1 = highest) **that is not the SDM's recorded failed image**, else `FACTORY_IMAGE` |
| `set-primary P1\|P2` | `rsu_client --enable <n>` (top priority), **write the slot's offset into `reboot_image`**, and `rsu_client --clear-error-status` if that image is the one the SDM last recorded as failed |
| `get-state NAME` | `bad` if the slot is disabled/erased (`PRIORITY: [disabled]`) or is the failed image (`rsu_client --log`'s `FAIL IMAGE`), else `good`; the factory image is always good |
| `set-state NAME bad` | `rsu_client --disable <n>` (skipped for an already disabled slot) |
| `set-state NAME good` | nothing to write: a slot is good while enabled and not failed |
| `get-current` | the image whose offset is `CURRENT IMAGE` in `rsu_client --log` |

Exit 0 and the answer on stdout; non-zero and the reason on stderr.

Why each detail is there:
- **`reboot_image` in `set-primary`.** A warm `reboot` makes the SDM load
  the *running* image again, not the highest-priority one. Without it the
  first image install came back on P1 with P2 primary. (A power cycle goes
  by priority anyway.)
- **The failed image skipped in `get-primary`.** After a fallback the
  failed image keeps its priority (the SDM just skips it), and RAUC showed
  it as "Activated".
- **The failure record cleared in `set-primary`.** An install into the
  failed slot is a new image; the old record must not count against it.

Host test: `linux/tools/rauc_backend_test.py` runs every call against a
stand-in `rsu_client` that keeps the slots, priorities and the SDM's log in
a JSON file (`RSU_CLIENT`, `RSU_SYSFS` override the paths).

**Check:** on the board `/usr/lib/rauc/bootloader get-primary`,
`get-current`, `get-state P1`, `get-state P2`.

---

## 10. Handlers and hooks

### post-install handler (system side)

`linux/board/rauc/post-install` (python3) → `/usr/lib/rauc/post-install`,
on the rootfs - outside anything an update replaces at run time.

- **Activate only what this bundle carries.** Read
  `$RAUC_BUNDLE_MOUNT_POINT/manifest.raucm`: `[image.<repo>/<name>]` for an
  artifact, `[image.<class>]` for a slot image. RAUC's artifact links keep
  pointing at the last installed contents even after a trial rejected
  them, so activating "whatever the link points at" would bring back
  something that failed earlier (the Zynq Mini project's lesson). And
  recognise the slot form too: the first version looked only for `/` and
  failed every image bundle after RAUC had written both slots.
- **Application first, then the core**, so an application that knows a new
  core runs before the core loads.
- **The application** (`gui`): packed reproducibly (sorted, mtime 0, owner
  0) so the same tree gives the same release name, handed to the running
  application's own install path (here localhost `POST /api/update`), then
  wait for its verdict - confirmed: exit 0, reverted: exit 1. Skip it if it
  is already the confirmed release.
- **The core** (`core`): handed to the process that owns the FPGA
  (`fpga_access.py install_core` over its socket) with all its checks;
  skip it if that build runs already. Wait for the owner to answer first:
  an application update restarts it.
- **An image** (`rootfs`, `qspi`): RAUC already wrote the slots and made the
  group primary. Leave a marker asking for the reboot; do not reboot here -
  RAUC saves its status after the handler.
- A non-zero exit makes `rauc install` fail with the handler's output.

### install hook (bundle side)

`linux/board/rauc/image-hook`, shipped **in the image bundle** as `hook`
(`[hooks] filename=hook`, and `hooks=install` on `[image.qspi]`). RAUC calls
it with `slot-install` instead of writing the `qspi.N` slot, with
`RAUC_SLOT_BOOTNAME` (`P1`/`P2`, the parent's) and `RAUC_IMAGE_NAME` (an
absolute path in the mounted bundle).

It hands the QSPI image (an RSU bundle: application image, its U-Boot, its
core, a manifest) to `fpga_access.py install_rsu` with that slot and no
reboot. That code checks the bundle, refuses the running slot when both
exist, and writes in the order that keeps a power cut harmless: erase the
slot, `SSBL.<slot>`, `CORE.<slot>`, the card's `u-boot_<slot>.itb` and core,
the core and manifest for `/lib/firmware/rsu/<slot>`, then the image,
verified.

**Guard against an older writer.** An `fpga_access.py` from before the A/B
layout ignores the slot and writes P1 - even while P1 runs. The hook asks it
for its RSU state first and stops unless the answer has the per-image field
it only has in new versions.

### health and mark-good

`rsu-confirm` (started first in `rc.local`) feeds the watchdog until the
application answers healthy, then resets the RSU retry counter and runs
`rauc status mark-good`. If the image never gets healthy, it stops feeding
and the SDM falls back. That is the whole rollback of an image update.

---

## 11. Bundles

`linux/tools/make_bundle.py` (needs `build/rauc/rauc-host`, the keys,
`mksquashfs`):

```
python3 linux/tools/make_bundle.py gui            # the application
python3 linux/tools/make_bundle.py core           # build/images' FPGA core
python3 linux/tools/make_bundle.py gui core       # both, one bundle
python3 linux/tools/make_bundle.py image          # rootfs + QSPI image
python3 linux/tools/make_bundle.py gui --keys DIR # another key pair (refusal tests)
```

An artifact bundle's manifest:

```ini
[update]
compatible=de25-std
version=1.0.0-7790567_core1792432492
description=GUI 1.0.0+7790567, core build 1792432492 (...)

[bundle]
format=verity

[image.gui/de25web]
filename=gui.tar
convert=tar-extract

[image.core/de25_std]
filename=core.tar
convert=tar-extract
```

An image bundle's:

```ini
[update]
compatible=de25-std
version=build1793422905

[bundle]
format=verity

[hooks]
filename=hook

[image.rootfs]
filename=rootfs.ext4

[image.qspi]
filename=qspi.tar.gz
hooks=install
```

- `format=verity`: the board checks every block it reads against the hash
  tree in the signed manifest (a flipped byte: `verity: data block N is
  corrupted`, the install fails).
- `convert=tar-extract`: the **PC** unpacks the tar when it makes the
  bundle; the board installs a ready tree and needs no GNU tar.
- The image order is the write order: rootfs first, the QSPI image last.
- A squashfs smaller than 4096 bytes is refused at creation ("squashfs
  size must be larger than 4096 bytes") - irrelevant for real content.
- Sizes here: a GUI bundle 72 KB, a core bundle 0.9 MB, an image bundle
  46 MB (a 512 MB rootfs image compresses well).

**Check on the PC:** `rauc-host -c <conf> info --output-format=shell bundle`
(`RAUC_MF_IMAGES`, `RAUC_IMAGE_CLASS_<n>` from 0), `rauc-host extract`.
`info` checks the signature only; payload corruption shows up at install.

---

## 12. Getting a bundle onto the board

`POST /api/bundle` in the board's web service (`linux/webapp/fpga_web.py`):

- **Refuse from the headers** before reading the body: no or wrong token
  (403), too big (400), an install running (409), no rauc (501). The host
  side sends its headers, waits a moment for such an answer, and sends the
  body only if none came (`linux/tools/board_http.py`).
- **Stream the upload to disk** (`/data/upload`, up to 512 MB) and hash it
  on the way. An image bundle is tens to hundreds of MB; the board has 1 GB.
- **Run `rauc install` in its own session** (`start_new_session=True`) and
  answer 202 at once: an application release in the bundle restarts the web
  service mid-install, and the install must outlive it. Its output and exit
  code go to files; `GET /api/bundle` reports them.
- **Reboot after a good image install** - the runner checks the handler's
  marker once `rauc install` exits 0.
- Remove an upload left behind by a power cut when the service starts.

Host tool: `linux/tools/deploy_bundle.py` checks the signature locally,
checks the board name, uploads, follows the log, confirms an application
release that is on test, follows an image's reboot until the new image is
confirmed (or reports the fallback, and tells a reboot that did not switch
images from a fallback). `--status` shows what the board runs. The web page
has the same as an "Update" card.

Other ways RAUC offers - installing from an HTTP URL (streaming), D-Bus
service, hawkBit - are built out here (`-Dnetwork=false -Dstreaming=false
-Dservice=false`) and would need those options back.

---

## 13. First install

1. Build: FPGA, U-Boot/kernel/`rsu_client`, RAUC, the `.jic` (with P2),
   the keys, the card image (Docker for the rootfs base).
2. **Make sure nothing was written on the board in the last seconds**
   before step 3: JTAG programming stops the HPS, and data not yet on the
   card is lost.
3. The `.jic` over JTAG; power-cycle.
4. The card (`sd_recover.py`); power-cycle.
5. `deploy_bundle.py --status`: image P1, confirmed, P2 `[disabled]`; on the
   board `rauc status`: booted `rootfs.0` (P1).
6. An image bundle: it goes into P2 and the board boots P2. The next one
   goes into P1.

---

## 14. Tests

On the PC (no board):

| test | covers |
|---|---|
| `rauc_backend_test.py` | every backend call against a stand-in `rsu_client` |
| `rauc_handler_test.py` | `/api/bundle` and the post-install handler with the real application supervisor (`--sim`) and a stand-in for `rauc install`: application confirmed / reverted, core refused / loaded / repeated, upload refusals, the old upload paths refused from the network, the image reboot marker, an unknown repository |
| `supervisor_test.py` | the application's own test/revert, including a release whose files came back empty |

On the board (DE25-Standard results, [plan_rauc.md](plan_rauc.md)):

| test | result |
|---|---|
| application bundle | confirmed, 11-12 s |
| core bundle, new build | loaded in ~2 s, checked, 6 s in all |
| core whose manifest names another build | loaded, check failed, previous core back, `rauc install` fails |
| bundle from another CA / a flipped payload byte / another board | refused (signature / dm-verity / compatible) |
| application never confirmed | reverted after its test time, `rauc install` fails |
| image bundle into P2, then P1 | ~125 s install (rootfs 96 s, QSPI 16 s), reboot, confirmed: ~165 s from upload |
| confirmation killed on a new image (`pkill -KILL rsu-confirm`) | watchdog, the SDM loads the **other application image**, the failed one is `bad` in RAUC |
| install into the failed slot | confirmed, failure record cleared |
| power cut during the rootfs write | the other image boots, confirmed; the interrupted slot is disabled; the next install into it is confirmed |
| the Update card in a browser (`gui_test.py --bundle`) | application, core and image bundles (the image: rebooted into P1, the page back on its own showing it confirmed, 167 s), wrong token refused |

To time a power cut, wait on the **board's** install log
(`GET /api/bundle` until "writing data to device"), not on a local tool's
output - that is buffered and arrived too late the first time.

---

## 15. Traps we hit

| trap | symptom | fix |
|---|---|---|
| RAUC writes only the non-booted group | factory + P1 has nothing to write | A/B: P1 and P2 |
| Alpine's RAUC is 1.10.1 | no artifact repositories | build 1.15.2 static |
| static libblkid needs libeconf | link fails: `econf_*` undefined | compile libeconf in |
| libeconf's `read_file` | duplicate symbol | `-Dread_file=econf_read_file_` |
| `-Dc_link_args=-static,-leconf` | "unknown argument" | link args in the meson machine file |
| apk 3 and a foreign arch | "UNTRUSTED signature", "no such package" | `--keys-dir /usr/share/apk/keys/aarch64` |
| `check-purpose` default | "unsuitable certificate purpose" | `check-purpose=codesign` |
| repository directories missing | RAUC does not start | create them in the image |
| `&&` in `CONFIG_BOOTCOMMAND` | U-Boot build fails in `autoconf.h` | no `&`: `scripts/config` uses `sed` |
| handler parsed `[image.x/y]` only | image install "failed" after writing both slots | parse `[image.x]` too |
| warm reboot | came back on the old image | `reboot_image` in `set-primary` |
| failed image keeps its priority | RAUC "Activated" the failed slot | skip the failed image in `get-primary` |
| writes just before JTAG programming | files 0 bytes after the power cycle, application looping | fsync before pointing at new files; revert empty releases |
| power cut during an upload | 46 MB left on `/data` | remove stale uploads at start |
| a buffered local log | missed the moment for a power cut | wait on the board's log |
| an older writer ignores the slot | would erase the running image | the hook checks the writer's version first |

---

## 16. Porting checklist

- `compatible` (the board name) in `system.conf` and `make_bundle.py`.
- The SPT names (bootnames), the slot offsets (`reboot_image`), and the
  QSPI partition addresses (`make_jic.sh`).
- The card layout: partition numbers in `system.conf`, in the U-Boot boot
  command, in inittab/fstab (`/data`), and the sizes in
  `make_sdcard_image.sh`.
- The kernel and DT names in the rootfs's `/boot` and in the boot command.
- What lives on `/data` (the links in `alpine_rootfs_config.sh`).
- The artifact repositories and what the post-install handler hands them to.
- What "healthy" means (`rsu-confirm`), and the application's own
  confirm/revert.
- The keys: a development CA on the build PC; a product needs its own,
  kept elsewhere.
