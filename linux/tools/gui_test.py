#!/usr/bin/env python3
"""gui_test.py [url] [--shots DIR] - drive the DE25-Standard web GUI in a real
(headless) Chromium over the DevTools protocol (ported from the DE25-Nano's):
open the page, click each blinker mode and check the page (and the register
file behind it) follow, take a capture with the oscilloscope card (a sine
triggered at t = 0, the counter, the switches as bit lanes), toggle an LED in software mode, set the 7-segment
displays from the card and by clicking a segment, flip them, check the
temperature control plot renders and its mode buttons, setpoint and the fan
slider (rpm) reach the controller (the loop's and the displays' settings
are put back afterwards), check the FPGA core card shows the running build,
then screenshot the page at desktop and phone widths. --reload-core also
clicks the card's Reload (the board pauses ~2 s; the token from
~/.de25web_token_std) and checks the blinker mode and the displays survive
it. --bundle PATH (repeatable) also installs a RAUC bundle through the
Update card, as a person would (the file picked into the input, the token
typed): first with a wrong token (refused), then with the right one, and
follows it - a GUI release: the page reloads into it and confirms it, and
`rauc install` ends with exit 0; a core: "Installed." and the build runs;
an image: "the board reboots", the page comes back by itself on the other
application image, and its image card shows it confirmed.
Exit status 1 when the page does not show what was expected.

Works against the board or a local `fpga_web.py --sim`:
    python3 linux/webapp/fpga_web.py --sim --port 8000 &
    python3 linux/tools/gui_test.py http://127.0.0.1:8000/ --shots /tmp/shots

Chromium: Playwright's headless shell in ~/.cache/ms-playwright (or CHROME).
The DevTools client is ~/dev/pr_testing/tools/gui_test.py's.
"""
import base64
import glob
import json
import os
import socket
import struct
import subprocess
import sys
import time
import urllib.request

ARGV = sys.argv[1:]
SHOTS = None
if "--shots" in ARGV:
    i = ARGV.index("--shots")
    SHOTS = ARGV[i + 1]
    del ARGV[i:i + 2]
RELOAD_CORE = "--reload-core" in ARGV
if RELOAD_CORE:
    ARGV.remove("--reload-core")
BUNDLES = []
while "--bundle" in ARGV:
    i = ARGV.index("--bundle")
    BUNDLES.append(os.path.abspath(ARGV[i + 1]))
    del ARGV[i:i + 2]
URL = ARGV[0] if ARGV else "http://192.168.1.223/"
LEDS = 10
PORT = 9224
MODES = ["off", "counter", "scanner", "breathing", "sparkle", "software"]


def chrome():
    if os.environ.get("CHROME"):
        return os.environ["CHROME"]
    found = glob.glob(os.path.expanduser(
        "~/.cache/ms-playwright/chromium_headless_shell-*/*/chrome-headless-shell"))
    if not found:
        sys.exit("no headless Chromium: set CHROME")
    return sorted(found)[-1]


class WebSocket:
    """just enough of a WebSocket client for the DevTools protocol"""

    def __init__(self, url):
        host, path = url[len("ws://"):].split("/", 1)
        h, p = host.split(":")
        self.s = socket.create_connection((h, int(p)), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall((f"GET /{path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n"
                        f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
                        "Sec-WebSocket-Version: 13\r\n\r\n").encode())
        self.buf = b""
        while b"\r\n\r\n" not in self.buf:
            self.buf += self.s.recv(4096)
        self.buf = self.buf.split(b"\r\n\r\n", 1)[1]

    def send(self, text):
        data, mask = text.encode(), os.urandom(4)
        n = len(data)
        head = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else
                                bytes([0x80 | 126]) + struct.pack(">H", n) if n < 65536 else
                                bytes([0x80 | 127]) + struct.pack(">Q", n))
        self.s.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def _need(self, n):
        while len(self.buf) < n:
            self.buf += self.s.recv(65536)

    def recv(self):
        self._need(2)
        n, off = self.buf[1] & 0x7F, 2
        if n == 126:
            self._need(4)
            n, off = struct.unpack(">H", self.buf[2:4])[0], 4
        elif n == 127:
            self._need(10)
            n, off = struct.unpack(">Q", self.buf[2:10])[0], 10
        self._need(off + n)
        data, self.buf = self.buf[off:off + n], self.buf[off + n:]
        return json.loads(data)


class Page:
    def __init__(self, ws):
        self.ws, self.next_id = ws, 0

    def call(self, method, **params):
        self.next_id += 1
        self.ws.send(json.dumps({"id": self.next_id, "method": method, "params": params}))
        while True:
            msg = self.ws.recv()
            if msg.get("id") == self.next_id:
                return msg.get("result", {})

    def js(self, expr):
        r = self.call("Runtime.evaluate", expression=expr, returnByValue=True, awaitPromise=True)
        return r.get("result", {}).get("value")


def api(path, body=None):
    req = urllib.request.Request(URL.rstrip("/") + path,
                                 data=None if body is None else json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=5))


def api_or_none(path):
    """api(), or None while the board reboots"""
    try:
        return api(path)
    except (OSError, ValueError):
        return None


