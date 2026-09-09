# HPS LWH2F register test

A bare-metal program letting a human, typing over HPS UART1, read and write
the `fpga_interconnect` register file (`uart_register_block.vhd`) through the
HPS's lightweight HPS-to-FPGA bridge (LWH2F / `lwhps2fpga`) — the same
registers the fabric UART already reaches (see the top-level README), now
poked from the ARM cores as plain memory-mapped I/O instead. Same bring-up
approach as [`../baremetal_uart1_test`](../baremetal_uart1_test) — **no ATF,
no U-Boot, no Linux, no SD card** — see that directory's README for the
fuller account of the pin-mux / clkmgr bring-up shared by both.

## ✅ The bridge itself is fixed and hardware-confirmed working (2026-09-09)

The root cause was in this project's own RTL, not anything HPS-side:
`de25_soc_top.vhd` drives `axi_bridge_reset` (the fabric-side reset for the
HPS's own `lwhps2fpga` hard macro) with `not system_reset` - but that signal
is **active-high** (see its declaration and the fan controller's
`reset => system_reset` a few lines below it in `uart_register_block.vhd`),
so it was inverted: the macro was released from reset instantly at
configuration and then held in **permanent** reset for the rest of normal
operation, regardless of any HPS-side software sequence or how long a
power-on-reset delay was configured. Fixed by dropping the `not`. Confirmed
on hardware immediately afterward from a live U-Boot prompt (Terasic's
u-boot-socfpga fork, see `linux/README.md`):
```
=> bridge enable 0x2
=> md.l 0x20000010 1
20000010: 0000de25
=> mw.l 0x20000030 0xcafef00d 1
=> md.l 0x20000030 1
20000030: cafef00d
```
register 1 (constant id), register 3 (loopback, write/read-back), and
register 4 (read-strobe counter, incrementing across reads) all work
exactly as they do over the fabric UART. See `linux/README.md`'s
session-status notes for the full trail (including a real ATF bug found
along the way - `agilex5_ddr.c`'s hardcoded 2GB DDR-size check - and how
this was chased down via a full ATF+U-Boot+Linux boot, not this file).

**This specific bare-metal test still hangs, for a separate, unresolved
reason** - see below. The bridge is not the mystery anymore; something
particular to running with no ATF at all still is.

## ⚠️ This file's own test still hangs - unresolved (separate from the bridge bug above)

`LWH2F_BASE` is `0x20000000`, given directly by the project owner from the
Agilex 5 HPS TRM (an earlier guess, `0xF9000000` - the Stratix10/Agilex1
convention that no locally available source could confirm or deny for
Agilex 5's newer NOC-based HPS - was tried first and empirically hung the
same way; see git history). Every concrete thing found in
`hps/baremetal-drivers` that software normally has to do before an
HPS-to-FPGA bridge is usable - all missing when running bare-metal with
no ATF, since ATF normally does them before Linux/U-Boot ever runs - has
been added and confirmed correctly applied on hardware via debug tracing
over UART1, and **none of it has changed the hang**:

1. **Bridge reset + enable** (`lwh2f_bridge_enable()`): deasserts
   `rstmgr`'s `LWSOC2FPGA` bit in `brgmodrst`, clears the idle handshake,
   and sets `LWSOC2FPGA_EN` in `sysmgr`'s `FPGA_BRIDGE_CTRL` - the
   LWSOC2FPGA-only subset of `baremetal-drivers`' `bridge_helper.cpp`
   `bridge_enable()` (which also does SOC2FPGA/F2SOC/F2SDRAM, since those
   bridges are disabled in `hps_subsystem.qsys`). Confirmed on hardware:
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
3. **`lwhps2fpga_axi_reset_reset` delayed like the rest of the reset
   tree** (`de25_soc_top.vhd`) instead of tied straight to `not
   CPU_RESET_n` (releasing within a clock or two of FPGA configuration
   finishing) - on the project owner's own prior experience, a bridge
   hard macro whose reset releases before the FPGA fabric driving it has
   settled can come up permanently wedged. Tried **both polarities**
   (asserted-high-for-~21ms-then-low, and the inverse) - synthesizes/
   fits/assembles clean either way, **identical hang both times**.
4. **SMMU status checked** - `hps/baremetal-drivers`' own
   `test/simics/bridge/bridge_test.c` (the *actual* official bridge
   test - an earlier pass through this project mischaracterised it by
   its directory name alone) notes "if SMMU is enabled, then
   MBOX_HPS_FPGA_CONFIG_COMP isolates the connection between HPS and
   FPGA", i.e. a required SDM mailbox handshake might gate bridge
   traffic when SMMU is on. Checked directly on hardware first, before
   implementing the mailbox call, so as not to chase it blind: `smmu
   IIDR = 0x4832243B` (matches the datasheet ID exactly - the read
   itself works) `CR0 = 0x00000000` - **SMMU_EN clear**. Per that same
   reference test's own conditional logic, the mailbox handshake is not
   needed when SMMU is disabled, so this is ruled out too.
5. **The actual Agilex 5-specific bridge-enable sequence, not the
   generic one.** Found via
   [`Ignitarium-Software/freertos-socfpga`](https://github.com/Ignitarium-Software/freertos-socfpga)
   - its `samples/bridge/lwhps2fpga_bridge.c` uses `LWH2F_BASE =
   0x20000000` too (**independent confirmation the address is right** -
   this is Intel's own sample, not derived from anything in this
   project), and its bridge enable goes through an SMC call to ATF
   (`SIP_SMC_HPS_SET_BRIDGES`). Chasing that into this project's own
   locally-built ATF source
   (`linux/build_output/arm-trusted-firmware/plat/intel/soc/common/soc/socfpga_reset_manager.c`,
   `socfpga_bridges_enable()`) found it has a **separate, more elaborate
   code path specifically `#if PLATFORM_MODEL == PLAT_SOCFPGA_AGILEX5`**
   - `baremetal-drivers`' `bridge_helper.cpp` (item 1 above) turns out to
   implement ATF's simpler `#else` (non-Agilex5, older SoCFPGA
   generations) path instead. Agilex 5's is a full flush cycle: request
   the handshake and wait for the ack to **assert** (not clear), assert
   reset again, clear the request, clear the ack (write-1-to-clear), only
   then deassert reset and enable in the system manager - reimplemented
   in `lwh2f_bridge_enable()` to match. On hardware: the ack **never
   asserts** (timed out; ATF's own code tolerates this same timeout and
   continues regardless, so this implementation does too) - board still
   hangs at the identical point afterward.

Every one of the five items above was independently confirmed correct,
inapplicable, or (item 5) implemented exactly per Intel's own Agilex
5-specific reference and still made no difference. The board hangs on
the register-1 self-test read - banner prints (now including the debug
trace for all five), then silence, exactly like the very first
wrong-address guess did.
`axi_lwh2f_bridge.vhd`'s read path has a 7-cycle watchdog that returns 0
if a request reaches it but nothing answers within the FPGA fabric - so
a multi-second hang, rather than that quick built-in timeout, means the
ARM's AXI transaction most likely never reaches the FPGA fabric pins at
all. `de25_soc_top.vhd`'s port wiring from `hps_subsystem`'s
`lwhps2fpga_*` ports through to `axi_lwh2f_bridge.vhd` was re-checked by
hand and looks correct (signal directions and names all match).

That the address matches Intel's own `freertos-socfpga` sample exactly
rules out address confusion as the cause. What's left is either a
NOC-level permission/routing gate that isn't exposed in any of
`hps/baremetal-drivers`, `noc_firewall.h`, the SMMU driver, or ATF's own
reset-manager source (all now checked about as far as they document
themselves), or - more likely, given `freertos-socfpga`'s own sample only
actually works reached *through ATF's SMC handler* rather than by poking
these registers directly from non-secure bare-metal code - something in
Agilex 5's boot chain that only ATF (running at EL3, or otherwise
privileged in a way this bare-metal test isn't) can set up, with no
non-secure/bare-metal equivalent documented anywhere found so far.
Recovering from every hang so far has just been a JTAG reprogram with a
known-good image; nothing else on the board has been affected.

**Update, 2026-09-09**: the "something only ATF/EL3 can set up" theory above
turned out to be wrong - see the fixed-and-confirmed section at the top of
this file. The actual bug was a plain RTL reset-polarity inversion in this
project's own `de25_soc_top.vhd`, nothing EL3/privilege-related at all - the
"tried both polarities, identical hang both times" claim in item 3 above
must have been testing under some other simultaneous issue, since the
corrected polarity alone (no other change) fixed LWH2F access completely,
confirmed from U-Boot.

That leaves a genuinely separate question: **why does this bare-metal test
specifically still hang** even with the bridge fixed? Two things ruled out
so far:
- **Not the fabric power-on-reset window.** `de25_soc_top.vhd` holds the
  HPS's `lwhps2fpga` hard macro in fabric-side reset for ~100ms after FPGA
  configuration (`g_por_cycles`), independent of HPS boot timing. This
  test's own `lwh2f_bridge_enable()` sequence (dominated by an
  always-timing-out, up-to-3,000,000-iteration hdskack poll) could
  plausibly finish inside that window and dispatch its self-test read too
  early, permanently hanging that one blocking AXI transaction. Added an
  explicit ~150-200ms `long_busy_delay()` before the read to test this -
  **made no difference**, reproducibly, across repeated tests (the delay is
  still probably a real requirement, just not the whole story - left in).
