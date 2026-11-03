# Build requirements

What a PC needs before `./build.sh all` works. Checked on Ubuntu 24.04
under WSL2 (2026-11-03), building from scratch. The builds also need
internet access: they clone the ATF, U-Boot, kernel and intel-rsu sources,
download the ARM toolchain, zlib and the Alpine minirootfs, and pull Docker
images.

## Quick install (Ubuntu / Debian)

```bash
sudo apt-get update
sudo apt-get install -y \
    git wget xz-utils bc bison flex make gcc libssl-dev libgnutls28-dev uuid-dev \
    python3 python3-dev python3-setuptools python3-serial swig device-tree-compiler \
    docker.io fakeroot e2fsprogs fdisk mtools gzip openssl
sudo usermod -aG docker $USER      # then log in again (or use: sg docker -c "...")
sudo service docker start          # WSL2 without systemd
```

Then install Quartus (below) and create the keys once (below).

## Per build step

| step | needs |
|---|---|
| `./build.sh fpga` | **Quartus Prime Pro 26.1.1** with Agilex 5 device support, in `~/altera_pro/26.1.1/quartus` (or set `QUARTUS_BIN`). Submodules: `git submodule update --init` |
| `./build.sh sim` | `nvc` >= 1.14 on `PATH`, VUnit (`pip install vunit_hdl`) |
| `./build.sh linux` | `git wget xz-utils bc bison flex make gcc libssl-dev python3 python3-dev python3-setuptools device-tree-compiler`, **`swig`** (U-Boot builds pylibfdt; without it the build stops with `error: command 'swig' failed`), `libgnutls28-dev`, `uuid-dev` (U-Boot host tools), about 10 GB free. The aarch64 cross toolchain is downloaded into `build/toolchain/` (or set `CROSS_TOOLCHAIN`) |
| `./build.sh rauc` | **Docker** (pulls `alpine:3.24` for `linux/amd64`) |
| `./build.sh jic` | Quartus (`quartus_pfg`), and the `fpga` and `linux` outputs |
| `./build.sh sdcard` | **Docker** (the Alpine rootfs base), `fakeroot`, `mkfs.ext4` (e2fsprogs), `sfdisk` (fdisk), **`mformat mcopy mmd` (mtools)**, `gzip`, `dtc`; the RAUC keys; the `linux`, `rauc` and `jic` outputs |

## Files outside the repository

Keep these out of git. `make_sdcard_image.sh` reads them, and the update
tools use them.

| file | what | how to get it |
|---|---|---|
| `~/.de25_rauc_keys/` | RAUC CA and signing key | `linux/tools/rauc_keys.sh`, once. A new CA means boards running an older card refuse bundles until they are re-imaged, so copy the existing keys to a new build PC |
| `~/.de25web_token_std` | web GUI update token | the first `sdcard` build writes one to `build/images/de25web_token`; copy it here so later cards keep it |
| `~/.de25_std_mac` | the board's fixed eth0 MAC | written by the first `sdcard` build |
| `~/.ssh/id_*.pub` | SSH public keys that may log in to the board as root | optional; `SSH_AUTHORIZED_KEYS="..."` overrides. Without any, SSH logins are impossible (the serial console still works) |

## Programming and board tools

| for | needs |
|---|---|
| JTAG from WSL2 (`tools/program.sh`, `quartus_pgm`) | [usbipd-win](https://github.com/dorssel/usbipd-win) on Windows: `usbipd bind` once, `usbipd attach --wsl --busid <b-p>` after every replug |
| serial console, `sd_recover.py`, `install_webapp.py` | `pyserial` (`python3-serial`), your user in the `dialout` group |
| `ddr_test.py`, `test_logger.py`, `test_stream.py` | `numpy` (`python3-numpy`) |
| network updates (`deploy_bundle.py`) | a host interface on the board's subnet (the tools default to `192.168.1.223`) |