def check(ok, text):
    global failures
    failures += not ok
    print(f"{'PASS' if ok else 'FAIL'}  {text}")
    return ok


def wait_for(fn, timeout=4.0):
    t0 = time.time()
    while True:
        v = fn()
        if v or time.time() - t0 > timeout:
            return v
        time.sleep(0.3)


def scope_tests(page):
    """the oscilloscope card (a core with the scope, or the simulated
    board's): a single capture of the test generator, its strips, a rising
    trigger on the sine at t = 0, the crosshair's readout, Run and Stop"""
    info = api("/api/scope")
    if not info or not info.get("ok"):
        print(f"SKIP  oscilloscope: none in this core ({(info or {}).get('error')})")
        return
    if not check(wait_for(lambda: page.js('!document.getElementById("scope-card").hidden')),
                 f"scope card shown: {len(info['sources'])} sources, depth {info['depth']}"):
        return
    names = [s["name"] for s in info["sources"]]
    # sine on CH1 (the trigger), the counter on CH2, the switches (bits) on CH3, the rest off
    setup = {0: "sine", 1: "counter", 2: "switches"}
    for c in range(8):
        v = names.index(setup[c]) if c in setup else -1
        page.js(f'(e => {{ e.value = "{v}"; e.dispatchEvent(new Event("change", {{bubbles: true}})); }})'
                f'(document.getElementById("scope-src{c}"))')
    page.js("""(() => { const set = (id, v) => { const e = document.getElementById(id); e.value = v;
        e.dispatchEvent(new Event("change", {bubbles: true})); };
        set("scope-rate", "49"); set("scope-length", "1024"); set("scope-pre", "50");
        set("scope-mode", "normal"); set("scope-tch", "0"); set("scope-edge", "rising");
        set("scope-level", "0"); set("scope-gen", "20000"); })()""")
    page.js('document.getElementById("scope-single").click()')
    status = wait_for(lambda: (lambda t: t if t in ("triggered", "forced") else None)(
        page.js('document.getElementById("scope-status").textContent')), timeout=6)
    check(status == "triggered", f"Single: status {status!r}")
    cap = page.js("""(() => { const c = scope.cap; if (!c) return null;
        const on = c.chans.filter(x => x.on);
        const sine = c.chans[0].v, cnt = c.chans[1].v;
        let steps = 0; for (let i = 1; i < cnt.length; i++) steps += ((cnt[i] - cnt[i-1]) & 0xffff) === 1;
        return {n: c.n, pre: c.pre, shown: on.length, lanes: c.chans[2].lanes,
                before: sine[c.pre - 1], at: sine[c.pre], steps,
                h: document.getElementById("scope-canvas").getBoundingClientRect().height}; })()""")
    check(cap and cap["n"] == 1024 and cap["shown"] == 3 and cap["h"] > 150,
          f"capture drawn: {cap and cap['n']} samples, {cap and cap['shown']} strips, "
          f"canvas {cap and round(cap['h'])} px high")
    check(cap and cap["before"] < 0 <= cap["at"],
          f"rising trigger on the sine at t = 0: {cap and cap['before']} -> {cap and cap['at']}")
    check(cap and cap["steps"] == cap["n"] - 1,
          f"counter steps by one: {cap and cap['steps']} of {cap and cap['n'] - 1}")
    check(cap and cap["lanes"] >= 1, f"switches drawn as {cap and cap['lanes']} bit lanes")
    # the crosshair: one readout row per strip shown
    rows = page.js("""(() => { const c = document.getElementById("scope-canvas"), r = c.getBoundingClientRect();
        c.dispatchEvent(new PointerEvent("pointermove", {clientX: r.left + r.width * 0.6,
                                                         clientY: r.top + 30, bubbles: true}));
        const tip = document.getElementById("scope-tip");
        return tip.hidden ? 0 : tip.querySelectorAll(".row").length; })()""")
    check(rows == 3, f"crosshair readout: {rows} rows")
    if SHOTS:
        page.call("Emulation.setDeviceMetricsOverride", width=1280, height=900, deviceScaleFactor=1, mobile=False)
        page.js('document.getElementById("scope-card").scrollIntoView()')
        time.sleep(0.5)
        r = page.js('(r => ({x: r.x, y: r.y + scrollY, w: r.width, h: r.height}))'
                    '(document.getElementById("scope-card").getBoundingClientRect())')
        data = page.call("Page.captureScreenshot", format="png", captureBeyondViewport=True,
                         clip={"x": r["x"], "y": r["y"], "width": r["w"], "height": r["h"], "scale": 1})["data"]
        os.makedirs(SHOTS, exist_ok=True)
        with open(os.path.join(SHOTS, "scope.png"), "wb") as f:
            f.write(base64.b64decode(data))
        print(f"screenshot {os.path.join(SHOTS, 'scope.png')}")
    # Run: captures keep coming; Stop: they stop
    before = page.js("scope.cap.captures")
    page.js('document.getElementById("scope-run").click()')
    more = wait_for(lambda: page.js("scope.cap.captures") != before, timeout=6)
    page.js('document.getElementById("scope-stop").click()')
    time.sleep(0.5)
    stopped = page.js('document.getElementById("scope-status").textContent')
    check(more and stopped == "stopped", f"Run: new captures {bool(more)}; Stop: status {stopped!r}")


