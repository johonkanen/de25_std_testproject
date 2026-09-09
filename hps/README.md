# hps/ — Agilex 5 HPS subsystem for the DE25-Standard

A Platform Designer system, `hps_subsystem.qsys`, instantiated directly as
a VHDL `component` in `de25_soc_top.vhd` — the Agilex 5 HPS plus its DDR4
EMIF. No wrapper-generator script: Platform Designer wires
`intel_agilex_5_soc_0 ↔ emif_io96b_hps_0` internally, the same way
[`de25_nano_testproject`](https://github.com/johonkanen/de25_nano_testproject)
and the `datacenter_peak_shaving` DE25-Standard build do it.

## Where this came from

Vendored verbatim from `datacenter_peak_shaving/fpga/agilex/de25/ip/hps/`
(same author, same board, `device = A5ED013BB32AE4SCS`, DDR4), then trimmed:

| file | origin |
|------|--------|
| `hps_subsystem.qsys` | vendored, then `iopll_0` removed (see below) |
| `ip/hps_subsystem/hps_subsystem_intel_agilex_5_soc_0.ip` | vendored verbatim — HPS pin mux: EMAC0 (RGMII+MDIO), SD/MMC 4-bit, UART1, I2C1 |
| `ip/hps_subsystem/hps_subsystem_emif_io96b_hps_0.ip` | vendored verbatim — DDR4 EMIF |
| `ip/hps_subsystem/hps_subsystem_s10_user_rst_clkgate_0.ip` | vendored verbatim — Reset Release IP (`ninit_done`) |
| `hps_pins.tcl` | the 100 `HPS_*`/`DDR4_*` pin + IO-standard lines this pin mux actually drives, from `golden_top.qsf` |

No `USB0`/`SPIM0`/LCD-GPIO in this pin mux (unlike the earlier `hps_min.v`
generator this replaces) — smaller HPS config, smaller pin file.

## Bridges — kept as vendored, same as the sibling projects

| bridge | state |
|---|---|
| `H2F` (128-bit) | disabled |
| `LWH2F` (32-bit, lightweight) | **enabled**, exported as `lwhps2fpga` |
| `F2SDRAM` | disabled |
| `F2H` (ACE5-Lite) | disabled |
| F2H interrupts | enabled, exported as `fpga2hps_interrupt_irq0/1` |

`lwhps2fpga` and the F2H interrupts are exported from `hps_subsystem` but
**not yet wired to anything in the fabric** — `de25_soc_top.vhd` ties the
manager inputs idle (`awready`/`wready`/`arready` low, response channels
zero) and the interrupts to `0`. The register block in `de25_uart_top`
still only talks over its own GPIO UART. Point `lwhps2fpga` at
`fpga_interconnect` (or any AXI-Lite slave) to make it reachable from HPS
software.

## Removing `iopll_0`

The vendored `hps_subsystem.qsys` also had an `altera_iopll` (`iopll_0`,
50 MHz → `main_clock`/`modulator_clock`) feeding a flying-capacitor
modulator in the source project. This project's fabric runs on the DE25's
50 MHz oscillator directly, so it's unused — dropped with
[`trim_hps_subsystem.tcl`](trim_hps_subsystem.tcl):

```
qsys-script --package-version=25.1 --new-quartus-project=_t \
    --script=trim_hps_subsystem.tcl --search-path='ip/hps_subsystem,$'
rm -f *.qpf *.qsf; rm -rf _t*
```

`remove_instance`/`remove_interface` work on this `.qsys` even though its
component boundaries are cached ("generic component") — unlike editing an
instance's *parameters* (e.g. the bridge widths), which requires editing
the `.ip` file directly (not attempted here; the vendored bridge config was
already what this project wants).

## Building

Nothing to run by hand: `build_de25_soc.tcl` sets
`PROJECT_IP_REGENERATION_POLICY ALWAYS_REGENERATE_IP`, so `quartus_syn`
regenerates `hps_subsystem` itself from the `QSYS_FILE`/`IP_FILE`
assignments. To inspect the generated component port list (e.g. after
re-vendoring), run once:

```
qsys-generate hps_subsystem.qsys --synthesis=VHDL --part=A5ED013BB32AE4SCS --search-path='ip/hps_subsystem,$'
```
which writes `hps_subsystem/hps_subsystem_inst.vhd` — the source for the
`component hps_subsystem` declaration in `de25_soc_top.vhd`. Generated
trees (`hps_subsystem/`, `ip/hps_subsystem/hps_subsystem_*_0/`) are
git-ignored; only the `.qsys` and `.ip` files are tracked.

## H2F User0 clock (HPS-generated free-running clock to fabric) - not yet wired

The HPS IP has an "H2F User Clock" feature (`User0_clk_enable`/
`User0_clk_freq` parameters in
`ip/hps_subsystem/hps_subsystem_intel_agilex_5_soc_0.ip`, currently set to
`true`/`50.0` MHz) - a dedicated, free-running clock the ARM cores' clock
manager generates for FPGA fabric logic to use directly, independent of the
board oscillator. Started wiring this up (2026-09-09) but hit a genuine
tooling wall documented here so it isn't re-derived from scratch:

- Editing the `.ip` file's parameters is correct (per this file's own
  "editing an instance's parameters... requires editing the `.ip` file
  directly" note above) and does take effect - regenerating that `.ip`
  directly (`qsys-generate ip/hps_subsystem/hps_subsystem_intel_agilex_5_soc_0.ip
  --synthesis=VHDL --part=A5ED013BB32AE4SCS`, after deleting its stale
  generated output directory first to force a real regen) produces a real
  new port, `h2f_user0_clk_clk`, on that sub-component.
- **The problem**: `intel_agilex_5_soc_0` is a Platform Designer "Generic
  Component" (`CLASS_NAME = altera_generic_component`) - its interface list,
  as seen by the *system* (`hps_subsystem.qsys`, and hence by `de25_soc_top`
  which instantiates `hps_subsystem`), is a fixed snapshot cached at
  instance-creation time, not re-derived from the underlying `.ip` on
  regeneration. None of `qsys-generate hps_subsystem.qsys`,
  `reload_component_footprint`, `reload_ip_catalog`, or `load_component`
  (all real `qsys-script` commands, all tried) refresh it - the new port
  stays completely invisible at the system level no matter how many times
  the sub-IP is regenerated.
- The only lever left is the instance's `FILE` property (which `.ip` a
  Generic Component instance is loaded from) - but it's **read-only**
  through every scripting path tried: `set_instance_property` on the
  existing instance, `set_instance_property` on a freshly `add_instance`'d
  one (`add_instance <name> altera_generic_component 1.0` - 2 args is name+
  type only, 3 args' third slot is a *version* string, not a file path, and
  errors if it isn't a real registered version). `set_instance_parameter_value`
  also doesn't work on this component type at all (`No parameter named X`,
  even for parameters that definitely exist per the `.ip`'s own IP-XACT).
- Conclusion: associating a Generic Component instance with an updated
  `.ip` file appears to be a Platform Designer **GUI-only** action (whatever
  the right-click/dialog workflow is for it isn't exposed as a scriptable
  property at all) - not something achievable headlessly with the
  `qsys-script`/`qsys-generate` command-line tools alone.
- **Nothing was left in a broken state**: none of this touched
  `hps_subsystem.qsys` (confirmed via `git diff` - zero changes, since no
  attempt ever got far enough to call `save_system`). Only the `.ip` file's
  two parameter values changed, which is inert (nothing currently reads
  them into a build) until the interface actually gets exported.

**To finish this**: open `hps_subsystem.qsys` in the Platform Designer GUI
(not available in this headless dev environment), let it pick up the
already-edited `.ip` file's new `h2f_user0_clk` interface, export it at the
system level (same way `lwhps2fpga`/`hps_io`/etc. are already exported -
see the interface list this file's own investigation dumped via
`get_interfaces`/`get_instance_interfaces` for the exact existing pattern
to match), `save_system`, then add the new `h2f_user0_clk_clk` port to
`de25_soc_top.vhd`'s `component hps_subsystem` declaration and wire it to
a small isolated test module (not the existing register file/LWH2F path -
see the top-level README and this session's own discussion for why: no
CDC infrastructure exists there today).

## Status

Synthesizes as part of `de25_soc_top` (see the top-level README's build
log). Same hardware-verification status as before this refactor: the
fabric side has been programmed and confirmed on a real DE25-Standard; the
HPS/EMIF bring-up itself has not — see the top-level README.
