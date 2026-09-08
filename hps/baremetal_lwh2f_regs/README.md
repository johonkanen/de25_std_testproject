# HPS LWH2F register test

A bare-metal program letting a human, typing over HPS UART1, read and write
the `fpga_interconnect` register file (`uart_register_block.vhd`) through the
HPS's lightweight HPS-to-FPGA bridge (LWH2F / `lwhps2fpga`) — the same
registers the fabric UART already reaches (see the top-level README), now
poked from the ARM cores as plain memory-mapped I/O instead. Same bring-up
approach as [`../baremetal_uart1_test`](../baremetal_uart1_test) — **no ATF,
no U-Boot, no Linux, no SD card** — see that directory's README for the
fuller account of the pin-mux / clkmgr bring-up shared by both.

## ⚠️ LWH2F_BASE is an unverified guess

`hps_lwh2f_regs.c`'s `LWH2F_BASE` (`0xF9000000`) is **not** confirmed against
Intel's Agilex 5 HPS Technical Reference Manual — that manual wasn't
available while writing this. It's the address Cyclone V's successors
(Arria 10, Stratix 10, Agilex 1/7) have used for their LWH2F window since
their L3-remap generation; Agilex 5 is a newer NOC-based HPS and may not
match. An exhaustive search of everything available locally — this
project's `hps/baremetal-drivers` (including its "bridge" test, which turns
out to be about QSPI/NAND reset control, not FPGA bridges), the ATF and
U-Boot sources under `linux/build_output/`, `linux-socfpga`'s device trees
(no Intel SoCFPGA generation exposes a DT node for this bridge), and the
`~/dev/datacenter_peak_shaving` project this VHDL pattern is adapted from
(its `axi_led.vhd` fabric side is wired but was never, it turns out,
exercised by real ARM-side software) — found no documented address.

The program self-tests on startup: it reads register 1 (the constant ID,
always `0x0000DE25`) immediately after UART1 comes up and prints PASS/FAIL
*before* accepting any commands. If it prints FAIL (or nothing at all,
because the read hung/faulted), `LWH2F_BASE` is wrong for this chip — do not
trust any register read/write below it. Recovering from a wrong guess is
just a JTAG reprogram (`quartus_pgm`), same as everything else in this
project: nothing persistent is touched.

If you have the Agilex 5 HPS TRM, the real fix is to replace `LWH2F_BASE`
with the documented value and rebuild.

**Tried and empirically ruled out:** `0xF9000000` (the address builds and
programs cleanly). On real DE25-Standard hardware the banner prints in
full, then the board goes silent forever partway into the self-test read —
no PASS, no FAIL, nothing. `baremetal-drivers` installs no exception vector
table, so this is consistent with the load either faulting into an
unhandled/default vector or (more likely, since the AXI protocol is a
request/response handshake) the ARM core simply stalling forever on a
load whose AXI request never reaches anything that answers it — i.e. this
address isn't routed to the LWH2F NOC endpoint at all. Recovering just
took reprogramming over JTAG with a known-good image; nothing else on the
board was affected. Whatever address is tried next, expect the same
silent-hang failure mode if it's also wrong, not a clean error.

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