def stream_tests(page):
    """the stream card (after scope_tests' channel setup: sine, counter,
    switches): a recorded stream at 1 MS/s, its bands drawn, the scope
    refused meanwhile, Stop; every recorded sample's counter steps by one"""
    info = api("/api/scope")
    if not info or not info.get("ok") or not info.get("stream"):
        print("SKIP  stream: no stream server")
        return
    if not check(wait_for(lambda: page.js('!document.getElementById("stream-card").hidden')),
                 f"stream card shown: port {info['stream']['port']}"):
        return
    page.js("""(() => { const set = (id, v) => { const e = document.getElementById(id); e.value = v;
        e.dispatchEvent(new Event("change", {bubbles: true})); };
        set("stream-rate", "49"); set("stream-window", "2");
        document.getElementById("stream-record").checked = true; })()""")
    page.js('document.getElementById("stream-start").click()')
    status = wait_for(lambda: (lambda t: t if t == "streaming" else None)(
        page.js('document.getElementById("stream-status").textContent')), timeout=6)
    if not check(status == "streaming", f"Start: status {status!r}"):
        print("      " + str(page.js('document.getElementById("stream-msg").textContent')))
    got = wait_for(lambda: page.js("stream.count >= 1500 ? stream.count : null"), timeout=10)
    check(got, f"points arriving: {got} ms of points")
    refused = None
    try:
        refused = api("/api/scope/capture", {"settings": {}})
    except urllib.error.HTTPError as e:        # the refusal is the answer
        refused = json.load(e)
    check(refused and "stream" in str(refused.get("error", "")),
          f"scope refused while streaming: {refused and refused.get('error')}")
    drawn = page.js("""(() => { const c = document.getElementById("stream-canvas");
        return {h: c.getBoundingClientRect().height, strips: stream.settings.chans.filter(x => x.on).length}; })()""")
    check(drawn["strips"] == 3 and drawn["h"] > 150, f"stream drawn: {drawn['strips']} strips, "
          f"canvas {round(drawn['h'])} px high")
    if SHOTS:
        page.call("Emulation.setDeviceMetricsOverride", width=1280, height=900, deviceScaleFactor=1, mobile=False)
        page.js('document.getElementById("stream-card").scrollIntoView()')
        time.sleep(0.5)
        r = page.js('(r => ({x: r.x, y: r.y + scrollY, w: r.width, h: r.height}))'
                    '(document.getElementById("stream-card").getBoundingClientRect())')
        data = page.call("Page.captureScreenshot", format="png", captureBeyondViewport=True,
                         clip={"x": r["x"], "y": r["y"], "width": r["w"], "height": r["h"], "scale": 1})["data"]
        os.makedirs(SHOTS, exist_ok=True)
        with open(os.path.join(SHOTS, "stream.png"), "wb") as f:
            f.write(base64.b64decode(data))
        print(f"screenshot {os.path.join(SHOTS, 'stream.png')}")
    page.js('document.getElementById("stream-stop").click()')
    stopped = wait_for(lambda: (lambda t: t if t != "streaming" else None)(
        page.js('document.getElementById("stream-status").textContent')), timeout=6)
    check(stopped == "stopped", f"Stop: status {stopped!r}")
    rec = page.js("""(() => { let n = 0, bad = 0, prev = null;
        for (const b of stream.raw) { const v = new Uint16Array(b);
            for (let i = 1; i < v.length; i += 8) {
                if (prev !== null && ((v[i] - prev) & 0xffff) !== 1) bad++;
                prev = v[i]; n++; } }
        return {n, bad, save: !document.getElementById("stream-save").disabled}; })()""")
    check(rec["n"] > 100000 and rec["bad"] == 0 and rec["save"],
          f"recording: {rec['n']} samples, counter breaks {rec['bad']}, download offered {rec['save']}")
    check(api("/api/scope").get("stream", {}).get("active") is False, "the board: no stream left running")


