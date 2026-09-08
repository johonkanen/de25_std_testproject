# HPS LWH2F register test

A bare-metal program letting a human, typing over HPS UART1, read and write
the `fpga_interconnect` register file (`uart_register_block.vhd`) through the
HPS's lightweight HPS-to-FPGA bridge (LWH2F / `lwhps2fpga`) — the same
registers the fabric UART already reaches (see the top-level README), now
poked from the ARM cores as plain memory-mapped I/O instead. Same bring-up
approach as [`../baremetal_uart1_test`](../baremetal_uart1_test) — **no ATF,
no U-Boot, no Linux, no SD card** — see that directory's README for the
fuller account of the pin-mux / clkmgr bring-up shared by both.

## ⚠️ Still hangs on real hardware - unresolved

`LWH2F_BASE` is `0x20000000`, given directly by the project owner from the
Agilex 5 HPS TRM (an earlier guess, `0xF9000000` - the Stratix10/Agilex1
convention that no locally available source could confirm or deny for
Agilex 5's newer NOC-based HPS - was tried first and empirically hung the
same way; see git history). Two more things software normally has to do
before an HPS-to-FPGA bridge is usable at all - both missing when running
bare-metal with no ATF, since ATF normally does them before Linux/U-Boot
ever runs - were added and both confirmed working on hardware via debug
tracing over UART1:

1. **Bridge reset + enable** (`lwh2f_bridge_enable()`): deasserts
   `rstmgr`'s `LWSOC2FPGA` bit in `brgmodrst`, clears the idle handshake,
   and sets `LWSOC2FPGA_EN` in `sysmgr`'s `FPGA_BRIDGE_CTRL` - the
   LWSOC2FPGA-only subset of `baremetal-drivers`' `bridge_helper.cpp`
   `bridge_enable()` (which also does SOC2FPGA/F2SOC/F2SDRAM via SDM
   mailbox + SMMU machinery this test doesn't need, since those bridges
   are disabled in `hps_subsystem.qsys`). Confirmed on hardware:
   `brgmodrst` read `0x4F` (LWSOC2FPGA bit set, i.e. in reset) before and
   `0x4D` (bit cleared) after; the idle handshake ack cleared immediately;
   `fpga_bridge_ctrl` read `0x0` before and `0x2` after.
2. **NOC firewall permission** (`noc_firewall0`'s `LWSOC2FPGA` register,
   the same one as `hps_address_map.h`'s
   `SOCFPGA_L4_LWHPS2FPA_SCR_BASE`) - a *separate* per-master security
   register gating which masters may use the bridge, mirroring this
   driver's own `noc_firewall_test.c`. Confirmed on hardware: read back
   `0x0FFE0301` before any write (bit 0 - the bit this test sets - was
   already `1`, so this register was likely not the blocker) and `0x1`
   after explicitly setting it.

**Both confirmed applied correctly, and the board still hangs** on the
register-1 self-test read - banner prints (now including the debug trace
of both steps above), then silence, exactly like the wrong-address guess
did. `axi_lwh2f_bridge.vhd`'s read path has a 7-cycle watchdog that
returns 0 if a request reaches it but nothing answers within the FPGA
fabric - so a multi-second hang, rather than that quick built-in timeout,
means the ARM's AXI transaction most likely never reaches the FPGA fabric
pins at all. `de25_soc_top.vhd`'s port wiring from `hps_subsystem`'s
`lwhps2fpga_*` ports through to `axi_lwh2f_bridge.vhd` was re-checked by
hand and looks correct (signal directions and names all match).

That leaves the physical address itself still suspect (despite being
given directly rather than guessed - possibly it needs combining with
another base, or there's windowing/pagination this test doesn't do), or a
NOC-level permission/routing gate neither `bridge_helper.cpp` nor
`noc_firewall.h` expose (both are the full extent of what
`hps/baremetal-drivers` offers for this). Recovering from every hang so
far has just been a JTAG reprogram with a known-good image; nothing else
on the board has been affected.

## Register map

Same registers `uart_register_block.vhd` exposes to the fabric UART (see the
top-level README), addressed here as LWH2F byte offset `16 * reg`
(`axi_lwh2f_bridge.vhd` decodes AXI address bits `[19:4]` as the register
number — each register occupies a 16-byte-aligned slot):

| reg | name                | access |
|-----|---------------------|--------|
| 1   | constant id `0x0000DE25` | RO |
| 2   | git hash            | RO |
| 3   | loopback register   | RW |
| 4   | read-strobe counter (increments per read, any master) | RO |
| 5   | LED register, low 10 bits -> `LEDR[9:0]` | RW |
| 6   | `SW[9:0]`            | RO |
| 7   | `KEY[3:0]`, 1 = pressed | RO |
| 8   | uptime counter       | RO |

## Console

Once UART1 is up (115200 8N1, same divisor-reprogramming workaround as
`baremetal_uart1_test`) it accepts line-based commands:

```
r <reg>          read a register, e.g.  r 1        -> reg 00000001 = 0x0000DE25
w <reg> <value>  write a register, e.g. w 3 0x1234  -> wrote 0x00001234 to reg 00000003
?                print help
```

`<reg>`/`<value>` accept decimal or `0x`-prefixed hex. Backspace works.

## Build

```
# same toolchain as baremetal_uart1_test - see that README for the full
# curl/tar/export sequence if not already on PATH
export PATH="$HOME/aarch64-none-elf/bin:$PATH"   # or wherever it was extracted

# CMakeLists.txt's FetchContent_Declare(esw_bare SOURCE_DIR ...) points at
# ../baremetal-drivers - already cloned if baremetal_uart1_test was built
# first.

cmake -GNinja -B build . \
    -DATF_GIT_TAG=rel_socfpga_v2.10.1_24.11.03_pr
cmake --build build
# objcopy in generate_bin_file() resolves to the *system* objcopy (same
# CMake variable-scoping quirk as baremetal_uart1_test) - convert manually:
aarch64-none-elf-objcopy -O binary build/hps_lwh2f_regs.elf build/hps_lwh2f_regs.bin
aarch64-none-elf-objcopy -I binary -O ihex --change-address 0x0 build/hps_lwh2f_regs.bin build/hps_lwh2f_regs.hex
```

## Embed and load

Run from the repo root (`output_files/de25_soc.sof` needs the LWH2F-wired
`de25_soc` project built first):

```
quartus_pfg -c output_files/de25_soc.sof out.sof -o hps_path=hps/baremetal_lwh2f_regs/build/hps_lwh2f_regs.hex
quartus_pgm -c 2 -m jtag -o "p;out.sof@1"    # cable index depends on what else is attached
python3 -c "
import serial, time
s = serial.Serial('/dev/ttyUSB2', 115200, timeout=1)
time.sleep(0.3)
print(s.read(2000).decode(errors='replace'))
s.write(b'r 1\r')
time.sleep(0.2)
print(s.read(200).decode(errors='replace'))
"
```

`/dev/ttyUSB2` above was this session's device path — check
`ls /dev/serial/by-id/` for the `TERASIC_DE25-Standard_..._if01-port0`
symlink to find yours.

Same volatile-JTAG-load category as every other `.sof` in this project —
nothing persistent, nothing touches QSPI flash or an SD card.