- **Not a flaky test harness.** The same binary was observed to both hang
  and succeed-past-the-trace-line across back-to-back reprograms with zero
  source changes early in this investigation, which looked like it might
  explain everything - but repeated, patient (30-40s, single continuous
  read window) testing confirms the hang past the debug trace is real and
  reproducible, not a serial-port-timing artifact of how this was tested.

Not yet root-caused. The bridge itself is proven working (U-Boot, this same
FPGA bitstream) - what's left is specific to this bare-metal test's own
environment (no ATF, EL3, whatever else genuinely differs from U-Boot's
SMC-mediated enable beyond the sequence of register writes, which are now
confirmed byte-for-byte identical to ATF's own Agilex5 path).

## Running the real thing instead: `freertos-socfpga`

[`Ignitarium-Software/freertos-socfpga`](https://github.com/Ignitarium-Software/freertos-socfpga)
has a genuine, Intel-published, presumably-working `lwhps2fpga_bridge_sample()`
(`samples/bridge/`) - not a reimplementation guessed from register
definitions the way everything above is. Running it directly, rather
than continuing to reverse-engineer its effect in bare-metal C, is
feasible in principle:

- This project already has ATF (`arm-trusted-firmware`) built from
  `linux/build_de25_linux.sh` - `freertos-socfpga`'s bridge sample needs
  BL31 running underneath it to handle the `SIP_SMC_HPS_SET_BRIDGES` SMC
  call its bridge driver makes, and that's already available.
- It is a **materially bigger undertaking** than anything else in this
  directory, though: FreeRTOS would need to become `bl33` (replacing
  U-Boot in the existing chain, or added as a second boot path), the
  sample's board support needs porting to this project's exact
  `hps_subsystem.qsys` pin-mux/handoff (not the stock GHRD the sample
  presumably targets), and the sample loads its FPGA bitstream itself
  from an SD card FAT filesystem via `fpga_manager` at runtime (a
  `core.rbf`, 8.3-filename-limited) - a different flow from this
  project's all-in-one JTAG `.sof` load, needing either adaptation or an
  SD card prepared to match.
- Not yet attempted here - this section exists to record that it's a
  real, considered option, not to claim it's done.

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