def logger_tests(page):
    """the data logger card: a labelled log at 100 points/s, the stream
    refused meanwhile, Stop; its row, the CSV's rows match its points, Delete"""
    try:
        r = api("/api/logs")
    except (OSError, ValueError) as e:
        print(f"SKIP  data logger: {e}")
        return
    if not check(wait_for(lambda: page.js('!document.getElementById("log-card").hidden')),
                 f"logger card shown: {len(r['logs'])} logs, {r['status']['free_bytes'] >> 20} MB free"):
        return
    label = f"gui-test-{int(time.time()) % 100000}"
    page.js(f"""(() => {{ const set = (id, v) => {{ const e = document.getElementById(id); e.value = v;
        e.dispatchEvent(new Event("change", {{bubbles: true}})); }};
        set("log-rate", "100"); set("log-duration", ""); set("log-label", "{label}"); }})()""")
    page.js('document.getElementById("log-start").click()')
    status = wait_for(lambda: (lambda t: t if t == "logging" else None)(
        page.js('document.getElementById("log-status").textContent')), timeout=8)
    if not check(status == "logging", f"Start: status {status!r}"):
        print("      " + str(page.js('document.getElementById("log-msg").textContent')))
        return
    # the stream waits while a log runs
    page.js('document.getElementById("stream-start").click()')
    ended = wait_for(lambda: (lambda t: t if t in ("ended", "stopped") else None)(
        page.js('document.getElementById("stream-status").textContent')), timeout=8)
    msg = page.js('document.getElementById("stream-msg").textContent')
    check(ended == "ended" and "log" in (msg or ""), f"stream refused while logging: {ended!r}, {msg!r}")
    time.sleep(3)
    page.js('document.getElementById("log-stop").click()')
    idle = wait_for(lambda: (lambda t: t if t == "idle" else None)(
        page.js('document.getElementById("log-status").textContent')), timeout=15)
    check(idle == "idle", f"Stop: status {idle!r}")
    logs = [l for l in api("/api/logs")["logs"] if l.get("label") == label]
    log = logs[0] if logs else None
    check(log and log["state"] == "done" and log["points"] >= 100,
          f"the log: {log and log['name']}, {log and log['points']} points, state {log and log['state']}")
    if not log:
        return
    row = wait_for(lambda: page.js(f'!!document.querySelector(\'#log-rows tr[data-name="{log["name"]}"]\')'), timeout=5)
    check(row, "its row in the table")
    csv = page.js(f"""fetch("/api/logs/{log['name']}.csv").then(r => r.text()).then(t => {{
        const lines = t.trim().split("\\n"); return {{rows: lines.length - 1, cols: lines[0].split(",").length}}; }})""")
    check(csv and csv["rows"] == log["points"] and csv["cols"] == 25,
          f"CSV: {csv and csv['rows']} rows of {csv and csv['cols']} columns for {log['points']} points")
    page.js(f'window.confirm = () => true; document.querySelector(\'#log-rows button[data-delete="{log["name"]}"]\').click()')
    gone = wait_for(lambda: page.js(f'!document.querySelector(\'#log-rows tr[data-name="{log["name"]}"]\')') or None,
                    timeout=6)
    check(gone and not [l for l in api("/api/logs")["logs"] if l["name"] == log["name"]], "Delete: the log is gone")
    if SHOTS:
        page.call("Emulation.setDeviceMetricsOverride", width=1280, height=900, deviceScaleFactor=1, mobile=False)
        page.js('document.getElementById("log-card").scrollIntoView()')
        time.sleep(0.5)
        r = page.js('(r => ({x: r.x, y: r.y + scrollY, w: r.width, h: r.height}))'
                    '(document.getElementById("log-card").getBoundingClientRect())')
        data = page.call("Page.captureScreenshot", format="png", captureBeyondViewport=True,
                         clip={"x": r["x"], "y": r["y"], "width": r["w"], "height": r["h"], "scale": 1})["data"]
        os.makedirs(SHOTS, exist_ok=True)
        with open(os.path.join(SHOTS, "logger.png"), "wb") as f:
            f.write(base64.b64decode(data))
        print(f"screenshot {os.path.join(SHOTS, 'logger.png')}")


def adc_tests(page):
    """the ADC card: converting at the expected rate with no channel-ID errors;
    the link test (the ADC's fixed pattern) gives 0xA5A on every input, in
    the registers and in a scope capture of AIN0..7; an input left out of the
    sequence"""
    try:
        r = api("/api/adc")
    except (OSError, ValueError) as e:
        print(f"SKIP  ADC: {e}")
        return
    if not check(wait_for(lambda: page.js('!document.getElementById("adc-card").hidden')),
                 f"ADC card shown: state {r['state']}, mask {r['mask']:#04x}"):
        return

    def settled(pred, timeout=6):
        return wait_for(lambda: (lambda a: a if a.get("state") == "converting" and a.get("rate")
                                 and pred(a) else None)(api("/api/adc")), timeout=timeout)

    a = settled(lambda a: True)
    check(a and abs(a["rate"] / a["expected_rate"] - 1) < 0.05 and a["id_errors"] == 0,
          f"converting: {a and round(a['rate'])} conversions/s of {a and round(a['expected_rate'])} expected, "
          f"{a and a['id_errors']} ID errors")
    page.js('document.getElementById("adc-fixed").click()')
    a = settled(lambda a: a["fixed_pattern"])
    codes = a and [ch["code"] for ch in a["channels"]]
    check(a and all(c == 0xA5A for c in codes) and a["id_errors"] == 0,
          f"link test: codes {codes and ' '.join(f'{c:03X}' for c in codes)}, {a and a['id_errors']} ID errors")
    msg = wait_for(lambda: (lambda t: t if "link test" in (t or "") else None)(
        page.js('document.getElementById("adc-msg").textContent')))
    check(msg and "every input A5A" in msg, f"the card: {msg!r}")
    cap = None
    for _ in range(20):
        cap = api("/api/scope/capture", {"settings": {"sources": list(range(16, 24)), "length": 1024,
                                                      "trigger": False}, "force": True})
        if cap.get("done"):
            break
    if cap and cap.get("done"):
        samples = struct.unpack(f"<{len(base64.b64decode(cap['data'])) // 2}h", base64.b64decode(cap["data"]))
        wrong = sum(1 for v in samples if v != 0xA5A)
        check(wrong == 0, f"scope capture of AIN0..7: {len(samples) // 8} samples, {wrong} values not 0xA5A")
    else:
        check(False, f"scope capture of AIN0..7: {cap}")
    page.js('document.getElementById("adc-on-3").click()')
    a = settled(lambda a: a["mask"] == 0xF7)
    off = page.js('document.getElementById("adc-row-3").classList.contains("off")')
    check(a and off and not a["channels"][3]["enabled"] and a["id_errors"] == 0,
          f"AIN3 left out: mask {a and hex(a['mask'])}, row greyed {off}, {a and a['id_errors']} ID errors")
    page.js('document.getElementById("adc-on-3").click()')
    page.js('document.getElementById("adc-fixed").click()')
    a = settled(lambda a: a["mask"] == 0xFF and not a["fixed_pattern"])
    check(a is not None, f"back to all inputs, no link test: {a and [ch['volts'] for ch in a['channels']]} V")
    if SHOTS:
        page.call("Emulation.setDeviceMetricsOverride", width=1280, height=900, deviceScaleFactor=1, mobile=False)
        page.js('document.getElementById("adc-card").scrollIntoView()')
        time.sleep(1.0)
        r = page.js('(r => ({x: r.x, y: r.y + scrollY, w: r.width, h: r.height}))'
                    '(document.getElementById("adc-card").getBoundingClientRect())')
        data = page.call("Page.captureScreenshot", format="png", captureBeyondViewport=True,
                         clip={"x": r["x"], "y": r["y"], "width": r["w"], "height": r["h"], "scale": 1})["data"]
        os.makedirs(SHOTS, exist_ok=True)
        with open(os.path.join(SHOTS, "adc.png"), "wb") as f:
            f.write(base64.b64decode(data))
        print(f"screenshot {os.path.join(SHOTS, 'adc.png')}")


