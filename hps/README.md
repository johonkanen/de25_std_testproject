# hps/ — Agilex 5 HPS + HPS-EMIF for the DE25-Standard

A minimal HPS subsystem for `de25_soc_top`: the Agilex 5 hard processor
system plus its DDR4 EMIF, with **every FPGA↔HPS bridge disabled**.

## What's vendored

| file | origin (DE25 GHRD `Demonstration/SoC_FPGA/GHRD/`) |
|------|--------------------------------------------------|
| `ip/hps_subsys/agilex_hps.ip` | `hps_subsys/ip/hps_subsys/agilex_hps.ip`, **then patched** (see below) |
| `ip/qsys_top/emif_io96b_hps.ip` | `hps_subsys/ip/qsys_top/emif_io96b_hps.ip`, verbatim |
| `hps_ddr4_pins.tcl` | the 123 `HPS_*` / `DDR4_*` pin + IO-standard lines from `golden_top.qsf` |

`agilex_hps.ip` keeps the GHRD's DE25 pin mux — EMAC0 (RGMII + MDIO),
SD/MMC 4-bit, UART1 console, USB0, I2C1, SPIM0, the LCD/gsensor GPIOs.

## The bridge patch

[`disable_bridges.py`](disable_bridges.py) flips five parameters in
`agilex_hps.ip` so the HPS has no AXI ports into the fabric:

```
H2F_Width          128 -> 0     LWH2F_Width        32 -> 0
f2s_data_width     256 -> 0     f2sdram_data_width 256 -> 0
F2H_IRQ_Enable    true -> false
```

This is why the design **cannot use the stock Terasic GHRD Linux image** —
that image's device tree maps the h2f / lwh2f bridge regions. Boot this one
with your own device tree (no `soc/bridge@*` nodes) and its own U-Boot SPL
handoff, regenerated from this project's Quartus output.

## Regenerating

```
python3 hps/disable_bridges.py          # idempotent; safe to re-run
qsys-generate hps/ip/hps_subsys/agilex_hps.ip   --synthesis=VHDL --part=A5ED013BB32AE4SCS
qsys-generate hps/ip/qsys_top/emif_io96b_hps.ip --synthesis=VHDL --part=A5ED013BB32AE4SCS
python3 hps/gen_hps_min.py              # writes hps_min.v from the two *_inst.v
```

The generated IP trees (`ip/*/*/`) are git-ignored; only the `.ip` source
and the scripts are tracked.

## `hps_min.v`

[`gen_hps_min.py`](gen_hps_min.py) generates [`hps_min.v`](hps_min.v): it
instantiates `agilex_hps` + `emif_io96b_hps` and wires the internal
`io96b0_to_hps` NoC bus (62 signals, AXI4 + AXI4-Lite) between them by
matching the role names in each IP's `*_inst.v`. The EMIF supplies the NoC
clock/reset, and the HPS clocks itself from `HPS_CLK_25`, so `hps_min`
needs no fabric clock or reset — it exposes only the physical `HPS_*` /
`DDR4_*` pins plus `h2f_reset` / `emac0_app_rst` (left unconnected at the
top).

`hps_min.v` is tracked so the project builds after `qsys-generate` without
re-running the generator; re-run it only if an IP's port list changes.
