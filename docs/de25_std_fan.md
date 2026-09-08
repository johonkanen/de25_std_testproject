# Fan control on the DE25-Standard

The DE25-Standard cools itself with a fan driven by a **MAX6650** fan-speed
controller (Maxim, `Datasheet/Fan-Control/MAX6650EUB+.pdf`). The FPGA does
not drive the fan directly — it talks to the MAX6650 over I2C, and the
MAX6650 runs its own closed-loop tachometer regulation.

## What is wired where

| signal | pin | IO standard | note |
|--------|-----|-------------|------|
| `FPGA_I2C_SCL` | PIN_BF120 | 3.3-V LVCMOS | I2C clock |
| `FPGA_I2C_SDA` | PIN_BH118 | 3.3-V LVCMOS | I2C data |

This bus is dedicated to the fan chip — not shared with anything else on
this board (unlike the DE25-Nano, where the equivalent chip sits on the
HDMI I2C bus). That wiring comes from Terasic's own board-management
demo, `Demonstration/SoC_FPGA/GHRD/board_management_ip/BOARD_MANAGEMENT.v`,
which instantiates its I2C master on `FPGA_I2C_SCLK`/`FPGA_I2C_SDAT` and
talks to the fan chip at 7-bit address `0x48` (`0x90 >> 1`).

## Control mode: closed-loop, not open-loop

Unlike the DE25-Nano's AMC6821, the MAX6650 has no open-loop
duty-cycle register to fall back on — closed-loop tachometer regulation
is its only real mode. Register 9 (`ktach_in`) is written straight into
the Speed register (`0x00`): the chip servos the fan's own PWM duty until
the measured tach count matches it. There is no ramping/kick logic in
`max6650_fan_control.vhd` the way there is in the DE25-Nano's
`amc6821_fan_control.vhd` - that servo action is the whole point of
closed-loop mode, so a stalled-from-rest fan is the chip's problem to
solve, not this driver's.

Register 9 is called "ktach", not "rpm", because the value written there
is the datasheet's KTACH encoding, not a linear RPM count - see below.

## Registers written at startup

Written in this order (fan chip only - this driver does not touch the
board's separate ADT7461 temperature sensor, which Terasic's
`BOARD_MANAGEMENT.v` shares a state machine with but is out of scope
here):

| reg | value | why |
|----:|-------|-----|
| `0x16` Count   | `0x01` | 0.5 s tach sample window |
| `0x02` Config  | `0x0A` | intermediate value while AlarmEnable and the final Config are still being written |
| `0x08` AlarmEn | `0x0F` | GPIO1 / tach-overflow / min-output / max-output alarms |
| `0x02` Config  | `0x29` | final: closed-loop operation, KSCALE = 2 |
| `0x04` GPIODef | `0xF5` | GPIO1 = FULL-ON input, GPIO0 = ALERT output |
| `0x00` Speed   | ktach  | the target - written last, and again whenever it changes |

All values taken verbatim from Terasic's `BOARD_MANAGEMENT.v`, not
derived.

## Choosing a target

```
KTACH = ((992 * KSCALE) / (RPM / 60)) - 1
```

straight from Terasic's own `auto_fan.v`. `g_fan_min_rpm` (default
**3500**) is converted to KTACH at elaboration time for register 9's
reset value - `3500 -> KTACH 33` with `KSCALE = 2`.

3500 RPM is Terasic's own `auto_fan.v` curve's minimum (its "Speed8", the
quietest point in their validated 3500-6000 RPM auto-fan ramp) - a
**vendor-chosen floor, not a soak-tested one**. Compare the DE25-Nano's
`g_fan_min_duty`, which was walked down live against real hardware and
measured holding a stable RPM for a 30 s soak (see
`de25_nano_testproject/docs/de25_nano_fan.md`) - nothing here has had
that same treatment yet. If 3500 RPM turns out to be higher (louder) or
lower (unstable) than necessary once this is on real hardware, walk
`g_fan_min_rpm` the same way that project's minimum duty was found.

## Measuring speed

```
rpm_out = 60 * Tach0Count
```

straight from `BOARD_MANAGEMENT.v`'s own `assign Fan_Speed = 60 * TACH0`
- a plain linear scale, unlike the KTACH encoding above (do not use the
KTACH formula in reverse for this - the two registers are not on the
same scale). `Tach0Count` (register `0x0C`) is 8 bits, so `rpm_out` tops
out at `60 * 255 = 15300`, comfortably above this board's fan range.

## Register map (this project's `uart_register_block.vhd`)

| addr | contents | access |
|-----:|----------|--------|
| 9  | KTACH target (Speed register encoding, see above) | RW |
| 10 | bits 7:0 raw Tach0Count, bits 23:8 rpm_out | RO |
| 11 | bits 7:0 Config readback, bit 8 init_done, bit 9 i2c_error | RO |

`config_readback` (reg 11 bits 7:0) is Config (`0x02`) read back once
right after the last configuration write completes - not part of the
ongoing poll, just a one-shot "the I2C link is alive and the write
landed" check. It should read `0x29` if the link works. The MAX6650 has
no separate device-ID register the way the AMC6821 does, so there is no
equivalent of the DE25-Nano's continuously-polled device ID.

## Debugging the I2C link

Register 11 is the place to start:

- **bits 7:0 (`config_readback`) reading `0x29`** — the I2C link works
  and the final configuration write landed.
- **bit 8 (`init_done`)** — the configuration sequence completed. It
  drops while the controller is retrying.
- **bit 9 (`i2c_error`)** — sticky: at least one write went unacknowledged
  since reset. `init_done` set together with `i2c_error` set means it
  failed once and has since recovered.

A write the MAX6650 does not acknowledge is followed by a STOP so the bus
is always released - never abandoned mid-frame - and the whole
configuration is retried after a ~100 ms back-off.

## Status

Clean synthesis/fit/assembly on both `de25_uart` and `de25_soc`,
source-grounded throughout against Terasic's own reference design, and
programmed onto a DE25-Standard. Not yet *confirmed* on that hardware,
though - no USB-serial adapter was attached to the fabric UART GPIO
header (see the top-level README) during that programming run to read
back register 10/11, and the fan's actual sound/speed was not observed
directly. Wire up a fabric UART adapter (or listen to the fan) and update
this section once it has been.