def control_tests(page):
    """the temperature control card: plot, mode buttons, setpoint, slider"""
    c0 = api("/api/control")["state"]
    if not check(c0.get("available"), f"temperature controller answers: {c0.get('status') or c0.get('error')}"):
        return
    time.sleep(2.5)                     # a few samples for the plot
    plot = page.js('''(() => {
        const t = document.querySelector("#plot-temp svg"), d = document.querySelector("#plot-fan svg");
        const lt = t && t.querySelector("path.line-temp"), ld = d && d.querySelector("path.line-duty");
        return {temp: lt ? lt.getAttribute("d").split(/[ML]/).length - 1 : 0,
                duty: ld ? ld.getAttribute("d").split(/[ML]/).length - 1 : 0,
                sp: !!(t && t.querySelector("line.sp")),
                spText: (t && t.querySelector(".sp-label") || {}).textContent || "",
                width: t ? t.getBoundingClientRect().width : 0,
                pill: document.getElementById("ctl-status").textContent};
    })()''')
    check(plot["temp"] >= 2 and plot["duty"] >= 2 and plot["width"] > 200 and
          (plot["sp"] or c0["mode"] != "auto"),
          f"control plot: {plot['temp']} temperature points, {plot['duty']} fan points, "
          f"setpoint line {plot['sp']} ({plot['spText']!r}), {plot['width']:.0f} px wide, status {plot['pill']!r}")
    # hover: the crosshair and the tooltip
    page.js('''(() => { const h = document.getElementById("plot-temp"), r = h.getBoundingClientRect();
        h.dispatchEvent(new PointerEvent("pointermove", {clientX: r.right - 40, clientY: r.top + 40, bubbles: true})); })()''')
    time.sleep(0.3)
    tip = page.js('!document.getElementById("plot-tip").hidden && document.getElementById("plot-tip").textContent')
    check(bool(tip) and "hottest" in tip, f"plot hover tooltip: {tip!r}")
    page.js('document.getElementById("plot-temp").dispatchEvent(new PointerEvent("pointerleave"))')

    try:
        for mode in ("manual", "off", "auto"):
            page.js(f'document.querySelector("#ctl-modes [data-mode={mode}]").click()')
            got = wait_for(lambda: api("/api/control")["state"].get("mode") == mode)
            shown = wait_for(lambda: (lambda m: m if m == mode else None)(page.js(
                'document.querySelector("#ctl-modes [aria-checked=true]")?.dataset.mode')), 2.0)
            check(got and shown == mode, f"mode button {mode}: controller {api('/api/control')['state']['mode']}, page {shown}")
        sp_new = 43.5 if abs(c0["setpoint"] - 43.5) > 0.05 else 41.5
        page.js(f'(() => {{ const i = document.getElementById("sp-input"); i.focus(); i.value = "{sp_new}";'
                ' document.querySelector("#sp-form button").click(); })()')
        got = wait_for(lambda: abs(api("/api/control")["state"]["setpoint"] - sp_new) < 0.01)
        time.sleep(1.5)
        label = page.js('document.querySelector("#plot-temp .sp-label")?.textContent')
        check(got and label and f"{sp_new:.1f}" in label, f"setpoint {sp_new}: controller "
              f"{api('/api/control')['state']['setpoint']}, plot label {label!r}")
        # the fan slider, with the loop on auto, switches it to manual at that
        # speed; register 9 then holds its KTACH (3000 rpm -> 39 -> 2976 rpm)
        page.js('(() => { const d = document.getElementById("fan-target"); d.value = 3000;'
                ' d.dispatchEvent(new Event("change")); })()')
        st = wait_for(lambda: (lambda s: s if s["mode"] == "manual" and s["manual_rpm"] == 3000 else None)(
            api("/api/control")["state"]))
        time.sleep(1.5)
        fan = api("/api/board")["fan"]
        check(bool(st) and abs(fan["target_rpm"] - 3000) < 60,
              f"fan slider 3000 rpm in auto: controller {api('/api/control')['state']['mode']}, "
              f"register 9 = {fan['ktach']} ({fan['target_rpm']} rpm), measured {fan['rpm']} rpm")
    finally:
        api("/api/control", {"mode": c0["mode"], "setpoint": c0["setpoint"],
                             "manual_rpm": c0["manual_rpm"]})
        print(f"      (put back: mode {c0['mode']}, setpoint {c0['setpoint']}, manual {c0['manual_rpm']} rpm)")


