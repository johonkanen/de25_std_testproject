# linux/webapp/ — the DE25-Standard web GUI

A page served by the board itself (`http://192.168.1.223/`): a drawing of
the DE25-Standard with its LEDs, 7-segment displays, slide switches,
push-buttons and fan live (20 updates a second), the LED blinker picker,
the LED register, the HEX displays (digits, raw segments, blanking, and a
flip for reading the board from the other side), the fan speed,
closed-loop control of the die temperature (42 °C by default, with a live
10-minute plot), reloading the FPGA core while Linux keeps running, and
updates of the GUI itself over the network with automatic rollback.
Ported from the DE25-Nano's (`~/dev/de25_nano_testproject/linux/webapp`);
plan Phase C in
[docs/plan_upstream_hps_first_webgui.md](../../docs/plan_upstream_hps_first_webgui.md).

The LED blinkers are FPGA modules (`fpga/source/led_blinkers.vhd`,
`fpga/source/blinkers/`); the GUI only picks the mode (register 13) and
shows what the ten LEDs do (registers 14, 15, 20). The HEX displays are
`fpga/source/hex_display.vhd` (registers 21..26). `fpga/register_block.vhd`'s
header has the whole register map.

## Architecture

Three processes, all from the release in `current/`, started (in this
order) and restarted by the supervisor:

```
                    /dev/mem (LWH2F 0x2000_0000)
                              |
  fpga_access.py  ------------+   the only process mapping it; one lock;
     |  /run/de25web/fpga.sock    pause/resume; the fan lease; FPGA core
     |                            loads (/lib/firmware); --sim board
     |
     +-- temp_control.py   reads soc64hwmon (/sys/class/hwmon), PI on the
     |      |  /run/de25web/control.sock   hottest die sensor, writes the fan
     |      |                              target (register 9) through fpga.sock
     +------+-- fpga_web.py   HTTP :80 - registers via fpga.sock, the loop
                                via control.sock; never touches /dev/mem
```

Both sockets speak one JSON object per line each way (the protocols are in
the docstrings of `fpga_access.py` and `temp_control.py`); both have a
`--client` mode for the shell:

```sh
python3 /opt/de25web/current/fpga_access.py --client read 9          # fan KTACH target
python3 /opt/de25web/current/fpga_access.py --client status
python3 /opt/de25web/current/fpga_access.py --client pause 30        # hold register traffic
python3 /opt/de25web/current/fpga_access.py --client core            # running build id, installed core
python3 /opt/de25web/current/fpga_access.py --client reload          # load the installed core again (~2 s)
python3 /opt/de25web/current/temp_control.py --client state
python3 /opt/de25web/current/temp_control.py --client set setpoint=45 mode=auto
```

**Fail safe, not crash.** A client that cannot reach a socket reports it -
the page shows "FPGA access unavailable" or "temperature control not
running" - and retries; nothing crashes over a missing peer. All register
traffic is serialised in `fpga_access.py`, the one place a bitstream load
pauses it (`{"op": "pause"}` / `"resume"`, with a timeout so a forgotten
pause cannot hold the fan loop forever).

**Fabric guard.** With no FPGA core loaded (HPS-first boot, the card's and
the QSPI copy both failed) the LWH2F bridge stays in reset and an access
would hang the CPU. `fpga_access.py` reads the reset manager's BRGMODRST
(read only) and refuses register traffic ("fabric not configured") while
the LWH2F bit is set. After a load it also waits 0.5 s before the first
access: the fabric's own power-on reset holds the bridge for ~100 ms after
configuration, which BRGMODRST does not show, and a read in that window
hung the whole board (2026-10-19).

## FPGA core

`fpga_access.py` loads the FPGA core (HPS-first images): op `reload`
applies the device-tree overlay that makes the kernel's FPGA manager load
`/lib/firmware/de25_std.core.rbf` again (~2.1 s). During the load register
reads and writes answer "paused"; after it the board id, board variant
(`STD\0`) and build id are checked against `de25_std.core.json`, the LED
register, fan target, blinker mode, HEX registers and loopback are written
back, and fan leases are extended by the pause. `/usr/sbin/fpga-reload`
on the console goes through it when the GUI runs, and stops everything
under `/opt/de25web` around the load when it does not.

