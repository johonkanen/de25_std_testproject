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

## Phase 3: done (2026-11-01), on the board

- **The stream server is in `fpga_access.py`** (the process that maps `/dev/mem` anyway),
  a WebSocket on port 5004: `GET /stream?divider=D&sources=...`.
  - It arms the scope in continuous deep capture (mode 3, no trigger) over F2SDRAM.
  - It sends the ring's records in order, as binary messages of up to 1 MB.
  - Register 22 (records answered by the bus) is read before and after each message.
  - A client the ring laps, or records the writer could not take, end the stream with a
    1011 close frame that says which (as the Ti60's overrun reset did, but with a reason).
- **Three things found on the board** set the rate:
  1. The kernel's copy from the uncached mapping (`sendall` straight from the mmap) manages
     **18 MB/s**: it reads 8 bytes at a time. Each message is now copied into a cached
     buffer in user space first (memcpy: 460 MB/s), then sent.
  2. The HPS has two Cortex-A55 and two A76 cores, and the A55s copy from uncached memory
     at **41 MB/s** against the A76s' 460. A sender that the scheduler moved to an A55 fell
     behind until the ring lapped it. The sending thread is now pinned to the A76s (from
     `/proc/cpuinfo`: `cpu_capacity` reads the same for all four).
  3. The PC-side checker (`test_stream.py`) had to parse frames in place to keep up.
- **Results** (`linux/tools/test_stream.py`, every sample's counter checked):

  | rate | produced | received | run | errors | furthest behind |
  |---|---|---|---|---|---|
  | 1 MS/s | 16 MB/s | 15.0 MB/s | 8 s | 0 | - |
  | 3.85 MS/s | 61.5 MB/s | 58.7 MB/s | 20 s | 0 | 20 K records |
  | 5 MS/s | 80 MB/s | 76.4 MB/s | 2 x 20 s | 0 | 22 K |
  | 6.25 MS/s | 100 MB/s | 95.7 MB/s | 20 s | 0 | 273 K |
  | **7.14 MS/s** | **114 MB/s** | 108.6 MB/s | 20 s | 0 | 23 K |
  | **7.14 MS/s** | **114 MB/s** | 109.0 MB/s | **120 s, 818 M samples** | **0** | 77 K |

  "Received" counts from the connect, so it reads a few % low; the board's own figure for
  the 120 s run is 114.28 MB/s. The ring holds 8.4 M records (1.2 s at 7.14 MS/s), so even
  the furthest behind was under a tenth of it. 8.33 MS/s (133 MB/s) is beyond gigabit
  Ethernet and overruns in about 3 s. The board's CPU stays mostly idle.
- **The GUI**: a Stream card after the scope card. It streams the scope card's channels and
  generator at 0.01-10 MS/s. `static/stream_worker.js` (after the Ti60's
  `collect_worker.js`) reads the WebSocket and reduces it to per-millisecond min/max. The
  card draws bands over a 2, 10 or 60 s window. Record keeps the raw messages in the tab (up
  to 1 GB) for a download (`.i16`: int16 little-endian, 8 channels interleaved).
  `gui_test.py` streams at 1 MS/s with recording on, checks that the scope is refused
  meanwhile, and checks every recorded sample's counter (2.25 M samples, 0 breaks).
- **Fixed on the way**: `fpga_web.py` left a POST's unread body (`/api/scope/stop`'s `{}`)
  on the kept-alive connection, where it became the start of the next request. The stream
  card's worker script failed to load about one time in two. Every POST's body is now taken
  off the connection.

## Phase 4: done (2026-11-01), on the board

Decided: logs go to the board's SD card and are downloaded from the GUI. A point holds each
channel's minimum, maximum and mean. The target is 1-10 k points/s for hours.

- **`fpga/scope_decimator.vhd`** sits between the scope's deep capture port and the DDR
  writer (registers 304..308). Enabled, it turns every n samples (64 .. 2^26) into a point of
  four records, 64 bytes:
  - **Record 4p:** each channel's minimum.
  - **Record 4p+1:** each channel's maximum.
  - **Record 4p+2:** each channel's mean, exact: eight restoring dividers, 43 steps, rounded
    to nearest with halves away from zero.
  - **Record 4p+3:** the point's number, the points lost before it, and n.
  - Digital channels (bit lanes) get AND, OR and the last sample.
  - A point the writer has no room for is lost whole and counted. Its number says where.
  - Disabled, records pass straight through, so the stream is unchanged.
- **The DDR writer** now sends beats that have waited 21 ms (`g_flush_clocks`) as a shorter
  burst. Before, records waited for a full 16-beat burst (512 bytes), and a continuous capture
  never flushes. A slow log's last ~10 points sat in the FIFO and were lost on Stop. At 0.5
  points/s the first one took 20 s to appear. A point is two whole beats, so whole points
  always go out; this is why it has a 4th record.
- **The logger** is a thread in `fpga_access.py` and runs with no page open:
  - **Rate:** 0.1 to 100 000 points/s. The scope's input stays at 50 MS/s while n fits.
  - **Output:** `/data/logs/<name>.i16`, fsynced every second, plus `<name>.json` (its
    settings and layout).
  - **Ends** on Stop, the set duration, or less than 64 MB left on the card.
  - **After a restart:** a log cut short is marked `interrupted` and trimmed to whole points.
  - **Exclusive:** the triggered scope, the stream and a log exclude each other.
  - **Ring start:** a decimated ring is read from record 0. The scope reports its "first"
    sample as record 1 (one sample goes in before it); for samples that is right, but for
    points it shifted every point by a record. The simulator's ring starts at 0, so only the
    board showed it.
- **GUI:** a Data logger card with rate, duration, label, the free space and how long it
  lasts, and a table of logs with CSV, raw and JSON downloads and Delete. In the CSV, the
  time comes from the point's number, so a lost point leaves a gap.
- **`/data` fills the card:**
  - `linux/board/grow-data.py` runs once at boot, after `/data` is mounted.
  - It grows p6 and the extended partition to the card's end. Only the size fields in the
    MBR and the EBR change.
  - It then calls BLKPG_RESIZE_PARTITION and an online `resize2fs`.
  - On the board's 32 GB card, `/data` went from 487 MB to 26.8 GB, in under a second.
  - At 64 bytes a point: 11 h at 10 k points/s, 113 h at 1 k points/s.
- **Results** (`linux/tools/test_logger.py`, channel 0 on the generator's counter):
  - **Check:** every point's minimum, maximum and mean against the counter's exact sequence,
    plus continuity from point to point and the point numbers.
  - **Results:**

  | rate | n | run | points | lost | errors |
  |---|---|---|---|---|---|
  | 1 points/s | 50 M | 12 s | 11 | 0 | 0 |
  | 1 k points/s | 50 000 | 30 s | 29 464 | 0 | 0 |
  | 10 k points/s | 5 000 | 30 s | 293 840 | 0 | 0 |
  | 100 k points/s | 500 | 30 s | 2 631 664 | 0 | 0 |
  | 10 k points/s | 5 000 | **10 min** | **5 994 784** | 0 | 0 |

  - **Downloads:** the .i16 at about 110 MB/s (384 MB in 3.4 s). The CSV is made on the
    board as it goes out, about 46 k rows/s (7 MB/s): about 2 min for that 10-minute log.
- **Not covered:** the logger records the test generator. Real inputs come with phase 5.

## Phase 5, part 1: the TLA2518, on the board (2026-11-01)

- **`fpga/tla2518_reader.vhd`** (registers 320..333) reads the board's TLA2518 continuously.
  The TLA2518 has 8 channels, 12 bits and runs up to 1 MS/s; it sits on the 2×5 header J18,
  on pins CH4, CK4, BF32 and BP22.
  - **Start-up, on its own after reset:** it waits for power-up, resets the ADC, turns on the
    4-bit channel ID, calibrates the offset, writes the channel mask and starts auto-sequence.
  - **Then:** one 16-bit frame per conversion, SPI-00 at 25 MHz, with CS high for 640 ns
    (tCONV is 600 ns).
  - **Rate:** 67 clocks a conversion, so **746 k conversions/s**, 93 k a channel with all eight.
  - **SDO capture:** SDO is taken a whole SCLK period after the edge that launched it, through
    an I/O input register; SCLK, CS and SDI leave from output registers. That leaves 40 ns for
    the round trip; the ADC itself takes up to 16 ns.
  - **Checking:** each frame's channel ID must be the next one in the mask; any other frame is
    counted.
  - **Link test:** with FIX_PAT on, every frame is **0xA5A5**: the pattern only, with no
    channel ID. The datasheet says "0xA5A"; the board showed the rest. In that mode the reader
    takes the channels in sequence order and counts any frame that isn't 0xA5A5.
  - **Raw access:** a register reads and writes the ADC's own registers while the reader is
    stopped.
- **Scope sources:**
  - AIN0..AIN7 are sources 16..23 (unsigned, 0..4095), each the input's last result.
  - Source 24, "ADC strobes", toggles lane 0 at each conversion and lane 1 at each scan.
  - The scope, the stream and the logger take them like any other source.
- **Software:**
  - `GET/POST /api/adc` and `/api/adc/register` (ops `adc`, `adc_set`, `adc_register` in
    `fpga_access.py`); the simulator has the ADC too.
  - The GUI's ADC card shows each input's level, volts and code, plus Run/Stop, the link
    test, the channel checkboxes, the measured rate and the error count.
  - `gui_test.py` runs the link test through the registers and through a scope capture of
    AIN0..7.
- **Results on the board:**
  - **Rate:** 746 480 conversions/s measured, 746 269 calculated.
  - **Link test:** 44.8 M frames in 60 s, all 0xA5A5, 0 errors.
  - **Normal mode:** 22.4 M + 29.5 M conversions, 0 channel-ID errors.
  - **Scope capture:** of AIN0..7 under the link test, 1024 samples × 8, all 0xA5A.
- **Not yet:**
  - **No known voltage measured yet:** with nothing on J18 every input reads about 2.2 V, which
    is open-input pickup.
  - **Full scale** is taken as 3.3 V: AVDD is the board's 3.3 V through a ferrite (the 5 V
    option is not fitted), though the user manual says 3.4 V.
  - **Sampling:** the scope samples the held values at its own rate, not in step with the
    conversions.

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
- External ADC (from earlier): SCLK continuous or burst, the spare isolator channel, data
  lines and bits, framing.