SEG_DIGITS = {0x3F: "0", 0x06: "1", 0x5B: "2", 0x4F: "3", 0x66: "4", 0x6D: "5", 0x7D: "6", 0x07: "7",
              0x7F: "8", 0x6F: "9", 0x77: "A", 0x7C: "b", 0x39: "C", 0x5E: "d", 0x79: "E", 0x71: "F", 0: " "}


def drawn_hex(page):
    """the six digits as the drawing lights them, HEX5 first"""
    lit = page.js('[5,4,3,2,1,0].map(n => [..."abcdefg"].reduce((v, s, b) =>'
                  ' v | (document.getElementById(`hex${n}-${s}`).classList.contains("lit") ? 1 << b : 0), 0))')
    return "".join(SEG_DIGITS.get(v, "?") for v in lit)


def hex_tests(page):
    """the 7-segment card: digits, blank, a segment click (raw), flip"""
    h0 = api("/api/board")["hex"]
    try:
        api("/api/hex", {"flip": False, "blank": 0})      # the checks read the digits unturned
        page.js('(() => { const i = document.getElementById("hex-input"); i.focus(); i.value = "c0ffee";'
                ' document.querySelector("#hex-form button").click(); })()')
        got = wait_for(lambda: (lambda d: d if d == "C0FFEE" else None)(drawn_hex(page)))
        check(api("/api/board")["hex"]["value"] == "c0ffee" and got == "C0FFEE",
              f"HEX card c0ffee: register {api('/api/board')['hex']['value']}, drawing {drawn_hex(page)!r}")
        page.js('document.querySelector("#hex-blank [data-digit=\'5\']").click()')
        got = wait_for(lambda: (lambda d: d if d == " 0FFEE" else None)(drawn_hex(page)))
        check(bool(got), f"blank HEX5: drawing {drawn_hex(page)!r}")
        # a click on HEX0's middle segment: raw mode, "E" without g = "C" with e... toggles g off
        page.js('document.getElementById("hex0-g").dispatchEvent(new MouseEvent("click", {bubbles: true}))')
        time.sleep(1.0)
        b = api("/api/board")["hex"]
        check(b["raw_mode"] and b["lit"][0] == 0x79 & ~0x40,
              f"click HEX0 segment g: raw mode {b['raw_mode']}, HEX0 {b['lit'][0]:#04x} (was 0x79)")
        page.js('(() => { const i = document.getElementById("hex-input"); i.focus(); i.value = "123456";'
                ' document.querySelector("#hex-form button").click(); })()')
        page.js('document.querySelector("#hex-blank [data-digit=\'5\']").click()')
        time.sleep(0.8)
        page.js('document.getElementById("hex-flip").click()')
        got = wait_for(lambda: api("/api/board")["hex"]["flip"])
        time.sleep(0.8)
        lit = api("/api/board")["hex"]["lit"]
        box = page.js('document.getElementById("hex-flip").checked')
        # "123456" turned: HEX0 shows the "1" upside down (e, f), HEX5 the "6" as a "9"
        check(bool(got) and box and lit[0] == 0x30 and lit[5] == 0x6F,
              f"flip: register {got}, HEX0 {lit[0]:#04x} HEX5 {lit[5]:#04x}, checkbox {box}")
    finally:
        api("/api/hex", {"value": "0x" + h0["value"], "blank": h0["blank"], "flip": h0["flip"]})
        print(f"      (put back: HEX {h0['value']}, blank {h0['blank']}, flip {h0['flip']})")