Op `install_core` (`POST /api/fpga`) checks a bundle (core +
`de25_std.core.json` from `linux/make_jic.sh`: size, SHA-256, board
`de25-std`, the same periphery hash as the installed core), keeps the old
core and loads it back if the new one fails, and writes a good one to the
SD card's FAT partition too. A bad bundle is refused (409) before
anything is touched. The RSU code (`/api/rsu`, a core per QSPI image) is
there but dormant until plan Phase F gives this board an RSU flash layout.

```bash
python3 linux/tools/deploy_fpga.py                  # build/images' core, to 192.168.1.223
python3 linux/tools/deploy_fpga.py --pack-only core.tar.gz   # a bundle for the GUI's "FPGA core" card
python3 linux/tools/deploy_fpga.py --reload
```

A core only fits the first stage in QSPI of a build with the same pins,
HPS and DDR: after a change there, program the new `.jic` first.

## Control loop

- **Controlled variable**: the hottest of the die sensors (`temp*_input` of
  `soc64hwmon`: SDM and three corners), sampled once a second (every read
  is an SDM mailbox call; the web server takes the temperatures from the
  controller rather than reading them a second time).
- **Setpoint** 42.0 °C (25..85), kept in `/opt/de25web/control.json` with the
  mode and gains, across releases and restarts.
- **Actuator**: the fan's target speed. The fan chip is a **MAX6650** that
  regulates the speed itself from its tachometer
  ([docs/de25_std_fan.md](../../docs/de25_std_fan.md)); register 9 holds
  its KTACH value, `KTACH = 119040 / rpm - 1` (`rpm_to_ktach()` /
  `ktach_to_rpm()` in `fpga_access.py`, the one conversion every process
  uses; a smaller KTACH is a faster fan). The loop works in rpm, clamped
  to **1500..6000**; register 10 has the measured speed.
- **Law**: positional PI, `e = T_max - setpoint` (too hot -> more fan),
  `u = Kp e + I`, conditional integration (the integrator stops when the
  output is at a limit and the error pushes further) and an integrator
  clamped to the output range: no windup. Entering auto is bumpless (the
  integrator starts from the target in the register).
- **Gains**: `Kp = 320 rpm/°C`, `Ki = 11 rpm/(°C·s)` (`Ti` ~ 30 s): the
  DE25-Nano's gains scaled to this fan's range, against a simulated plant
  that is still a first guess (below). To be re-fit from a step response on
  the board (plan C7); change them with `POST /api/control {"kp": .., "ki": ..}`.
- **Honest limits**: a fan only cools. At 1500 rpm with the die still below
  the setpoint (a cool room - on the first board the die sat at 37-40 °C
  there) the loop is **saturated low** and says so; at 6000 rpm and still
  above it, **saturated high**. "Settled" means every 5-sample average of
  the last 30 s within ±0.3 °C. Routine changes between regulating and
  saturated are logged at most every 30 s (the target rounds to whole
  KTACH steps, so at the floor the state flickers).
- **Modes**: `auto` (PI), `manual` (fixed speed, at least 1500 rpm), `off`
  (the loop leaves the fan alone). The GUI's fan slider in auto or manual
  puts the loop in manual at that speed; with the loop off it writes
  register 9 directly.

**When something dies:**

| what | the fan |
|------|---------|
| `temp_control.py` killed / crashed | keeps its target (the FPGA holds register 9); a crash with a Python exception raises it to 4000 rpm first; the supervisor restarts the loop within ~1 s, bumpless |
| `temp_control.py` hung (alive, silent) | each fan write carries a 10 s **lease**: `fpga_access.py` raises the fan to 4000 rpm (never lowers it) when it runs out |
| `fpga_access.py` killed | keeps its target; the loop and the page report "FPGA access unavailable"; restarted within ~1 s |
| no die temperature for 5 samples | the loop puts the fan at >= 4000 rpm and says why |
| the FPGA core reloads | the fabric comes back at 1500 rpm; `fpga_access.py` writes the target back ~0.5 s later |

Unlike the DE25-Nano's AMC6821, the MAX6650 has **no thermal fail-safe** of
its own: the lease is the only net when the loop dies.

## Files

