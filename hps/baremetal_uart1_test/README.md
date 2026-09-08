# HPS UART1 bare-metal test

A minimal, from-scratch bare-metal program proving HPS UART1
(`HPS_UART_TX`/`HPS_UART_RX`) works, with **no ATF, no U-Boot, no Linux, no
SD card, no QSPI flash** — it runs straight out of HPS OCRAM as the very
first and only thing the ARM cores execute. Adapted from
[`de25_nano_testproject`](https://github.com/johonkanen/de25_nano_testproject/tree/main/hps/baremetal_uart1_test)
(same author, same bring-up approach, DE25-Nano) — see that project for
the fuller account of what each piece does.

**Hardware-verified working**, DE25-Standard, `de25_soc_top`'s
`hps_subsystem`:

```
=== de25_std_testproject HPS bare-metal UART1 test (v3) ===
no ATF, no U-Boot, no Linux - running straight out of HPS OCRAM
fsbl_configuration() rc = 0x00000000
handoff header_magic = 0x424F4F54
IOB15 (UART1 TX) pinmux sel = 0x00000005
IOB16 (UART1 RX) pinmux sel = 0x00000005
clkmgr_bringup() rc = 0x00000000
measured UART (L4_SP) clock = 100000000 Hz
divisor programmed = 54
type anything: it echoes back
```

Plus a live echo test: bytes sent from the host over `/dev/ttyUSB2` (the
DE25-Standard's on-board USB-Blaster III UART channel, distinct from the
JTAG interface on the same USB device) came back byte-for-byte identical.

`IOB15`/`IOB16` (pin-mux array indices 38/39) are the same UART1 TX/RX
slot as the DE25-Nano's — confirmed against this project's
`hps/ip/hps_subsystem/hps_subsystem_intel_agilex_5_soc_0.ip`
`HPS_IO_Enable` array, so `hps_uart1_test.c` needed no index changes, only
the banner text.

## What it took

Two things had to be brought up in software before UART1 would produce
anything but noise — both ported from real, tested Intel/Altera source
rather than derived or guessed (see file headers for exact provenance):

1. **Pin-mux** (`fsbl_configuration()`, part of
   `altera-fpga/baremetal-drivers`' `alterametal` library). Without it,
   nothing at all reaches the physical pins.
2. **Clock-manager PLL bring-up** ([`clkmgr_bringup.c`](clkmgr_bringup.c),
   ported from `altera-fpga/arm-trusted-firmware`'s
   `agilex5_clock_manager.c`). Without it, UART1 is correctly wired but
   transmits at the wrong rate — the clkmgr sits in "boot mode" out of
   reset with both PLLs fully bypassed, so `uart_init()`'s baud divisor
   (hardcoded assuming a 100 MHz clock) is wrong until something brings
   the PLLs up for real.

Both read the *same* SDM-provided handoff blob (a fixed OCRAM address)
that Quartus populates automatically from
`hps/ip/hps_subsystem/hps_subsystem_intel_agilex_5_soc_0.ip`'s
configuration — no register value in either file is derived or guessed.

## Build

```
# ARM GNU Toolchain, aarch64-none-elf (bare-metal, not -linux-gnu)
curl -LO https://developer.arm.com/-/media/Files/downloads/gnu/13.2.rel1/binrel/arm-gnu-toolchain-13.2.rel1-x86_64-aarch64-none-elf.tar.xz
tar xf arm-gnu-toolchain-13.2.rel1-x86_64-aarch64-none-elf.tar.xz
export PATH="$PWD/arm-gnu-toolchain-13.2.Rel1-x86_64-aarch64-none-elf/bin:$PATH"

# CMakeLists.txt's FetchContent_Declare(esw_bare SOURCE_DIR ...) points at
# ../baremetal-drivers, i.e. hps/baremetal-drivers - a sibling of this
# directory, NOT of hps/ itself:
git clone -b QPDS25.1_REL_GSRD_PR https://github.com/altera-fpga/baremetal-drivers ../baremetal-drivers

cmake -GNinja -B build . \
    -DATF_GIT_TAG=rel_socfpga_v2.10.1_24.11.03_pr
# (baremetal-drivers' generate_bin_file() unconditionally FetchContents an
# `atf` target even though this test needs no ATF - target_aarch64.cmake's
# default ATF_GIT_TAG no longer exists upstream. Any valid tag from
# `git ls-remote --tags https://github.com/altera-opensource/arm-trusted-firmware.git`
# unblocks it, or point FETCHCONTENT_SOURCE_DIR_ATF at an existing
# arm-trusted-firmware checkout - e.g. linux/build_output/arm-trusted-firmware
# if you've already run linux/build_de25_linux.sh - to skip the fetch
# entirely.)
cmake --build build
# objcopy in generate_bin_file() resolves to the *system* objcopy due to a
# CMake variable-scoping quirk in baremetal-drivers' target_aarch64.cmake -
# the .elf link itself succeeds; convert manually instead:
aarch64-none-elf-objcopy -O binary build/hps_uart1_test.elf build/hps_uart1_test.bin
aarch64-none-elf-objcopy -I binary -O ihex --change-address 0x0 build/hps_uart1_test.bin build/hps_uart1_test.hex
```

## Embed and load

Run from the repo root (`output_files/de25_soc.sof` comes from building the
main project first — see the top-level README's Build section):

```
quartus_pfg -c output_files/de25_soc.sof out.sof -o hps_path=hps/baremetal_uart1_test/build/hps_uart1_test.hex
quartus_pgm -c 1 -m jtag -o "p;out.sof@1"    # cable index depends on what else is attached
python3 -c "
import serial, time
s = serial.Serial('/dev/ttyUSB2', 115200, timeout=1)
time.sleep(0.3)
print(s.read(500).decode(errors='replace'))
"
```

`/dev/ttyUSB2` above was this session's device path with two boards
attached (DE25-Nano + DE25-Standard) — check `ls /dev/serial/by-id/` for
the `TERASIC_DE25-Standard_..._if01-port0` symlink to find yours.

Same volatile-JTAG-load category as every other `.sof` in this project —
nothing persistent, nothing touches QSPI flash or an SD card.