def core_tests(page):
    """the FPGA core card: running build (register 19), installed manifest; Reload"""
    core = api("/api/fpga")
    # build id 0 (a simulated board without a manifest): the card says "unknown"
    want = str(core.get("running_build_id")) if core.get("running_build_id") else "unknown"
    shown = wait_for(lambda: (lambda t: t if t.startswith(want) else None)(
        page.js('document.getElementById("core-build").textContent')))
    check(bool(shown), f"core card: running build {shown!r} (register 19: {want})")
    inst = page.js('document.getElementById("core-installed").textContent')
    m = core.get("installed")
    check(inst.startswith(str(m["build_id"])) if m else inst == "no manifest",
          f"core card: installed {inst!r}")
    if not RELOAD_CORE:
        return
    token_file = os.path.expanduser("~/.de25web_token_std")
    token = open(token_file).read().strip() if os.path.exists(token_file) else ""
    mode = api("/api/board")["blinker"]["name"]
    api("/api/hex", {"value": "0xa5b6c7"})
    page.js(f'document.getElementById("token").value = {json.dumps(token)}')
    page.js('document.getElementById("core-reload").click()')
    msg = wait_for(lambda: (lambda t: t if t.startswith(("Reloaded", "Reload failed")) else None)(
        page.js('document.getElementById("core-msg").textContent')), timeout=30)
    after = wait_for(lambda: (lambda b: b if b.get("blinker") else None)(api("/api/board")), timeout=5)
    check(bool(msg) and msg.startswith("Reloaded") and after and after["blinker"]["name"] == mode
          and after["hex"]["value"] == "a5b6c7",
          f"core card Reload: {msg!r}, blinker {mode} -> {after and after['blinker']['name']}, "
          f"HEX a5b6c7 -> {after and after['hex']['value']}")


def bundle_tests(page, path):
    """a RAUC bundle through the Update card, as a person would"""
    token = open(os.path.expanduser("~/.de25web_token_std")).read().strip()
    name = os.path.basename(path)

    def pick():
        root = page.call("DOM.getDocument")["root"]["nodeId"]
        node = page.call("DOM.querySelector", nodeId=root, selector="#update-file")["nodeId"]
        page.call("DOM.setFileInputFiles", files=[path], nodeId=node)

    def submit(tok):
        page.js(f'document.getElementById("token").value = {json.dumps(tok)}')
        page.js('document.querySelector("#update-form button[type=submit]").click()')

    msg = lambda: page.js('document.getElementById("update-msg").textContent') or ""
    # a wrong token: refused before the body, nothing installed
    pick()
    submit("wrong-token")
    # (the page hashes the file first: an image bundle takes a while)
    shown = wait_for(lambda: (lambda m: m if m.startswith("Not installed") else None)(msg()), 300)
    check(bool(shown) and "X-Token" in shown, f"Update card, {name}, wrong token: {shown!r}")
    # the right token
    before = api("/api/version")["release"]
    core_before = api("/api/fpga").get("running_build_id")
    image_before = (api("/api/rsu") or {}).get("slot")
    page.js("window.__before_install = 1")
    pick()
    submit(token)
    t0 = time.time()
    outcome, rebooting = None, False
    # an image bundle: hashed in the page (46 MB), ~2 min install, a reboot
    while time.time() - t0 < 900 and outcome is None:
        time.sleep(1)
        try:
            reloaded = page.js("window.__before_install === undefined")
            m = msg()
        except Exception:                       # the page reloading under us
            continue
        if "reboots" in m:
            if not rebooting:
                print(f"      {name}: {m!r} ({time.time() - t0:.0f} s)")
            rebooting = True
        if reloaded:
            outcome = "rebooted" if rebooting else "reloaded"
        elif m.startswith(("Installed.", "rauc install failed", "Not installed")):
            outcome = m
    if outcome == "rebooted":
        # an image: the page waited for the board and reloaded by itself; the
        # other application image must run and get confirmed
        r = wait_for(lambda: (lambda r: r if r and r.get("slot") not in (None, image_before)
                              and (r.get("confirm") or "").startswith("confirmed") else None)(
            api_or_none("/api/rsu")), 300)
        card = wait_for(lambda: (lambda t: t if r and t == r.get("slot") else None)(
            page.js('document.getElementById("rsu-image").textContent')), 30)
        pill = wait_for(lambda: (lambda t: t if t == "confirmed" else None)(
            page.js('document.getElementById("rsu-confirm").textContent')), 40)
        check(bool(r) and bool(card) and bool(pill),
              f"Update card, {name}: board rebooted from {image_before} into "
              f"{r and r.get('slot')} ({r and r.get('confirm')!r}); page shows {card!r} {pill!r} - "
              f"{time.time() - t0:.0f} s")
        return
    if outcome == "reloaded":
        # a GUI release: the new page confirms it (loadVersion), which lets
        # rauc install finish
        v = wait_for(lambda: (lambda v: v if v.get("release") != before and not v.get("pending") else None)(
            api("/api/version")), 60)
        b = wait_for(lambda: (lambda b: b if b.get("rc") is not None else None)(api("/api/bundle")), 60)
        page_rel = page.js('document.getElementById("ver").textContent')
        check(bool(v) and bool(b) and b.get("rc") == 0 and page_rel == v.get("release"),
              f"Update card, {name}: page reloaded into {page_rel!r}, confirmed "
              f"(was {before!r}), rauc install exit {b and b.get('rc')} - {time.time() - t0:.0f} s")
    else:
        b = api("/api/bundle")
        core = api("/api/fpga")
        check(outcome is not None and outcome.startswith("Installed") and b.get("rc") == 0,
              f"Update card, {name}: {outcome!r}, rauc install exit {b.get('rc')}, core "
              f"{core_before} -> {core.get('running_build_id')} - {time.time() - t0:.0f} s")