| file | what |
|------|------|
| `fpga_web.py` | the HTTP server (stdlib only): the API, release handling; registers through `fpga_access.py`, the loop through `temp_control.py` |
| `fpga_access.py` | the register process: `/dev/mem`, `fpga.sock`, pause, fan lease, fabric guard, core loads; `--sim` simulates the register file and the board's heat |
| `temp_control.py` | the temperature loop: hwmon, PI, `control.sock`, `control.json` |
| `static/` | `index.html`, `app.js`, `style.css`, `board.svg` (the DE25-Standard, after the user manual's board photo) |
| `VERSION` | the GUI's version; releases add the git state (`1.0.0+a1b5e2b`) |
| `BOARD` | `de25-std`: the board a release is for. `/api/update` refuses a release for another board (a DE25-Nano release has no `BOARD`), and `deploy_web.py` checks the board before it uploads |
| `../board/de25web-supervisor.sh` | runs the three processes on the board and reverts a bad release - installed once, never part of a release |
| `../tools/install_webapp.py` | one-time install on a running board, over the serial console |
| `../tools/deploy_web.py` | an update over HTTP: pack, upload, wait, check, confirm |
| `../tools/deploy_fpga.py` | a new FPGA core over HTTP: bundle (core + manifest), board and periphery check, upload, check the build id |
| `../tools/supervisor_test.py` | the release cases (good, two updates, no confirmation, crash, restart during the test, rollback onto a broken one, wrong board) against the real supervisor under busybox `sh` with `--sim` |
| `../tools/gui_test.py` | drives the page in headless Chromium: every blinker, an LED click, the HEX card, the loop, the fan slider, `--reload-core`, screenshots |

## Install (once)

Needs the Alpine rootfs ([../README.md](../README.md)) and an FPGA core with
the register file v2 (build id, blinkers, HEX). Either:

- **a new SD card**: `./build.sh sdcard` installs the GUI too
  (`alpine_rootfs_config.sh`); the first boot with network runs
  `apk add python3`. The update token is `~/.de25web_token_std` when that
  exists (a re-imaged card still takes `deploy_web.py`), else a new one in
  `build/images/de25web_token` - copy it to `~/.de25web_token_std`.
- **a running board**: `python3 linux/tools/install_webapp.py` (serial
  console, found by id: `usb-TERASIC_DE25-Standard_*-if01-port0`; board
  online). It installs python3, the first release and the supervisor,
  writes a token (kept on re-runs, copied to `~/.de25web_token_std`), adds
  the supervisor to `/etc/inittab` and starts it.

## Update

```bash
python3 linux/tools/deploy_web.py            # pack linux/webapp, upload, check, confirm
```

or the page's **GUI release** panel: pick a `.tar.gz` made with
`deploy_web.py --pack-only out.tar.gz`, enter the token, **Upload**.

What happens on the board (`/opt/de25web`):

```
releases/<version>-<sha8>/   each release (the newest 4 are kept)
current  -> releases/...     what runs
previous -> releases/...     the rollback target
pending                      the release on test
token                        required in X-Token for uploads and rollbacks
control.json                 the temperature loop's settings
supervisor.log, server.log, access.log, control.log
```

Sockets and pid files are in `/run/de25web/`.

1. `POST /api/update` checks the SHA-256 and the token, unpacks into
   `releases/`, points `current` at it (`previous` at the old one), writes
   `pending`, and exits.
2. The supervisor stops the three processes and starts the new release's,
   on test for 120 s.
3. The release is kept once it is confirmed (`POST /api/update/confirm`):
   the page confirms by itself when it loads and reads the board;
   `deploy_web.py` confirms after checking the version and the board id.
   The server refuses to confirm (503) unless `fpga_access.py` and
   `temp_control.py` answer.
4. Otherwise the supervisor reverts to `previous` when the 120 s pass, when
   the release's processes exit 3 times (together), or when the board
   restarts during the test.

An upload while another release is still on test leaves `previous` at the
last confirmed release, so a failed test never lands on a release nobody
confirmed.

**Roll back** puts the previous release on test the same way, so rolling
back onto a broken release reverts too.

`python3 linux/tools/supervisor_test.py` runs these cases against the real
supervisor on the host (busybox `sh`, `--sim`, a layout in `/tmp/d25s`).

## API

| | |
|---|---|
| `GET /api/board` | every register, decoded (LED levels, HEX digits and segments, flip, switches, keys, CPU_RESET, fan target and measured rpm, blinker mode and module id, `build_id`, board variant), plus `soc`: the SoC's temperatures (°C) and supply voltages (V) from the kernel's `soc64-hwmon`, and `control`: the loop's latest sample. With `fpga_access.py` down: `{"error": "FPGA access unavailable ...", "fpga_unavailable": true, soc, control}` |
| `GET /api/control` | the loop: `state` (mode, setpoint, measured, hottest, target and measured rpm, p, i, error, saturated `"low"`/`"high"`/null, settled, status text, gains, rpm limits) and `history`: one sample a second for 10 min |
| `POST /api/control` | any of `{"mode": "auto"\|"manual"\|"off", "setpoint": 42.0, "manual_rpm": 3000, "kp": 320, "ki": 11}` |
| `GET /api/events` | `/api/board` as server-sent events, 20 a second |
| `POST /api/blinker` | `{"mode": "scanner"}` or `0..5` (software, off, counter, scanner, breathing, sparkle) |
| `POST /api/leds` | `{"value": 85}` - LED register 5, LEDR[8:0] (blinker mode software; LEDR9 is the heartbeat) |
| `POST /api/hex` | `{"value": 0x123456}` digits, or `{"raw": [6 bytes, HEX0 first]}` (segments g..a, 1 = lit); and/or `{"blank": 0..63}` (bit n: HEXn); and/or `{"flip": true}` (readable from the other side of the board) |
| `POST /api/fan` | `{"rpm": 1500..6000}` - loop in auto/manual: it becomes manual at this speed; loop off: register 9 directly |
| `GET /api/read?reg=N`, `POST /api/write` | raw register access |
| `GET /api/version` | release running, previous, on test, `board` |
| `POST /api/update` | body: release `.tar.gz`; headers `X-Sha256`, `X-Token`; 400 unless its `BOARD` is `de25-std` |
| `POST /api/update/confirm`, `/api/update/rollback` | |
| `GET /api/fpga` | the FPGA core: `running_build_id` (register 19), `installed` and `previous` manifests, `last_load` |
| `POST /api/fpga` | body: core bundle `.tar.gz`; headers `X-Sha256`, `X-Token`, `X-Force: 1` (no installed manifest). 200 loaded, 409 refused before anything was touched, 500 failed to load (`rolled_back` says whether the previous core is back) |
| `POST /api/fpga/reload` | load the installed core again (`X-Token`) |
| `GET /api/rsu`, `POST /api/rsu` | dormant until plan Phase F |

```bash
curl -X POST -d '{"mode":"breathing"}' http://192.168.1.223/api/blinker
curl -X POST -d '{"value":1194684}' http://192.168.1.223/api/hex     # 123AbC
```

## Develop without the board

```bash
export DE25WEB_RUN=/tmp/de25web-sim                  # the sockets (also the --sim default)
python3 linux/webapp/fpga_access.py --sim &          # registers + the simulated heat
python3 linux/webapp/temp_control.py --sim &         # the loop
python3 linux/webapp/fpga_web.py --sim --port 8000   # http://127.0.0.1:8000/
python3 linux/tools/gui_test.py http://127.0.0.1:8000/ --shots /tmp/shots
```

`--sim` models the register file, including the blinker patterns and the
HEX displays, a fan whose speed follows the KTACH target (1.5 s lag), and
the die's heat:

    T_ss = ambient + load / (0.01975 + 0.000781 sqrt(rpm)),   tau 30 s

a first guess (25 °C ambient: ~45 °C at 1500 rpm, ~42 °C at ~2500 rpm,
~37.5 °C at 6000 rpm) until plan C7 re-fits it; the load wanders ±3 % with
a 5 min period and each sensor has 0.08 °C of noise. The plant is written
as a fake `soc64hwmon` under `$DE25WEB_RUN/sim-hwmon/`, so the loop reads it
exactly as it reads `/sys/class/hwmon`. Change it while running:
`fpga_access.py --sim --client sim ambient=10` (saturates the loop low),
`ambient=40` (high), `load=1.2`, `temp=45`.

Updates are off in a plain run (not under `/opt/de25web`); to try them, lay
out a `releases/` directory and run the supervisor with `DE25WEB_BASE`,
`DE25WEB_PORT`, `DE25WEB_RUN`, `DE25WEB_TEST_SECONDS` and `DE25WEB_ARGS=--sim`
(`--sim` goes to all three processes). Unix socket paths are limited to 107
bytes: keep `DE25WEB_RUN` short.

## Notes

- Register access needs root (`/dev/mem`); init runs the supervisor as root.
- The web server samples the registers once (20 Hz) for all its clients.
- The CPU_RESET_n button (PB9) resets only the fabric's user registers
  (LEDs, blinkers, HEX), not the LWH2F bridge, so pressing it while Linux
  runs should be safe (to be confirmed on the board, plan C7); the page
  shows it pressed.
- The token guards uploads, rollbacks and core loads only; the rest of the
  page is open to the LAN, like the board's console.
