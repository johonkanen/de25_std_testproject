# Plan: oscilloscope and data logger on the DE25-Standard

An oscilloscope (triggered captures) and a continuous stream / data logger for signals inside
the FPGA, viewed in the web GUI, in the spirit of the Ti60 PSU board's 62.5 MB/s stream
(`~/dev/ti60_ac_psu/ti60_ac_inout_psu/docs/data_stream.md`).

## Decisions so far (2026-10-31)

- **Internal FPGA signals first.** The on-board TLA2518 ADC and an external isolated ADC come
  later (phase 5).
- **The FPGA-to-HPS buses were enabled without the Platform Designer GUI** (done:
  `fpga/hps/README.md`, "F2SDRAM and F2H: enabled headlessly").
- **The HPS is wrapped in `fpga/hps/hps.vhd`** with one record in and one out per AXI bus
  (`fpga/hps/hps_axi_pkg.vhd`).
- Sample format as on the Ti60 unless decided otherwise: records of 8 × int16 channels.

## What the Ti60 design did, and what changes here

On the Ti60 the soft CPU never touched the samples: `scope_capture` → `scope_axis_writer` →
a write-only DMA into a 32 MB HyperRAM ring → the Ethernet MAC's DMA read the payload
straight from the ring, a checksum inserter in fabric filled in IPv4/TCP checksums, and the
CPU only wrote three header words per 1460-byte TCP segment (its own `tcp_stream`, because
Zephyr's stack managed 1.7 MB/s). The HyperRAM, carrying writes and reads at once, set the
62.5 MB/s ceiling.

| Ti60 | DE25-Standard |
|---|---|
| `fpga_scope` (`scope_capture`, `scope_axis_writer`, test generator, probe table) | reused (submodule); it talks `hVHDL_fpga_interconnect`, as our `register_block` does |
| write-only DMA into a 32 MB HyperRAM ring | an AXI4 burst writer into a reserved region of the HPS DDR4 (1 GB on the board): 128-256 MB, seconds at 62.5 MB/s; DDR4 bandwidth is no limit |
| Ethernet DMA from the ring, checksum inserter, `tcp_stream`, driver fast path | not needed: Linux on the A76 cores fills gigabit Ethernet with ordinary socket writes of large chunks from the ring |
| register 22 (records taken) | the same, over LWH2F; optionally an F2H interrupt |
| `collect.html`, `collect_worker.js`, scope page, `test_stream.py` | ported to our web GUI |

With 16-byte records gigabit Ethernet (about 118 MB/s of payload) allows about 7 MS/s.

## Phase 1: done (2026-10-31), on the board (2026-11-01)

- FPGA: `fpga/source/fpga_scope` (submodule, at c88a58e) on the register bus in
  `register_block.vhd` through `fpga/scope_block.vhd`: registers 256..278, 4096 samples
  x 8 channels in block RAM on core_clock (up to 50 MS/s), the last capture read through
  the window at register 0x8000.. (one 32-bit read per word over LWH2F, 6 clocks per read
  in simulation; the LWH2F bridge's read timeout went from 7 to 15 clocks). Probes:
  fan rpm and tach, switches, keys, LEDR (digital), LEDR0/LEDR9 brightness, the fan's
  I2C lines and drives. Register 16 bit 2 says the core has the scope.
  `fpga/sim/scope_block_tb.vhd`: the counter steps by one over a whole capture read
  through the window, a probe lands in its channel, a read answers in time.
- Linux: `fpga_access.py` ops `scope_info`, `scope_capture`, `scope_stop` (and a
  simulated scope for `--sim`); `fpga_web.py` `GET /api/scope`, `POST
  /api/scope/capture`, `POST /api/scope/stop`; the scope card in the GUI (one strip per
  channel on one time axis, digital sources as bit lanes, crosshair readout, CSV).
  `gui_test.py` takes a capture with it.
- The core grew to 1.23 MB and no longer fits a QSPI core slot (1.11 MB): decided to
  keep the layout and load such a core from the SD card only (`make_jic.sh`,
  `install_rsu`, `docs/agilex5_network_update.md`; `linux/tools/rsu_install_test.py`).
- On the board (2026-11-01): build 1793479599 in P2 through an image bundle (CORE.P2 erased,
  not written; the core from the card), confirmed; `gui_test.py` against the board passes,
  scope included (the sine triggers at 0, the counter steps by one over 1023 samples).

## Phase 2: done (2026-11-01), on the board

- FPGA: `fpga/scope_ddr_writer.vhd` takes `scope_capture`'s deep capture port (scope
  register 10 bit 0) and writes 256 bit AXI4 bursts (16 beats, up to 8 in flight) into a
  ring of 2^23 records (128 MB) in the HPS DDR, over F2SDRAM or F2H (register 289 bit 0),
  with AxCACHE / AxDOMAIN / AxPROT / AxUSER from the same register. Records in memory as on
  the Ti60: record r at ring + 16r, channel c at +2c. A capture's last odd record is
  written with only its half strobed; `capture_written` counts records whose burst was
  answered. A pattern fill (word i = seed + i, as fast as the bus takes it, clocks
  counted) measures a bus without the scope. Registers 288..297 (the file's header).
  `fpga/sim/scope_ddr_writer_tb.vhd`: an AXI memory on each bus stalling at random; a
  record every clock (50 MS/s) never fills the FIFO.
- Linux: `reserved-memory` `scope-ring@b0000000`, 128 MB, not no-map; the kernel without
  `CONFIG_STRICT_DEVMEM`, so `/dev/mem` maps it cached, or uncached with `O_SYNC`.
- `linux/tools/ddr_test.py` (on the board): per bus setting the fill's MB/s, uncached and
  cached read MB/s, every word checked, stale cache lines after a new fill, and a deep
  capture of the counter at 50 MS/s checked sample by sample.
- On the board (2026-11-01, build 1793520573 in P1, `ddr_test.py --size 16 --repeat 3`):

  | bus setting | write MB/s | uncached read MB/s | cached read MB/s | words wrong | stale of 16384 |
  |---|---|---|---|---|---|
  | F2SDRAM, AxCACHE 0010 | 1280 | ~415 | ~1250 | 0 | ~15500 |
  | F2H, non-shareable, 0011 | 1219 | ~415 | ~1250 | 0 | ~14500 |
  | F2H, inner shareable, 1111 | 1219 | ~415 | ~1250 | 0 | ~15500 |
  | F2H, outer shareable, 1111 | 1219 | ~415 | ~1250 | 0 | ~15400 |

  - The ring's F2SDRAM address is its HPS physical address (0xB0000000): the data lands
    where Linux reads it, no bus errors.
  - F2H passes the SMMU (no errors, nothing in dmesg) but is **not coherent** with any
    AxDOMAIN / AxCACHE above, nor with AxUSER 0x00..0xFF (single bits, 0xE0, 0xFF): a
    cached mapping keeps the old data (stale: 64 KB read cached four times, a new fill,
    read cached again). Coherent F2H probably needs CCU / system manager setup that the
    firmware does not do; not pursued.
  - Writes: 1280 MB/s is 80 % of the bus's 1.6 GB/s at 50 MHz; the scope needs 800 MB/s at
    50 MS/s. Deep captures of 8M samples (122 MB) at 50 MS/s over either bus: nothing
    lost, the counter steps by one throughout, the FIFO never above 18 of 512 beats.
  - Reads: uncached (`O_SYNC`) 415 MB/s, every word right: 3.5 times gigabit Ethernet's
    118 MB/s. Cached reads are 3x faster but see stale lines.
- **Proposed for phase 3:** F2SDRAM, read uncached from user space. Fast enough for line
  rate, and needs no kernel driver. Cached reads plus cache invalidation would need one.

## Phases

1. **Triggered scope in block RAM.** `fpga_scope` into the FPGA design on the register bus;
   sources: the test generator, a counter, fan rpm, other internal signals. A scope card in the
   web GUI reads captures over LWH2F.
2. **FPGA → DDR.** An AXI burst writer (`t_axi256_m2s`) behind `scope_axis_writer`, a
   reserved-memory node in the DT, the ring exposed to user space. Measure, before choosing:
   - F2SDRAM (not coherent): the ring mapped uncached in Linux; read bandwidth?
   - F2H through the CCU: which AxDOMAIN / AxCACHE make writes coherent, and then a cached
     mapping (check with a counter pattern that no stale lines are read).
3. **Continuous stream.** A streaming server on the board (WebSocket, like the Ti60's port
   5004), the collect page; `test_stream.py` checks every sample against a counter channel.
   62.5 MB/s first, then towards line rate.
4. **Data logger.** Long recordings at low rates: decimation (min/max/mean) in fabric, to a
   file on `/data` (SD: about 10-20 MB/s at best) or to the PC through the collect page;
   download from the GUI.
5. **Analog inputs.** The TLA2518 (8 ch, 12 bit, 1 MS/s total, SPI) and/or the external
   isolated ADC.

## Open questions

- Rates: is 8 × int16 at up to about 4 MS/s the target, or faster / wider samples?
- Data logger: how long, at what rate, stored on the board or on the PC?
- External ADC (from earlier): SCLK continuous or burst, the spare isolator channel, data
  lines and bits, framing.