def shot(page, name, width, height):
    page.call("Emulation.setDeviceMetricsOverride", width=width, height=height,
              deviceScaleFactor=1, mobile=width < 600)
    time.sleep(0.8)
    full = page.js("document.documentElement.scrollHeight")
    page.call("Emulation.setDeviceMetricsOverride", width=width, height=full,
              deviceScaleFactor=1, mobile=width < 600)
    time.sleep(0.5)
    data = page.call("Page.captureScreenshot", format="png")["data"]
    os.makedirs(SHOTS, exist_ok=True)
    path = os.path.join(SHOTS, name)
    with open(path, "wb") as f:
        f.write(base64.b64decode(data))
    overflow = page.js("document.documentElement.scrollWidth > window.innerWidth")
    print(f"screenshot {path} ({width} px wide{', HORIZONTAL OVERFLOW' if overflow else ''})")
    return not overflow


proc = subprocess.Popen([chrome(), "--no-sandbox", "--hide-scrollbars", f"--remote-debugging-port={PORT}",
                         "--window-size=1280,900", "about:blank"],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
failures = 0
try:
    for _ in range(50):
        try:
            targets = json.load(urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json"))
            break
        except OSError:
            time.sleep(0.2)
    page_target = next(t for t in targets if t["type"] == "page")
    page = Page(WebSocket(page_target["webSocketDebuggerUrl"]))
    page.call("Page.enable")
    page.call("Runtime.enable")
    page.call("Page.navigate", url=URL)
    time.sleep(2.5)
    conn = page.js('document.getElementById("conn").textContent')
    leds = page.js('document.querySelectorAll("#board .led").length')
    ok = conn == "live" and leds == LEDS
    failures += not ok
    print(f"{'PASS' if ok else 'FAIL'}  page: connection {conn!r}, {leds} LEDs in the drawing")

    for mode in MODES:
        page.js(f'[...document.querySelectorAll("#modes button")].find(b => b.textContent === "{mode}").click()')
        time.sleep(1.0)
        shown = page.js('({checked: document.querySelector(\'#modes [aria-checked="true"]\')?.textContent,'
                        ' module: document.getElementById("module-id").textContent,'
                        ' glow: [...document.querySelectorAll("#board .led-glow")].map(g => +g.style.opacity)})')
        board = api("/api/board")
        lit = sum(1 for g in shown["glow"] if g > 0.05)
        ok = shown["checked"] == mode and board["blinker"]["name"] == mode
        if mode in ("counter", "scanner", "breathing", "sparkle"):
            ok = ok and len(shown["module"]) == 4
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}  picked {mode:9s} -> page {shown['checked']!s:9s} "
              f"module {shown['module']!s:11s} register {board['blinker']['name']:9s} lit {lit}/{LEDS}")
        if mode == "scanner" and SHOTS:
            shot(page, "desktop.png", 1280, 900)

    # software mode: clicking LEDR2 in the drawing toggles bit 2 of register 5
    before = api("/api/board")["led_register"]
    page.js('document.querySelector("#board #ledr2").dispatchEvent(new MouseEvent("click", {bubbles: true}))')
    time.sleep(0.8)
    after = api("/api/board")["led_register"]
    ok = after == before ^ 0x04
    failures += not ok
    print(f"{'PASS' if ok else 'FAIL'}  click LEDR2 in software mode: register 5 {before:#05x} -> {after:#05x}")

    hex_tests(page)
    scope_tests(page)
    stream_tests(page)
    logger_tests(page)
    adc_tests(page)
    control_tests(page)
    core_tests(page)
    for b in BUNDLES:
        bundle_tests(page, b)
    rsu = api("/api/rsu")
    if rsu.get("rsu"):
        shown = wait_for(lambda: (lambda t: t if t and t != "-" else None)(
            page.js('document.getElementById("rsu-image").textContent')))
        pill = page.js('document.getElementById("rsu-confirm").textContent')
        p1 = page.js('document.getElementById("rsu-p1").textContent')
        p2 = page.js('document.getElementById("rsu-p2").textContent')
        check(shown in ("P1", "P2", "factory image") and pill in ("confirmed", "fallback image", "on test")
              and ("running" in (p1 + p2)) == (shown in ("P1", "P2")),
              f"FPGA image card: running {shown!r}, {pill!r}, P1 {p1!r}, P2 {p2!r} (board: {rsu.get('confirm')!r})")

    if SHOTS:
        time.sleep(2)
        shot(page, "control.png", 1280, 900)
        page.js('[...document.querySelectorAll("#modes button")].find(b => b.textContent === "sparkle").click()')
        time.sleep(1.0)
        failures += not shot(page, "phone.png", 390, 844)
finally:
    proc.terminate()

print("PASS" if not failures else f"{failures} FAILED")
sys.exit(1 if failures else 0)
