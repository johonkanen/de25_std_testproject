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

## Status

Synthesizes as part of `de25_soc_top` (see the top-level README's build
log). Same hardware-verification status as before this refactor: the
fabric side has been programmed and confirmed on a real DE25-Standard; the
HPS/EMIF bring-up itself has not — see the top-level README.
