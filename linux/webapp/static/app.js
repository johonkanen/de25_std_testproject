// DE25-Standard web GUI (ported from the DE25-Nano's): the board drawing,
// live from /api/events (20 updates a second, polling /api/board if the
// stream drops), the blinker picker, the LED register, the HEX displays, the
// fan (rpm), the die temperature control loop (plot and controls), FPGA core
// loads and GUI release updates.
"use strict";

const $ = (id) => document.getElementById(id);
const LEDS = 10;                 // LEDR0..9; LEDR9 is the heartbeat in software mode
const HEARTBEAT = LEDS - 1;
const SEGS = "abcdefg";          // bit n of a HEX digit's byte: segment SEGS[n]
const MODE_INFO = {
  software: "register 5",
  off: "all dark",
  counter: "binary count",
  scanner: "sweep",
  breathing: "fade",
  sparkle: "random",
};
let state = null;
let svg = null;
let release = null;      // /api/version

async function api(path, body, headers = {}) {
  const opts = body === undefined ? {} : {
    method: "POST",
    headers: body instanceof Blob ? headers : { "Content-Type": "application/json", ...headers },
    body: body instanceof Blob ? body : JSON.stringify(body),
  };
  const r = await fetch(path, opts);
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || r.status + " " + r.statusText);
  return j;
}

// ---------------------------------------------------------------- board
function buildLedBar() {
  const bar = $("ledbar");
  for (let i = LEDS - 1; i >= 0; i--) {
    const b = document.createElement("button");
    b.type = "button";
    b.dataset.led = i;
    b.title = i === HEARTBEAT ? `LEDR${i} (heartbeat in software mode)` : "LEDR" + i;
    b.innerHTML = `<span>${i}</span>`;
    b.addEventListener("click", () => {
      if (state && state.blinker.name === "software" && i !== HEARTBEAT) toggleLed(i);
      else focusCard("blinker-card");
    });
    bar.appendChild(b);
  }
}

async function loadBoard() {
  const text = await (await fetch("/static/board.svg")).text();
  $("board").innerHTML = text;
  svg = $("board").querySelector("svg");
  svg.querySelector("#leds").addEventListener("click", (e) => {
    const led = e.target.closest(".led");
    if (led && state && state.blinker.name === "software" && led.dataset.led !== String(HEARTBEAT)) {
      toggleLed(Number(led.dataset.led));
    } else {
      focusCard("blinker-card");
    }
  });
  svg.querySelector("#leds").addEventListener("keydown", (e) => {
    if (e.key === "Enter" || e.key === " ") { e.preventDefault(); focusCard("blinker-card"); }
  });
  // a click on a HEX segment toggles it: raw mode, starting from what is lit
  svg.querySelector("#hex").addEventListener("click", (e) => {
    const m = e.target.id && e.target.id.match(/^hex(\d)-([a-g])$/);
    if (!m || !state || !state.hex) { focusCard("hex-card"); return; }
    // the drawing shows the segments driven; raw takes the digits as read,
    // so with flip on, turn the click (and what is lit) back first
    const turn = (b) => (b & 0x40) | ((b & 7) << 3) | ((b >> 3) & 7);
    const flip = state.hex.flip;
    const raw = flip ? state.hex.lit.slice().reverse().map(turn) : state.hex.lit.slice();
    const bit = 1 << SEGS.indexOf(m[2]);
    const d = Number(m[1]);
    if (flip) raw[5 - d] ^= turn(bit);
    else raw[d] ^= bit;
    api("/api/hex", { raw }).catch(showError);
  });
}

function focusCard(id) {
  const card = $(id);
  card.scrollIntoView({ behavior: "smooth", block: "nearest" });
  card.classList.add("flash");
  setTimeout(() => card.classList.remove("flash"), 700);
  const checked = card.querySelector('[aria-checked="true"]') || card.querySelector("button");
  if (checked) checked.focus({ preventScroll: true });
}

function renderBoard(s) {
  if (!svg) return;
  s.levels.forEach((l, i) => {
    const g = svg.querySelector("#ledr" + i);
    const on = l / 255;
    g.querySelector(".led-glow").style.opacity = (on * 0.95).toFixed(2);
    g.querySelector(".led-body").style.fill = on > 0.02
      ? `color-mix(in srgb, var(--led-on) ${Math.round(on * 100)}%, var(--led-off))` : "";
  });
  document.querySelectorAll("#ledbar button").forEach((b) => {
    const on = s.levels[Number(b.dataset.led)] / 255;
    b.style.background = on > 0.02
      ? `color-mix(in srgb, var(--led-on) ${Math.round(on * 100)}%, var(--led-off))` : "";
    b.style.boxShadow = on > 0.02 ? `0 0 ${Math.round(4 + on * 16)}px rgba(255, 59, 48, ${(on * 0.8).toFixed(2)})` : "";
  });
  s.switches.forEach((v, i) => svg.querySelector("#sw" + i).classList.toggle("up", !!v));
  s.keys.forEach((v, i) => svg.querySelector("#key" + i).classList.toggle("pressed", !!v));
  svg.querySelector("#cpu-reset").classList.toggle("pressed", !!s.cpu_reset);
  if (s.hex) {
    s.hex.lit.forEach((byte, n) => {
      for (let b = 0; b < 7; b++) {
        svg.querySelector(`#hex${n}-${SEGS[b]}`).classList.toggle("lit", !!((byte >> b) & 1));
      }
    });
  }
  const rotor = svg.querySelector("#fan-rotor");
  const rpm = s.fan.rpm;
  rotor.classList.toggle("spin", rpm > 0);
  // shown slowed down (a real rotation would be a blur): one turn per 6000/rpm s
  if (rpm > 0) rotor.style.setProperty("--fan-period", Math.max(0.15, 6000 / rpm).toFixed(2) + "s");
  svg.querySelector("#fan-label").textContent = rpm > 0 ? rpm + " rpm" : "FAN";
}

// ---------------------------------------------------------------- panels
function buildPanels() {
  const modes = $("modes");
  Object.keys(MODE_INFO).forEach((name, i) => {
    const b = document.createElement("button");
    b.type = "button";
    b.role = "radio";
    b.dataset.mode = i;
    b.setAttribute("aria-checked", "false");
    b.title = MODE_INFO[name];
    b.textContent = name;
    b.addEventListener("click", () => setMode(i));
    modes.appendChild(b);
  });
  const bits = $("led-bits");
  for (let i = LEDS - 1; i >= 0; i--) {
    const b = document.createElement("button");
    b.type = "button";
    b.dataset.bit = i;
    b.textContent = i;
    b.title = i === HEARTBEAT ? `LEDR${i}: heartbeat` : "LEDR" + i;
    if (i === HEARTBEAT) b.disabled = true;
    else b.addEventListener("click", () => toggleLed(i));
    bits.appendChild(b);
  }
  const fan = $("fan-target");
  fan.addEventListener("input", () => { $("fan-target-val").textContent = fan.value; });
  fan.addEventListener("change", () => api("/api/fan", { rpm: Number(fan.value) })
    .then((r) => { if (r.note) $("ctl-msg").textContent = "Fan slider: " + r.note + "."; })
    .catch(showError));
  $("hex-form").addEventListener("submit", (e) => {
    e.preventDefault();
    const v = $("hex-input").value.trim().replace(/^0x/i, "");
    if (!/^[0-9a-f]{1,6}$/i.test(v)) { $("hex-msg").textContent = "Up to six hex digits."; return; }
    api("/api/hex", { value: "0x" + v }).then(() => { $("hex-msg").textContent = ""; $("hex-input").blur(); })
      .catch((err) => { $("hex-msg").textContent = "Refused: " + err.message; });
  });
  $("hex-flip").addEventListener("change", (e) => {
    api("/api/hex", { flip: e.target.checked }).catch(showError);
  });
  const blanks = $("hex-blank");
  for (let n = 5; n >= 0; n--) {
    const b = document.createElement("button");
    b.type = "button";
    b.dataset.digit = n;
    b.textContent = "HEX" + n;
    b.title = `blank HEX${n}`;
    b.addEventListener("click", () => {
      if (state && state.hex) api("/api/hex", { blank: state.hex.blank ^ (1 << n) }).catch(showError);
    });
    blanks.appendChild(b);
  }
  $("update-form").addEventListener("submit", (e) => { e.preventDefault(); installBundle(); });
  $("rollback").addEventListener("click", rollback);
  $("core-reload").addEventListener("click", reloadCore);
}

function renderPanels(s) {
  $("hw-note").hidden = s.hw_blinkers;
  document.querySelectorAll("#modes button").forEach((b) => {
    const m = Number(b.dataset.mode);
    b.setAttribute("aria-checked", String(m === s.blinker.mode));
    b.disabled = !s.hw_blinkers && m > 1;
  });
  $("module-id").textContent = s.blinker.module_id || (s.blinker.name === "software" ? "register 5" : "-");
  const soft = s.blinker.name === "software";
  document.querySelectorAll("#led-bits button").forEach((b) => {
    const i = Number(b.dataset.bit);
    const on = i === HEARTBEAT ? s.levels[HEARTBEAT] > 127 : (s.led_register >> i) & 1;
    b.classList.toggle("on", !!on);
    if (i !== HEARTBEAT) b.disabled = !soft;
  });
  if (s.hex) {
    const input = $("hex-input");
    if (document.activeElement !== input) input.value = s.hex.value;
    $("hex-mode").textContent = (s.hex.raw_mode ? "raw segments" : "hex digits") + (s.hex.flip ? ", flipped" : "");
    $("hex-flip").checked = s.hex.flip;
    document.querySelectorAll("#hex-blank button").forEach((b) => {
      b.classList.toggle("on", !!((s.hex.blank >> Number(b.dataset.digit)) & 1));
    });
  }
  $("hex-card").hidden = !s.hw_hex;
  const fan = $("fan-target");
  if (document.activeElement !== fan) {
    fan.value = s.fan.target_rpm;
    $("fan-target-val").textContent = s.fan.target_rpm;
  }
  $("fan-rpm").textContent = s.fan.rpm;
  // closed_loop false: the MAX6650 does not regulate (plan §5.17b)
  const f = s.fan, stuck = f.closed_loop === false;
  $("fan-ok").textContent = f.i2c_error ? "I2C error" : !f.init_done ? "starting"
    : stuck ? `not regulating (Config 0x${f.config_readback.toString(16).padStart(2, "0")}) - the fan ignores its target; power-cycle the board if it stays`
    : f.reconfigs ? `ok (set up again ${f.reconfigs}${f.reconfigs === 15 ? "+" : ""} times)` : "ok";
  $("fan-ok").classList.toggle("bad", f.i2c_error || stuck);
  $("git").textContent = s.git_hash;
  if (s.build_id !== undefined) $("core-build").textContent = buildName(s.build_id);
  $("uptime").textContent = formatUptime(s.linux_uptime_s);
}

// the SoC's temperatures (deg C) and supply voltages, sampled by the server
// once a second from the kernel's soc64-hwmon (the SDM's sensors)
const TEMP_MAX_C = 100;          // Agilex 5 junction limit (industrial grades go higher)
const esc = (t) => String(t).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const shortLabel = (l) => l.replace(/^Main Die /, "").replace(/ max$/, "").replace(/^corner /, "corner ");

function renderSoc(soc) {
  const temps = (soc && soc.temps) || [];
  $("soc-none").hidden = !!(soc && soc.available);
  $("soc-temps").innerHTML = temps.map((t) => {
    const pct = Math.max(0, Math.min(100, (t.c / TEMP_MAX_C) * 100));
    const cls = t.c >= 85 ? "hot" : t.c >= 70 ? "warm" : "";
    return `<span class="name" title="${esc(t.label)}">${esc(shortLabel(t.label))}</span>` +
           `<span class="val">${t.c.toFixed(1)} °C</span>` +
           `<span class="bar"><span class="${cls}" style="width:${pct.toFixed(0)}%"></span></span>`;
  }).join("");
  $("soc-volts").innerHTML = ((soc && soc.volts) || []).map((v) =>
    `<span class="name">${esc(v.label)}</span><span class="val">${v.v.toFixed(3)} V</span>`).join("");
  // on the die in the drawing, each sensor at its corner (board.svg)
  if (svg) {
    svg.querySelectorAll("#soc-sensors .tsd").forEach((g) => {
      const t = temps.find((x) => x.label.includes(g.dataset.sensor));
      g.classList.toggle("none", !t);
      if (!t) return;
      g.classList.toggle("hot", t.c >= 85);
      g.classList.toggle("warm", t.c >= 70 && t.c < 85);
      g.querySelector(".tsd-val").textContent = t.c.toFixed(1) + " °C";
    });
  }
}

function formatUptime(sec) {
  // Linux's, not register 8 (32 bits at 50 MHz: it wraps every ~86 s)
  const d = Math.floor(sec / 86400), h = Math.floor(sec / 3600) % 24;
  const m = Math.floor(sec / 60) % 60, s = Math.floor(sec % 60);
  return (d ? d + "d " : "") + [h, m, s].map((x) => String(x).padStart(2, "0")).join(":");
}

async function setMode(m) {
  try { await api("/api/blinker", { mode: m }); } catch (e) { showError(e); }
}

async function toggleLed(i) {
  if (!state) return;
  try { await api("/api/leds", { value: state.led_register ^ (1 << i) }); } catch (e) { showError(e); }
}

function showError(e) {
  setConn("bad", String(e.message || e));
}

function setConn(kind, text) {
  const c = $("conn");
  c.className = "pill pill-" + kind;
  c.textContent = text;
}

function onState(s) {
  renderControl(s.control);
  if (s.error) {
    setConn("bad", s.fpga_unavailable ? "FPGA access unavailable" : "register read failed");
    renderSoc(s.soc);
    return;
  }
  state = s;
  setConn(s.id_ok ? "ok" : "bad", s.id_ok ? "live" : "unexpected id " + s.id.toString(16));
  renderBoard(s);
  renderPanels(s);
  renderSoc(s.soc);
}

// ---------------------------------------------------------------- live data
function connect() {
  if (!window.EventSource) return poll();
  const es = new EventSource("/api/events");
  es.onopen = () => loadControl();      // (re)fill the plot from the server's history
  es.onmessage = (e) => onState(JSON.parse(e.data));
  es.onerror = () => {
    setConn("wait", "reconnecting");
    es.close();
    setTimeout(connect, 1500);
  };
}

async function poll() {
  try { onState(await api("/api/board")); } catch (e) { setConn("bad", "offline"); }
  setTimeout(poll, 250);
}

// ---------------------------------------------------------------- FPGA core
// build id = the Unix time the build was stamped (write_build_id.sh)
function buildName(id) {
  // 0 / all ones: a core from before register 19 (unmapped reads)
  if (!id || id === 0xFFFFFFFF) return "unknown (no register 19)";
  return id + " (" + new Date(id * 1000).toISOString().slice(0, 16).replace("T", " ") + " UTC)";
}

function manifestName(m) {
  if (!m) return "no manifest";
  if (m.error) return m.error;
  return buildName(m.build_id) + (m.git ? ", git " + m.git : "");
}

async function loadCoreInfo() {
  const c = await api("/api/fpga");
  $("core-installed").textContent = manifestName(c.installed);
  $("core-prev").textContent = c.previous ? manifestName(c.previous) : "-";
  $("core-mismatch").hidden = !(c.installed && c.installed.build_id && c.running_build_id !== null
                                && c.running_build_id !== c.installed.build_id);
  return c;
}

async function reloadCore() {
  $("core-msg").textContent = "Reloading the installed core...";
  $("core-reload").disabled = true;
  try {
    const r = await api("/api/fpga/reload", {}, { "X-Token": $("token").value });
    $("core-msg").textContent = `Reloaded build ${r.build_id} in ${r.seconds} s.`;
  } catch (e) {
    $("core-msg").textContent = "Reload failed: " + e.message + " (the token is in the Update card)";
  } finally {
    $("core-reload").disabled = false;
    loadCoreInfo().catch(() => {});
  }
}

// ---------------------------------------------------------------- FPGA image (RSU)
const IMAGES = { 0x220000: "factory image", 0x400000: "P1", 0x700000: "P2" };

function imageLine(img, name) {
  if (!img) return "-";
  if (img.priority === "[disabled]" || img.priority === null)
    return "nothing bootable (empty, erased or disabled)";
  return (img.build_id ? buildName(img.build_id) : "written by the .jic")
    + (img.running ? " - running" : "") + ` (priority ${img.priority})`;
}

async function loadRsuInfo() {
  const r = await api("/api/rsu");
  if (!r.rsu) {
    $("rsu-card").hidden = true;            // no RSU flash layout on this board
    return r;
  }
  const st = r.status || {};
  const cur = parseInt(st.current_image || "0", 16);
  const fail = parseInt(st.fail_image || "0", 16);
  $("rsu-image").textContent = IMAGES[cur] || ("0x" + cur.toString(16));
  const c = r.confirm || "";
  const pill = $("rsu-confirm");
  pill.textContent = c.startsWith("confirmed") ? "confirmed" : c.startsWith("factory") ? "fallback image"
    : c.startsWith("waiting") ? "on test" : c.startsWith("failed") ? "not healthy" : (c || "-");
  pill.className = "pill" + (c.startsWith("confirmed") ? "" : " pill-warn");
  const images = r.images || {};
  $("rsu-p1").textContent = imageLine(images.P1, "P1");
  $("rsu-p2-row").hidden = !images.P2;      // no P2 before the A/B layout
  $("rsu-p2").textContent = imageLine(images.P2, "P2");
  $("rsu-fail").hidden = !fail;
  $("rsu-fail").textContent = fail ? `${IMAGES[fail] || "0x" + fail.toString(16)} failed (state ${st.state}) - the SDM fell back` : "";
  return r;
}

function waitForBoard(msg) {
  // the board reboots: wait for it to go away, then reload when it answers
  let down = false;
  const t0 = Date.now();
  const tick = async () => {
    try {
      await api("/api/version");
      if (down) { location.reload(); return; }
    } catch (e) { down = true; }
    if (Date.now() - t0 < 600000) setTimeout(tick, 3000);
    else msg.textContent = "The board did not come back within 10 minutes.";
  };
  setTimeout(tick, 3000);
}

// ---------------------------------------------------------------- releases
async function loadVersion() {
  release = await api("/api/version");
  $("ver").textContent = release.managed ? release.release : release.version;
  $("prev").textContent = release.previous || "-";
  $("pending").hidden = !release.pending;
  const managed = release.managed;
  $("rollback").disabled = !managed;
  if (!managed) $("release-msg").textContent = "Not an installed release - updates are off (development run).";
  // This page loaded and read the board: the release on test works. Keep it
  // (a GUI release from a bundle: the install on the board waits for this).
  if (managed && release.pending && release.pending === release.release) {
    // the server only confirms once all three processes answer; retry a while
    for (let i = 0; i < 20; i++) {
      try {
        await api("/api/update/confirm", {});
        $("release-msg").textContent = `Release ${release.release} confirmed.`;
        $("pending").hidden = true;
        return;
      } catch (e) {
        $("release-msg").textContent = "Not confirmed yet: " + e.message;
        await new Promise((r) => setTimeout(r, 3000));
      }
    }
  }
}

async function rollback() {
  try {
    const r = await api("/api/update/rollback", {}, { "X-Token": $("token").value });
    $("release-msg").textContent = `Rolling back to ${r.current}...`;
    waitForRestart();
  } catch (e) {
    $("release-msg").textContent = "Rollback refused: " + e.message + " (the token is in the Update card)";
  }
}

function waitForRestart() {
  // the server restarts into another release; reload once it answers again
  const t0 = Date.now();
  const tick = async () => {
    try {
      const v = await api("/api/version");
      if (v.release !== release.release) { location.reload(); return; }
    } catch (e) { /* still restarting */ }
    if (Date.now() - t0 < 60000) setTimeout(tick, 1000);
    else $("release-msg").textContent = "The board did not come back within a minute.";
  };
  setTimeout(tick, 1500);
}

// ---------------------------------------------------------------- RAUC bundles
// POST /api/bundle starts `rauc install` on the board and answers at once;
// GET /api/bundle follows it. A GUI release in the bundle restarts the
// server: this page then reloads, and the new page confirms the release
// (loadVersion), which is what lets the install finish. An image bundle
// ends in a reboot into the other application image.
async function installBundle() {
  const file = $("update-file").files[0];
  const msg = $("update-msg"), log = $("update-log");
  if (!file) { msg.textContent = "Pick a .raucb bundle first (linux/tools/make_bundle.py)."; return; }
  const form = $("update-form").querySelectorAll("input, button");
  form.forEach((el) => { el.disabled = true; });
  try {
    msg.textContent = `Checking ${file.name} (${(file.size / 1e6).toFixed(1)} MB)...`;
    const buf = await file.arrayBuffer();
    const sha = await sha256hex(buf);
    msg.textContent = `Uploading ${file.name}...`;
    await api("/api/bundle", new Blob([buf]), { "X-Sha256": sha, "X-Token": $("token").value });
    msg.textContent = "Installing - the board checks the signature, then writes it.";
    followBundle(release && release.release);
  } catch (e) {
    msg.textContent = "Not installed: " + e.message;
    form.forEach((el) => { el.disabled = false; });
  }
}

function followBundle(before) {
  const msg = $("update-msg"), log = $("update-log");
  const tick = async () => {
    let b;
    try { b = await api("/api/bundle"); } catch (e) { setTimeout(tick, 2000); return; }   // restarting
    const lines = (b.log || "").split("\n").filter((l) => l && !/^\s+\d+% /.test(l));
    log.hidden = !lines.length;
    log.textContent = lines.slice(-8).join("\n");
    if (b.rc === null || b.running) {
      // a GUI release from the bundle is running: reload, the new page confirms it
      try {
        const v = await api("/api/version");
        if (v.pending && v.release === v.pending && v.release !== before) { location.reload(); return; }
      } catch (e) { /* restarting */ }
      setTimeout(tick, 2000);
      return;
    }
    if (b.rc !== 0) {
      msg.textContent = `rauc install failed (exit ${b.rc}) - the board keeps what it had.`;
      $("update-form").querySelectorAll("input, button").forEach((el) => { el.disabled = false; });
      return;
    }
    if (b.reboot) {
      msg.textContent = "Installed; the board reboots into the new image. The page comes back once it is up; "
        + "the image counts when it shows \"confirmed\".";
      waitForBoard(msg);
      return;
    }
    msg.textContent = "Installed.";
    $("update-form").querySelectorAll("input, button").forEach((el) => { el.disabled = false; });
    loadCoreInfo().catch(() => {});
    loadVersion().catch(() => {});
  };
  setTimeout(tick, 1500);
}

// SHA-256: crypto.subtle only exists in secure contexts (https, localhost),
// and the board is plain http - so a small implementation as the fallback.
async function sha256hex(buf) {
  if (window.crypto && crypto.subtle) {
    const d = await crypto.subtle.digest("SHA-256", buf);
    return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
  }
  return sha256Fallback(new Uint8Array(buf));
}

function sha256Fallback(data) {
  const K = new Uint32Array([
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]);
  const H = new Uint32Array([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                             0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]);
  const len = data.length;
  const total = Math.ceil((len + 9) / 64) * 64;
  const m = new Uint8Array(total);
  m.set(data);
  m[len] = 0x80;
  const dv = new DataView(m.buffer);
  dv.setUint32(total - 8, Math.floor(len / 0x20000000));
  dv.setUint32(total - 4, (len * 8) >>> 0);
  const w = new Uint32Array(64);
  const rotr = (x, n) => (x >>> n) | (x << (32 - n));
  for (let off = 0; off < total; off += 64) {
    for (let i = 0; i < 16; i++) w[i] = dv.getUint32(off + 4 * i);
    for (let i = 16; i < 64; i++) {
      const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }
    let [a, b, c, d, e, f, g, h] = H;
    for (let i = 0; i < 64; i++) {
      const t1 = (h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i]) >>> 0;
      const t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) >>> 0;
      h = g; g = f; f = e; e = (d + t1) >>> 0; d = c; c = b; b = a; a = (t1 + t2) >>> 0;
    }
    H[0] += a; H[1] += b; H[2] += c; H[3] += d; H[4] += e; H[5] += f; H[6] += g; H[7] += h;
  }
  return [...H].map((x) => x.toString(16).padStart(8, "0")).join("");
}

// ---------------------------------------------------------------- temperature control
// The loop runs in temp_control.py on the board; this shows its state, the
// last 10 minutes (from GET /api/control, then one point a second from the
// event stream) and sends mode / setpoint changes.
const ctl = { hist: [], boot: null, last: null, span: 600, hover: null, busy: false };
const GAP_S = 3.5;           // samples further apart than this are drawn as a gap

async function loadControl() {
  try {
    const r = await api("/api/control");
    ctl.hist = r.history || [];
    ctl.span = r.history_s || 600;
    ctl.boot = r.state && r.state.boot;
    renderControl(r.state);
    drawPlots();
  } catch (e) { /* the event stream shows the state anyway */ }
}

function buildControl() {
  document.querySelectorAll("#ctl-modes button").forEach((b) => {
    b.addEventListener("click", () => sendControl({ mode: b.dataset.mode }));
  });
  $("sp-form").addEventListener("submit", (e) => {
    e.preventDefault();
    const v = Number($("sp-input").value);
    if (!(v >= 25 && v <= 85)) { $("ctl-msg").textContent = "Setpoint 25..85 °C."; return; }
    sendControl({ setpoint: v }).then(() => $("sp-input").blur());
  });
  ["plot-temp", "plot-fan"].forEach((id) => {
    const host = $(id);
    host.addEventListener("pointermove", (e) => hoverAt(host, e.clientX));
    host.addEventListener("pointerdown", (e) => hoverAt(host, e.clientX));
    host.addEventListener("pointerleave", () => { ctl.hover = null; drawPlots(); });
  });
  let rt = null;
  window.addEventListener("resize", () => { clearTimeout(rt); rt = setTimeout(drawPlots, 100); });
}

async function sendControl(body) {
  ctl.busy = true;
  try {
    const r = await api("/api/control", body);
    $("ctl-msg").textContent = body.mode ? `Mode ${r.state.mode}.` : `Setpoint ${r.state.setpoint.toFixed(1)} °C.`;
    renderControl({ available: true, ...r.state });
  } catch (e) {
    $("ctl-msg").textContent = "Refused: " + e.message;
  } finally { ctl.busy = false; }
}

function renderControl(c) {
  if (!c) return;
  const ok = !!c.available;
  $("ctl-none").hidden = ok;
  document.querySelectorAll("#ctl-modes button, #sp-form input, #sp-form button")
    .forEach((el) => { el.disabled = !ok; });
  if (!ok) {
    setPill("ctl-status", "bad", "not running");
    $("fan-note").textContent = "Temperature control is not running: the slider writes the fan register directly.";
    return;
  }
  if (c.boot && ctl.boot && c.boot !== ctl.boot) { ctl.boot = c.boot; loadControl(); }
  ctl.boot = ctl.boot || c.boot;
  if (c.t !== undefined && (!ctl.last || c.t > ctl.last.t)) {
    const h = ctl.hist;
    if (!h.length || c.t > h[h.length - 1][0]) {
      h.push([c.t, c.measured, c.mode === "auto" ? c.setpoint : null, c.target_rpm, c.rpm]);
      while (h.length && h[0][0] < c.t - ctl.span - 30) h.shift();
    }
    ctl.last = c;
    drawPlots();
  }
  document.querySelectorAll("#ctl-modes button").forEach((b) => {
    b.setAttribute("aria-checked", String(b.dataset.mode === c.mode));
  });
  const sp = $("sp-input");
  if (document.activeElement !== sp && !ctl.busy) sp.value = c.setpoint.toFixed(1);
  const withUnit = (v, d) => v == null ? "-" : `${v.toFixed(d)}<span class="unit"> °C</span>`;
  $("ctl-meas").innerHTML = withUnit(c.measured, 2);
  $("ctl-hottest").textContent = c.hottest ? shortLabel(c.hottest) : "no sensor";
  $("ctl-hottest").title = c.hottest || "";
  $("ctl-sp").innerHTML = withUnit(c.setpoint, 1);
  $("ctl-err").textContent = c.mode !== "auto" ? "loop " + c.mode
    : c.error == null ? "-" : "error " + (c.error >= 0 ? "+" : "") + c.error.toFixed(2) + " °C";
  $("ctl-fan").innerHTML = c.target_rpm == null ? "-" : `${c.target_rpm}<span class="unit"> rpm</span>`;
  $("ctl-rpm").textContent = c.rpm == null ? "-" : "measured " + c.rpm + " rpm";
  // the pill: a word, not color alone
  if (!c.fpga_ok) setPill("ctl-status", "bad", "FPGA access unavailable");
  else if (c.fan_closed_loop === false) setPill("ctl-status", "bad", "fan controller not regulating");
  else if (c.mode === "off") setPill("ctl-status", "wait", "off");
  else if (c.mode === "manual") setPill("ctl-status", "wait", "manual");
  else if (!c.sensor_ok) setPill("ctl-status", "bad", "no temperature");
  else if (c.saturated === "low") setPill("ctl-status", "warn", "saturated: fan at minimum");
  else if (c.saturated === "high") setPill("ctl-status", "bad", "saturated: fan at full");
  else if (c.settled) setPill("ctl-status", "ok", "settled ±" + c.settle_band + " °C");
  else setPill("ctl-status", "wait", "regulating");
  $("ctl-status").title = c.status || "";
  const mean = c.mean_error == null ? "-" : (c.mean_error >= 0 ? "+" : "") + c.mean_error.toFixed(2) + " °C";
  $("ctl-detail").textContent = `${c.status}. Kp ${c.kp} rpm/°C, Ki ${c.ki} rpm/(°C·s), ` +
    `P ${c.p}, I ${c.i}, mean error over the last 30 s ${mean}, sample every ${c.period_s} s.`;
  $("fan-note").textContent = c.mode === "auto"
    ? "Temperature control is on auto: moving the slider switches it to manual."
    : c.mode === "manual" ? `Manual: the slider sets the loop's fan speed (at least ${c.rpm_min} rpm).`
    : "Temperature control is off: the slider writes the fan register directly.";
}

function setPill(id, kind, text) {
  const el = $(id);
  el.className = "pill pill-" + kind;
  el.textContent = text;
}

function hoverAt(host, clientX) {
  const svgEl = host.querySelector("svg");
  if (!svgEl || !ctl.hist.length) return;
  const r = svgEl.getBoundingClientRect();
  const g = ctl.geom;
  const x = (clientX - r.left) * (g.w / r.width);
  const t = g.t1 - (g.x1 - x) / (g.x1 - g.x0) * ctl.span;
  let best = null;
  for (const p of ctl.hist) if (!best || Math.abs(p[0] - t) < Math.abs(best[0] - t)) best = p;
  ctl.hover = best && Math.abs(best[0] - t) < 10 ? best : null;
  drawPlots();
}

const fmtAgo = (s) => s < 1 ? "now" : s < 60 ? `${Math.round(s)} s ago` : `${Math.floor(s / 60)} min ${Math.round(s % 60)} s ago`;

function drawPlots() {
  const hostT = $("plot-temp"), hostD = $("plot-fan");
  const w = Math.max(280, Math.round(hostT.clientWidth || 600));
  const h = ctl.hist;
  const t1 = h.length ? h[h.length - 1][0] : 0;
  const t0 = t1 - ctl.span;
  const x0 = 38, x1 = w - 8;
  ctl.geom = { w, x0, x1, t1 };
  const X = (t) => x0 + (t - t0) / ctl.span * (x1 - x0);
  const pts = h.filter((p) => p[0] >= t0);

  // temperature: span at least 3 C so sensor noise looks like noise
  const vals = pts.flatMap((p) => [p[1], p[2]]).filter((v) => v != null);
  const sp = ctl.last && ctl.last.mode === "auto" ? ctl.last.setpoint : null;
  if (sp != null) vals.push(sp);
  let lo = vals.length ? Math.min(...vals) : 40, hi = vals.length ? Math.max(...vals) : 44;
  if (hi - lo < 3) { const m = (hi + lo) / 2; lo = m - 1.5; hi = m + 1.5; }
  const step = hi - lo > 12 ? 5 : hi - lo > 6 ? 2 : hi - lo > 3 ? 1 : 0.5;
  lo = Math.floor(lo / step) * step; hi = Math.ceil(hi / step) * step;
  hostT.innerHTML = plotSvg({
    w, hgt: 170, x0, x1, X, t0, pts, lo, hi, step, key: 1, cls: "line-temp", dot: "dot-temp",
    fmt: (v) => (step < 1 ? v.toFixed(1) : String(v)),
    extra: (Y) => {
      if (sp == null) return "";
      const band = ctl.last.settle_band || 0.3;
      return `<rect class="band" x="${x0}" y="${Y(sp + band).toFixed(1)}" width="${x1 - x0}" height="${(Y(sp - band) - Y(sp + band)).toFixed(1)}"/>` +
        `<line class="sp" x1="${x0}" x2="${x1}" y1="${Y(sp).toFixed(1)}" y2="${Y(sp).toFixed(1)}"/>` +
        `<text class="sp-label" x="${x1 - 4}" y="${(Y(sp) - 5).toFixed(1)}" text-anchor="end">setpoint ${sp.toFixed(1)} °C</text>`;
    },
  });
  const floor = (ctl.last && ctl.last.rpm_min) || 1500;
  hostD.innerHTML = plotSvg({
    w, hgt: 96, x0, x1, X, t0, pts, lo: 0, hi: 6500, ticks: [0, 3000, 6000], key: 3, cls: "line-duty", dot: "dot-duty",
    fmt: String, xAxis: true,
    extra: (Y) => `<line class="floor" x1="${x0}" x2="${x1}" y1="${Y(floor)}" y2="${Y(floor)}"/>` +
      `<text class="sp-label" x="${x1 - 4}" y="${Y(floor) - 4}" text-anchor="end">min ${floor}</text>`,
  });
  const tip = $("plot-tip");
  const p = ctl.hover;
  if (!p) { tip.hidden = true; return; }
  tip.hidden = false;
  tip.innerHTML = `${fmtAgo(t1 - p[0])}<br>hottest <b>${p[1] == null ? "-" : p[1].toFixed(2) + " °C"}</b>` +
    (p[2] != null ? `<br>setpoint <b>${p[2].toFixed(1)} °C</b>` : "") +
    `<br>fan target <b>${p[3] == null ? "-" : p[3] + " rpm"}</b>${p[4] != null ? " · measured " + p[4] : ""}`;
  const fig = hostT.parentElement.getBoundingClientRect();
  const px = X(p[0]) / w * hostT.getBoundingClientRect().width;
  const tw = tip.offsetWidth;
  tip.style.left = Math.max(0, Math.min(fig.width - tw, px + (px > fig.width / 2 ? -tw - 12 : 12))) + "px";
}

function plotSvg(o) {
  const top = 6, bottom = o.hgt - (o.xAxis ? 20 : 6);
  const Y = (v) => bottom - (v - o.lo) / (o.hi - o.lo) * (bottom - top);
  let out = `<svg viewBox="0 0 ${o.w} ${o.hgt}" width="${o.w}" height="${o.hgt}" aria-hidden="true">`;
  const ticks = o.ticks || [];
  if (!o.ticks) for (let v = o.lo; v <= o.hi + 1e-9; v += o.step) ticks.push(+v.toFixed(2));
  for (const v of ticks) {
    out += `<line class="grid" x1="${o.x0}" x2="${o.x1}" y1="${Y(v).toFixed(1)}" y2="${Y(v).toFixed(1)}"/>` +
      `<text class="axis" x="${o.x0 - 6}" y="${(Y(v) + 4).toFixed(1)}" text-anchor="end">${o.fmt(v)}</text>`;
  }
  const every = o.w < 520 ? 5 : 2;          // minutes between time ticks
  for (let m = 0; m <= ctl.span / 60; m += every) {
    const x = o.X(o.t0 + ctl.span - m * 60);
    out += `<line class="grid" x1="${x.toFixed(1)}" x2="${x.toFixed(1)}" y1="${top}" y2="${bottom}"/>`;
    if (o.xAxis) {
      const anchor = m === 0 ? "end" : m >= ctl.span / 60 ? "start" : "middle";
      out += `<text class="axis" x="${x.toFixed(1)}" y="${o.hgt - 5}" text-anchor="${anchor}">${m === 0 ? "now" : "−" + m + " min"}</text>`;
    }
  }
  out += o.extra(Y);
  // the line, broken where samples are missing (a controller restart, a gap)
  let d = "", prev = null;
  for (const p of o.pts) {
    const v = p[o.key];
    if (v == null) { prev = null; continue; }
    const cmd = prev && p[0] - prev[0] <= GAP_S ? "L" : "M";
    d += `${cmd}${o.X(p[0]).toFixed(1)} ${Y(Math.max(o.lo, Math.min(o.hi, v))).toFixed(1)}`;
    prev = p;
  }
  if (d) out += `<path class="${o.cls}" d="${d}"/>`;
  else out += `<text class="empty" x="${(o.x0 + o.x1) / 2}" y="${(top + bottom) / 2}" text-anchor="middle">waiting for samples</text>`;
  const hv = ctl.hover;
  if (hv && hv[o.key] != null) {
    const x = o.X(hv[0]).toFixed(1);
    out += `<line class="cross" x1="${x}" x2="${x}" y1="${top}" y2="${bottom}"/>` +
      `<circle class="${o.dot}" cx="${x}" cy="${Y(hv[o.key]).toFixed(1)}" r="4.5"/>`;
  }
  return out + "</svg>";
}

// ---------------------------------------------------------------- oscilloscope
// The FPGA's scope (fpga/scope_block.vhd, fpga_scope's scope_capture): eight
// channels, each any of the sources the FPGA names (its test generator, then
// the probes). POST /api/scope/capture arms when the settings change and
// waits 20 ms for the trigger; this asks again until a capture comes. One
// strip per channel on one time axis (t = 0 at the trigger): each channel has
// its own scale, so they are small multiples, not one shared y-axis. Digital
// sources draw as stacked bit lanes.
const SCOPE_DIVIDERS = [0, 1, 4, 9, 24, 49, 99, 249, 499, 999, 2499, 4999, 9999, 24999, 49999, 99999];
const SCOPE_LENGTHS = [256, 512, 1024, 2048, 4096];
const SCOPE_AUTO_MS = 250;       // auto mode: force a capture after this long without a trigger
const SCOPE_CH = 8;
const STRIP_H = 64, LANE_H = 16, STRIP_GAP = 8, AXIS_H = 22, LABEL_W = 116;
const scope = {
  info: null, running: false, single: false, force: false, armedAt: 0, busy: false,
  cap: null, view: null, hover: null,
};

function fmtRate(hz) {
  if (hz >= 1e6) return `${+(hz / 1e6).toFixed(3)} MS/s`;
  if (hz >= 1e3) return `${+(hz / 1e3).toFixed(3)} kS/s`;
  return `${+hz.toFixed(3)} S/s`;
}
function fmtTime(s) {
  const a = Math.abs(s);
  if (a === 0) return "0";
  if (a < 1e-6) return `${+(s * 1e9).toFixed(0)} ns`;
  if (a < 1e-3) return `${+(s * 1e6).toFixed(a < 1e-5 ? 2 : 1)} µs`;
  if (a < 1) return `${+(s * 1e3).toFixed(a < 1e-2 ? 2 : 1)} ms`;
  return `${+s.toFixed(3)} s`;
}
const chColor = (c) => getComputedStyle(document.documentElement).getPropertyValue(`--ch${c + 1}`).trim();
const cssVar = (n) => getComputedStyle(document.documentElement).getPropertyValue(n).trim();

async function initScope() {
  let info;
  try { info = await api("/api/scope"); } catch (e) { return; }   // no scope in this core
  scope.info = info;
  $("scope-card").hidden = false;
  $("scope-sub").textContent = `${info.channels} channels, ${info.depth} samples, ${fmtRate(info.clock_hz)} max` +
    (info.sim ? " (simulated)" : "");
  $("scope-rate").innerHTML = SCOPE_DIVIDERS.map((d) => `<option value="${d}">${fmtRate(info.clock_hz / (d + 1))}</option>`).join("");
  $("scope-rate").value = "49";
  $("scope-length").innerHTML = SCOPE_LENGTHS.filter((n) => n <= info.depth).map((n) => `<option>${n}</option>`).join("");
  $("scope-length").value = String(Math.min(1024, info.depth));
  const tch = $("scope-tch"), chs = $("scope-chs");
  for (let c = 0; c < SCOPE_CH; c++) {
    tch.add(new Option(`CH${c + 1}`, c));
    const row = document.createElement("label");
    row.className = "scope-ch";
    const key = document.createElement("span");
    key.className = "scope-key";
    key.style.background = `var(--ch${c + 1})`;
    const name = document.createElement("span");
    name.textContent = `CH${c + 1}`;
    const sel = document.createElement("select");
    sel.id = `scope-src${c}`;
    sel.add(new Option("off", "-1"));
    info.sources.forEach((s, i) => sel.add(new Option(s.name + (s.format === "digital" ? " (bits)" : ""), i)));
    sel.value = String(c < info.sources.length ? c : -1);
    row.append(key, name, sel);
    chs.append(row);
  }
  // a start that shows something: the test generator, the fan and the switches
  const pick = (name) => info.sources.findIndex((s) => s.name === name);
  [pick("sine"), pick("square"), pick("triangle"), pick("counter"), pick("fan rpm"), pick("switches"),
   pick("LEDR0 level"), pick("fan i2c")].forEach((v, c) => { if (v >= 0) $(`scope-src${c}`).value = String(v); });
  loadScopeSettings();
  $("scope-run").onclick = () => scopeStart(false);
  $("scope-single").onclick = () => scopeStart(true);
  $("scope-stop").onclick = scopeStop;
  $("scope-force").onclick = () => { scope.force = true; if (!scope.running) scopeStart(true); };
  $("scope-csv").onclick = scopeCsv;
  $("scope-edge").onchange = scopeEdgeShown;
  $("scope-card").addEventListener("change", saveScopeSettings);
  scopeEdgeShown();
  const canvas = $("scope-canvas");
  canvas.addEventListener("pointermove", (e) => scopeHover(e));
  canvas.addEventListener("pointerleave", () => { scope.hover = null; $("scope-tip").hidden = true; drawScope(); });
  window.addEventListener("resize", drawScope);
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", drawScope);
  drawScope();
  initStream(info);
  initLogger();
}

function scopeEdgeShown() {
  const pattern = $("scope-edge").value === "pattern";
  $("scope-pattern-l").hidden = !pattern;
  $("scope-level-l").hidden = pattern;
}

const SCOPE_KEYS = ["scope-rate", "scope-length", "scope-pre", "scope-mode", "scope-tch", "scope-edge",
  "scope-level", "scope-pattern", "scope-mask", "scope-gen"];
function saveScopeSettings() {
  const o = {};
  for (const k of SCOPE_KEYS) o[k] = $(k).value;
  for (let c = 0; c < SCOPE_CH; c++) o[`scope-src${c}`] = $(`scope-src${c}`).value;
  localStorage.setItem("de25-scope", JSON.stringify(o));
}
function loadScopeSettings() {
  let o = null;
  try { o = JSON.parse(localStorage.getItem("de25-scope")); } catch (e) { /* none */ }
  if (!o) return;
  for (const [k, v] of Object.entries(o)) {
    const el = $(k);
    if (el && [...(el.options || [])].some((op) => op.value === v) || el && !el.options) el.value = v;
  }
}

function scopeSettings() {
  const num = (id) => parseInt($(id).value, 0) || 0;
  const sources = [];
  for (let c = 0; c < SCOPE_CH; c++) sources.push(Math.max(0, +$(`scope-src${c}`).value));
  const ch = +$("scope-tch").value;
  const src = scope.info.sources[sources[ch]] || {};
  return {
    divider: +$("scope-rate").value,
    length: +$("scope-length").value,
    pre_percent: Math.max(0, Math.min(100, +$("scope-pre").value || 0)),
    trigger: $("scope-mode").value !== "free",
    channel: ch,
    edge: $("scope-edge").value,
    level: Math.round(+$("scope-level").value || 0),
    unsigned: src.format === "unsigned" || src.format === "digital",
    pattern: num("scope-pattern") & 0xffff,
    mask: num("scope-mask") & 0xffff,
    sources,
    generator_hz: Math.max(0, +$("scope-gen").value || 0),
  };
}

function setScopeStatus(kind, text) {
  const el = $("scope-status");
  el.className = "pill pill-" + kind;
  el.textContent = text;
}

function scopeStart(single) {
  scope.single = single;
  $("scope-run").setAttribute("aria-pressed", String(!single));
  $("scope-single").setAttribute("aria-pressed", String(single));
  scope.armedAt = performance.now();
  if (!scope.running) {
    scope.running = true;
    scopeLoop();
  }
}

async function scopeStop() {
  scope.running = false;
  $("scope-run").setAttribute("aria-pressed", "false");
  $("scope-single").setAttribute("aria-pressed", "false");
  setScopeStatus("wait", "stopped");
  try { await api("/api/scope/stop", {}); } catch (e) { /* the next run arms again */ }
}

async function scopeLoop() {
  while (scope.running) {
    const settings = scopeSettings();
    let force = scope.force;
    if (!force && $("scope-mode").value === "auto" && performance.now() - scope.armedAt > SCOPE_AUTO_MS) force = true;
    scope.force = false;
    let r;
    try {
      r = await api("/api/scope/capture", { settings, force });
    } catch (e) {
      setScopeStatus("bad", "error");
      $("scope-msg").textContent = e.message;
      await new Promise((ok) => setTimeout(ok, 1000));
      continue;
    }
    if (!scope.running) break;       // stopped while this request was out: drop its answer
    if (!r.done) {
      setScopeStatus("wait", force ? "forcing" : "waiting for trigger");
      continue;
    }
    scope.armedAt = performance.now();
    scopeTake(r, settings);
    setScopeStatus(r.forced ? "warn" : "ok", r.forced ? "forced" : settings.trigger ? "triggered" : "free running");
    if (scope.single) {
      scope.running = false;
      $("scope-single").setAttribute("aria-pressed", "false");
    } else {
      await new Promise((ok) => setTimeout(ok, 30));
    }
  }
}

// the reply's int16 samples, 8 channels interleaved, into one array per channel
function scopeTake(r, settings) {
  const bytes = Uint8Array.from(atob(r.data), (ch) => ch.charCodeAt(0));
  const all = new Int16Array(bytes.buffer);
  const n = r.length, rate = scope.info.clock_hz / (settings.divider + 1);
  const chans = [];
  for (let c = 0; c < SCOPE_CH; c++) {
    const on = +$(`scope-src${c}`).value >= 0;
    const src = scope.info.sources[settings.sources[c]] || { name: "?", format: "signed" };
    const v = new Float64Array(n);
    for (let s = 0; s < n; s++) {
      const x = all[s * SCOPE_CH + c];
      v[s] = src.format === "signed" ? x : x & 0xffff;
    }
    chans.push({ on, src, v, lanes: src.format === "digital" ? scopeLanes(v) : 0 });
  }
  scope.cap = { n, pre: r.pre, rate, chans, settings, forced: r.forced, captures: r.captures };
  $("scope-csv").disabled = false;
  $("scope-msg").textContent = `${n} samples at ${fmtRate(rate)} = ${fmtTime(n / rate)}` +
    (r.forced ? ", forced (no trigger)" : "") + `; capture ${r.captures}`;
  drawScope();
}

// a digital source shows the lanes up to the highest bit that is ever set
function scopeLanes(v) {
  let any = 0;
  for (const x of v) any |= x;
  let lanes = 1;
  while (any >> lanes) lanes++;
  return lanes;
}

// the strips: [{c, y, h}] top to bottom, and the canvas height
function scopeLayout() {
  const out = [];
  let y = 6;
  const cap = scope.cap;
  for (let c = 0; c < SCOPE_CH; c++) {
    const on = cap ? cap.chans[c].on : +$(`scope-src${c}`).value >= 0;
    if (!on) continue;
    const lanes = cap ? cap.chans[c].lanes : 0;
    const h = lanes ? Math.max(STRIP_H / 2, lanes * LANE_H) : STRIP_H;
    out.push({ c, y, h });
    y += h + STRIP_GAP;
  }
  return { strips: out, height: y + AXIS_H };
}

function drawScope() {
  const canvas = $("scope-canvas");
  if (!scope.info || !canvas) return;
  const { strips, height } = scopeLayout();
  const w = canvas.clientWidth || 600, dpr = window.devicePixelRatio || 1;
  canvas.style.height = height + "px";
  canvas.width = Math.round(w * dpr);
  canvas.height = Math.round(height * dpr);
  const g = canvas.getContext("2d");
  g.setTransform(dpr, 0, 0, dpr, 0, 0);
  g.clearRect(0, 0, w, height);
  const text = cssVar("--text"), muted = cssVar("--muted"), grid = cssVar("--grid"), line = cssVar("--line");
  const x0 = LABEL_W, x1 = w - 8, cap = scope.cap;
  scope.view = { x0, x1, strips };
  g.font = "12px system-ui, sans-serif";
  if (!cap) {
    g.fillStyle = muted;
    g.textAlign = "center";
    g.fillText("Press Run or Single for a capture", (x0 + x1) / 2, height / 2);
    return;
  }
  const n = cap.n, X = (s) => x0 + (s / Math.max(1, n - 1)) * (x1 - x0);
  // time grid: about every 90 px, at round time steps, t = 0 at the trigger
  const span = (n - 1) / cap.rate, raw = span / Math.max(1, (x1 - x0) / 90);
  const p10 = Math.pow(10, Math.floor(Math.log10(raw)));
  const step = [1, 2, 5, 10].map((m) => m * p10).find((v) => v >= raw);
  const tStart = -cap.pre / cap.rate, tEnd = tStart + span;
  const bottom = height - AXIS_H;
  g.strokeStyle = grid;
  g.lineWidth = 1;
  g.fillStyle = muted;
  g.textAlign = "center";
  for (let t = Math.ceil(tStart / step) * step; t <= tEnd + 1e-12; t += step) {
    const x = X((t - tStart) * cap.rate);
    g.beginPath(); g.moveTo(x + 0.5, 0); g.lineTo(x + 0.5, bottom); g.stroke();
    g.fillText(fmtTime(Math.abs(t) < step / 1e6 ? 0 : t), x, bottom + 15);
  }
  // the trigger: t = 0
  const xt = X(cap.pre);
  g.strokeStyle = muted;
  g.setLineDash([4, 3]);
  g.beginPath(); g.moveTo(xt + 0.5, 0); g.lineTo(xt + 0.5, bottom); g.stroke();
  g.setLineDash([]);
  for (const st of strips) {
    const ch = cap.chans[st.c], color = chColor(st.c);
    g.strokeStyle = line;
    g.beginPath(); g.moveTo(x0, st.y + st.h + 0.5); g.lineTo(x1, st.y + st.h + 0.5); g.stroke();
    // label: the key, the channel and its source (text in text colours)
    g.strokeStyle = color; g.lineWidth = 2;
    g.beginPath(); g.moveTo(4, st.y + 9); g.lineTo(18, st.y + 9); g.stroke();
    g.lineWidth = 1;
    g.fillStyle = text; g.textAlign = "left";
    g.fillText(`CH${st.c + 1}`, 24, st.y + 13);
    g.fillStyle = muted;
    g.fillText(ch.src.name.slice(0, 14), 4, st.y + 28);
    if (ch.lanes) drawLanes(g, ch, st, X, color, muted);
    else drawTrace(g, ch, st, X, color, muted, cap, st.c);
  }
  if (scope.hover != null) {
    const x = X(scope.hover);
    g.strokeStyle = text; g.globalAlpha = 0.6;
    g.beginPath(); g.moveTo(x + 0.5, 0); g.lineTo(x + 0.5, bottom); g.stroke();
    g.globalAlpha = 1;
  }
}

// an analog strip: auto range, min/max per pixel column when samples outnumber pixels
function drawTrace(g, ch, st, X, color, muted, cap, c) {
  let lo = Infinity, hi = -Infinity;
  for (const x of ch.v) { if (x < lo) lo = x; if (x > hi) hi = x; }
  if (hi - lo < 2) { lo -= 1; hi += 1; }
  const pad = (hi - lo) * 0.08, top = st.y + 3, bot = st.y + st.h - 3;
  const Y = (v) => bot - ((v - (lo - pad)) / (hi - lo + 2 * pad)) * (bot - top);
  ch.range = [lo, hi];
  g.fillStyle = muted; g.textAlign = "right";
  g.fillText(String(hi), LABEL_W - 6, top + 9);
  g.fillText(String(lo), LABEL_W - 6, bot);
  // the trigger level on the trigger channel
  const s = cap.settings;
  if (s.trigger && s.channel === c && s.edge !== "pattern" && s.level >= lo - pad && s.level <= hi + pad) {
    const y = Y(s.level);
    g.strokeStyle = color; g.globalAlpha = 0.5; g.setLineDash([2, 3]);
    g.beginPath(); g.moveTo(LABEL_W, y); g.lineTo(X(cap.n - 1), y); g.stroke();
    g.setLineDash([]); g.globalAlpha = 1;
  }
  g.strokeStyle = color; g.lineWidth = 2; g.lineJoin = "round";
  g.beginPath();
  const n = ch.v.length, cols = X(n - 1) - X(0);
  if (n > cols * 2) {
    const per = n / cols;
    for (let px = 0; px < cols; px++) {
      let a = Infinity, b = -Infinity;
      for (let i = Math.floor(px * per); i < Math.min(n, Math.floor((px + 1) * per)); i++) {
        const v = ch.v[i]; if (v < a) a = v; if (v > b) b = v;
      }
      const x = X(0) + px;
      if (px === 0) g.moveTo(x, Y(a)); else g.lineTo(x, Y(a));
      g.lineTo(x, Y(b));
    }
  } else {
    for (let i = 0; i < n; i++) { if (i) g.lineTo(X(i), Y(ch.v[i])); else g.moveTo(X(i), Y(ch.v[i])); }
  }
  g.stroke();
  g.lineWidth = 1;
}

// a digital strip: one lane per bit (b0 on top), high = up, the high
// stretches filled lightly so a 1 reads at a glance
function drawLanes(g, ch, st, X, color, muted) {
  const lh = st.h / ch.lanes, x1 = X(ch.v.length - 1);
  g.textAlign = "right";
  for (let b = 0; b < ch.lanes; b++) {
    const yHi = st.y + b * lh + 2, yLo = st.y + (b + 1) * lh - 2;
    if (b) {
      g.strokeStyle = cssVar("--grid"); g.lineWidth = 1;
      g.beginPath(); g.moveTo(LABEL_W, st.y + b * lh + 0.5); g.lineTo(x1, st.y + b * lh + 0.5); g.stroke();
    }
    g.fillStyle = muted;
    if (lh >= 10) g.fillText("b" + b, LABEL_W - 6, st.y + (b + 0.5) * lh + 4);
    // the runs of 1s, filled
    g.fillStyle = color; g.globalAlpha = 0.16;
    let start = null;
    for (let i = 0; i <= ch.v.length; i++) {
      const bit = i < ch.v.length ? (ch.v[i] >> b) & 1 : 0;
      if (bit && start === null) start = i;
      if (!bit && start !== null) { g.fillRect(X(start), yHi, X(i - 1) - X(start) || 1, yLo - yHi); start = null; }
    }
    g.globalAlpha = 1;
    g.strokeStyle = color; g.lineWidth = 1.5;
    g.beginPath();
    let prev = null;
    for (let i = 0; i < ch.v.length; i++) {
      const bit = (ch.v[i] >> b) & 1, y = bit ? yHi : yLo;
      if (prev === null) g.moveTo(X(i), y);
      else if (bit !== prev) { g.lineTo(X(i), prev ? yHi : yLo); g.lineTo(X(i), y); }
      prev = bit;
    }
    g.lineTo(x1, prev ? yHi : yLo);
    g.stroke();
  }
  g.lineWidth = 1;
}

// the crosshair snaps to the nearest sample; the tooltip lists every channel there
function scopeHover(e) {
  const cap = scope.cap, v = scope.view;
  if (!cap || !v) return;
  const rect = $("scope-canvas").getBoundingClientRect();
  const x = e.clientX - rect.left;
  if (x < v.x0 || x > v.x1) { scope.hover = null; $("scope-tip").hidden = true; drawScope(); return; }
  const s = Math.round(((x - v.x0) / (v.x1 - v.x0)) * (cap.n - 1));
  scope.hover = s;
  drawScope();
  const tip = $("scope-tip");
  tip.replaceChildren();
  const t = document.createElement("div");
  t.className = "t";
  t.textContent = `t = ${fmtTime((s - cap.pre) / cap.rate)} (sample ${s})`;
  tip.append(t);
  for (const st of v.strips) {
    const ch = cap.chans[st.c], val = ch.v[s];
    const row = document.createElement("div");
    row.className = "row";
    const key = document.createElement("i");
    key.className = "scope-key";
    key.style.background = `var(--ch${st.c + 1})`;
    const b = document.createElement("b");
    b.textContent = ch.lanes ? "0b" + (val >>> 0).toString(2).padStart(ch.lanes, "0") : String(val);
    const name = document.createElement("span");
    name.textContent = `CH${st.c + 1} ${ch.src.name}`;
    row.append(key, b, name);
    tip.append(row);
  }
  tip.hidden = false;
  const host = $("scope-plot").getBoundingClientRect();
  const left = x + 14 + tip.offsetWidth > host.width ? x - 14 - tip.offsetWidth : x + 14;
  tip.style.left = Math.max(0, left) + "px";
  tip.style.top = Math.max(0, e.clientY - host.top - 20) + "px";
}

// the capture as a table: time, then one column per channel shown
function scopeCsv() {
  const cap = scope.cap;
  if (!cap) return;
  const shown = cap.chans.map((ch, c) => ({ ch, c })).filter((x) => x.ch.on);
  const rows = ["time_s," + shown.map((x) => `CH${x.c + 1} ${x.ch.src.name}`.replace(/,/g, " ")).join(",")];
  for (let s = 0; s < cap.n; s++) {
    rows.push(((s - cap.pre) / cap.rate).toExponential(6) + "," + shown.map((x) => x.ch.v[s]).join(","));
  }
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob([rows.join("\n") + "\n"], { type: "text/csv" }));
  a.download = `de25-scope-${new Date().toISOString().replace(/[:.]/g, "-")}.csv`;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

// ---------------------------------------------------------------- start
buildControl();
drawPlots();
buildPanels();
buildLedBar();
loadBoard().then(connect);
// ---------------------------------------------------------------- stream
// The scope's continuous capture through the DDR ring, a WebSocket on the board's
// port 5004 (fpga_access.py StreamServer), read in stream_worker.js. Each channel's
// minimum and maximum per millisecond, the last 60 s kept, drawn as a band.
const STREAM_DIVIDERS = [4, 5, 6, 7, 9, 12, 19, 24, 49, 99, 249, 499, 999, 4999];
const STREAM_POINTS = 60000;
const STREAM_RECORD_MAX = 1 << 30;
const stream = {
  worker: null, on: false, settings: null, pts: null, count: 0, bytes: 0, samples: 0,
  t0: 0, raw: [], rawBytes: 0, rawFull: false, drawPending: false, timer: null,
};

function initStream(info) {
  if (!info.stream) return;                   // no stream server on this board
  $("stream-card").hidden = false;
  $("stream-rate").innerHTML = STREAM_DIVIDERS.map((d) => {
    const hz = info.clock_hz / (d + 1);
    return `<option value="${d}">${fmtRate(hz)}, ${+(hz * 16 / 1e6).toFixed(1)} MB/s</option>`;
  }).join("");
  $("stream-rate").value = localStorage.getItem("de25-stream-rate") || "49";
  if (!$("stream-rate").value) $("stream-rate").value = "49";
  $("stream-rate").onchange = () => localStorage.setItem("de25-stream-rate", $("stream-rate").value);
  $("stream-start").onclick = streamStart;
  $("stream-stop").onclick = streamStop;
  $("stream-save").onclick = streamSave;
  $("stream-window").onchange = drawStream;
  $("stream-record").onchange = () => {
    if (stream.worker) stream.worker.postMessage({ type: "raw", on: $("stream-record").checked });
  };
  window.addEventListener("resize", drawStream);
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", drawStream);
  drawStream();
}

function setStreamStatus(kind, text) {
  const el = $("stream-status");
  el.className = "pill pill-" + kind;
  el.textContent = text;
}

async function streamStart() {
  if (stream.on) return;
  if (scope.running) await scopeStop();
  const s = scopeSettings(), info = scope.info;
  const divider = +$("stream-rate").value, rate = info.clock_hz / (divider + 1);
  const chans = s.sources.map((src, c) => {
    const p = info.sources[src] || { name: "?", format: "signed" };
    return { on: +$(`scope-src${c}`).value >= 0, name: p.name, format: p.format };
  });
  stream.settings = { divider, rate, chans, pps: Math.min(1000, rate) };
  stream.pts = chans.map(() => ({ min: new Float32Array(STREAM_POINTS), max: new Float32Array(STREAM_POINTS) }));
  Object.assign(stream, { count: 0, bytes: 0, samples: 0, raw: [], rawBytes: 0, rawFull: false });
  $("stream-save").disabled = true;
  const host = location.hostname.includes(":") ? `[${location.hostname}]` : location.hostname;
  const url = `ws://${host}:${info.stream.port}/stream?divider=${divider}` +
    `&sources=${s.sources.join(",")}&generator_hz=${s.generator_hz}`;
  const w = new Worker("/static/stream_worker.js");
  stream.worker = w;
  w.onmessage = (e) => streamMessage(e.data);
  w.onerror = (e) => {
    $("stream-msg").textContent = `the stream's worker: ${e.message || "failed"}`;
    streamMessage({ type: "closed", code: 1006, reason: e.message || "worker failed" });
  };
  w.postMessage({ type: "raw", on: $("stream-record").checked });
  w.postMessage({ type: "start", url, rate, unsigned: chans.map((c) => c.format !== "signed") });
  stream.on = true;
  stream.t0 = performance.now();
  $("stream-start").setAttribute("aria-pressed", "true");
  setStreamStatus("wait", "connecting");
  $("stream-msg").textContent = "";
  stream.timer = setInterval(streamStats, 500);
}

function streamStop() {
  if (stream.worker) stream.worker.postMessage({ type: "stop" });
}

function streamMessage(m) {
  if (m.type === "open") {
    setStreamStatus("ok", "streaming");
    stream.t0 = performance.now();
  } else if (m.type === "points") {
    const v = m.values, pts = stream.pts;
    for (let i = 0; i < m.count; i++) {
      const at = (stream.count + i) % STREAM_POINTS;
      for (let c = 0; c < SCOPE_CH; c++) {
        pts[c].min[at] = v[i * 16 + 2 * c];
        pts[c].max[at] = v[i * 16 + 2 * c + 1];
      }
    }
    stream.count += m.count;
    stream.bytes = m.bytes;
    stream.samples = m.samples;
    if (!stream.drawPending) {
      stream.drawPending = true;
      requestAnimationFrame(() => { stream.drawPending = false; drawStream(); });
    }
  } else if (m.type === "raw") {
    if (stream.rawBytes + m.buffer.byteLength <= STREAM_RECORD_MAX) {
      stream.raw.push(m.buffer);
      stream.rawBytes += m.buffer.byteLength;
    } else if (!stream.rawFull) {
      stream.rawFull = true;
      stream.worker.postMessage({ type: "raw", on: false });
    }
  } else if (m.type === "closed") {
    stream.on = false;
    stream.worker.terminate();
    stream.worker = null;
    clearInterval(stream.timer);
    streamStats();
    $("stream-start").setAttribute("aria-pressed", "false");
    $("stream-save").disabled = stream.rawBytes === 0;
    const clean = m.code === 1000;
    setStreamStatus(clean ? "wait" : "bad", clean ? "stopped" : "ended");
    if (!clean) {
      $("stream-msg").textContent += ` - ${m.reason || "the connection closed (" + m.code + ")"}`;
    }
  }
}

function streamStats() {
  const secs = Math.max(1e-3, (performance.now() - stream.t0) / 1000);
  let t = `${(stream.bytes / secs / 1e6).toFixed(1)} MB/s received, ${stream.samples.toLocaleString()} samples in ${secs.toFixed(1)} s`;
  if (stream.rawBytes) t += `; ${(stream.rawBytes / 1e6).toFixed(0)} MB recorded` + (stream.rawFull ? " (full)" : "");
  $("stream-msg").textContent = t;
}

function streamSave() {
  const st = stream.settings;
  const blob = new Blob(stream.raw, { type: "application/octet-stream" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  // int16 little-endian, 8 channels interleaved
  a.download = `de25_stream_${Math.round(st.rate)}Sps_${st.chans.map((c) => c.name.replace(/\W+/g, "-")).join("_")}.i16`;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 10000);
}

function drawStream() {
  const canvas = $("stream-canvas");
  if (!canvas || !scope.info) return;
  const st = stream.settings;
  const strips = [];
  let y = 6;
  for (let c = 0; c < SCOPE_CH; c++) {
    const on = st ? st.chans[c].on : +$(`scope-src${c}`).value >= 0;
    if (!on) continue;
    strips.push({ c, y, h: STRIP_H });
    y += STRIP_H + STRIP_GAP;
  }
  const height = y + AXIS_H;
  const w = canvas.clientWidth || 600, dpr = window.devicePixelRatio || 1;
  canvas.style.height = height + "px";
  canvas.width = Math.round(w * dpr);
  canvas.height = Math.round(height * dpr);
  const g = canvas.getContext("2d");
  g.setTransform(dpr, 0, 0, dpr, 0, 0);
  g.clearRect(0, 0, w, height);
  const text = cssVar("--text"), muted = cssVar("--muted"), grid = cssVar("--grid"), line = cssVar("--line");
  const x0 = LABEL_W, x1 = w - 8, bottom = height - AXIS_H;
  g.font = "12px system-ui, sans-serif";
  if (!st || stream.count === 0) {
    g.fillStyle = muted;
    g.textAlign = "center";
    g.fillText(stream.on ? "Waiting for data" : "Press Start to stream", (x0 + x1) / 2, height / 2);
    return;
  }
  const win = +$("stream-window").value, wp = Math.min(STREAM_POINTS, Math.round(win * st.pps));
  const newest = stream.count - 1, oldest = Math.max(0, stream.count - wp, stream.count - STREAM_POINTS);
  const X = (j) => x1 - ((newest - j) / Math.max(1, wp - 1)) * (x1 - x0);
  // time grid: seconds before now
  const step = [0.1, 0.2, 0.5, 1, 2, 5, 10, 20].find((v) => v >= win / Math.max(1, (x1 - x0) / 90)) || 20;
  g.strokeStyle = grid; g.lineWidth = 1; g.fillStyle = muted; g.textAlign = "center";
  for (let t = 0; t <= win + 1e-9; t += step) {
    const x = x1 - (t / win) * (x1 - x0);
    g.beginPath(); g.moveTo(x + 0.5, 0); g.lineTo(x + 0.5, bottom); g.stroke();
    g.textAlign = t === 0 ? "right" : "center";
    g.fillText(t === 0 ? "now" : `-${+t.toFixed(1)} s`, x, bottom + 15);
  }
  const cols = Math.max(1, Math.round(x1 - x0));
  for (const s of strips) {
    const p = stream.pts[s.c], color = chColor(s.c), ch = st.chans[s.c];
    g.strokeStyle = line;
    g.beginPath(); g.moveTo(x0, s.y + s.h + 0.5); g.lineTo(x1, s.y + s.h + 0.5); g.stroke();
    g.strokeStyle = color; g.lineWidth = 2;
    g.beginPath(); g.moveTo(4, s.y + 9); g.lineTo(18, s.y + 9); g.stroke();
    g.lineWidth = 1;
    g.fillStyle = text; g.textAlign = "left";
    g.fillText(`CH${s.c + 1}`, 24, s.y + 13);
    g.fillStyle = muted;
    g.fillText(ch.name.slice(0, 14), 4, s.y + 28);
    // each pixel column's points into one min/max
    const lo = new Float32Array(cols).fill(Infinity), hi = new Float32Array(cols).fill(-Infinity);
    let vlo = Infinity, vhi = -Infinity;
    for (let j = oldest; j <= newest; j++) {
      const k = Math.min(cols - 1, Math.max(0, Math.round(X(j) - x0)));
      const at = j % STREAM_POINTS, a = p.min[at], b = p.max[at];
      if (a < lo[k]) lo[k] = a;
      if (b > hi[k]) hi[k] = b;
      if (a < vlo) vlo = a;
      if (b > vhi) vhi = b;
    }
    if (vhi - vlo < 2) { vlo -= 1; vhi += 1; }
    const pad = (vhi - vlo) * 0.08, top = s.y + 3, bot = s.y + s.h - 3;
    const Y = (v) => bot - ((v - (vlo - pad)) / (vhi - vlo + 2 * pad)) * (bot - top);
    g.fillStyle = muted; g.textAlign = "right";
    g.fillText(String(vhi), LABEL_W - 6, top + 9);
    g.fillText(String(vlo), LABEL_W - 6, bot);
    g.fillStyle = color;
    for (let k = 0; k < cols; k++) {
      if (hi[k] < lo[k]) continue;
      const ya = Y(hi[k]), yb = Y(lo[k]);
      g.fillRect(x0 + k, ya, 1, Math.max(1.5, yb - ya));
    }
  }
}

// ---------------------------------------------------------------- data logger
// fpga_access.py logs points (each channel's minimum, maximum and mean over n
// samples, fpga/scope_decimator.vhd) to the board's card; this starts and
// stops it and lists the files (GET /api/logs).
const LOG_RATES = [0.1, 1, 10, 100, 1000, 10000, 100000];
const LOG_POINT_BYTES = 64;
const logger = { timer: null, last: null, error: "" };

function fmtBytes(b) {
  if (b >= 1e9) return `${(b / 1e9).toFixed(2)} GB`;
  if (b >= 1e6) return `${(b / 1e6).toFixed(1)} MB`;
  if (b >= 1e3) return `${(b / 1e3).toFixed(0)} kB`;
  return `${b} B`;
}
function fmtDuration(s) {
  if (s < 60) return `${s.toFixed(s < 10 ? 1 : 0)} s`;
  if (s < 3600) return `${Math.floor(s / 60)} min ${Math.round(s % 60)} s`;
  if (s < 86400) return `${Math.floor(s / 3600)} h ${Math.round((s % 3600) / 60)} min`;
  return `${(s / 86400).toFixed(1)} days`;
}
const fmtPoints = (r) => (r >= 1000 ? `${r / 1000} k` : `${r} `) + "points/s";

async function initLogger() {
  let r;
  try { r = await api("/api/logs"); } catch (e) { return; }      // no logger on this board
  $("log-card").hidden = false;
  $("log-rate").innerHTML = LOG_RATES.map((v) => `<option value="${v}">${fmtPoints(v)}</option>`).join("");
  $("log-rate").value = localStorage.getItem("de25-log-rate") || "1000";
  if (!$("log-rate").value) $("log-rate").value = "1000";
  $("log-rate").onchange = () => { localStorage.setItem("de25-log-rate", $("log-rate").value); showLogs(logger.last); };
  $("log-start").onclick = logStart;
  $("log-stop").onclick = logStop;
  showLogs(r);
  logger.timer = setInterval(refreshLogs, 2000);
}

async function refreshLogs() {
  try { showLogs(await api("/api/logs")); } catch (e) { /* the next one */ }
}

async function logStart() {
  if (scope.running) await scopeStop();
  if (stream.on) streamStop();
  const s = scopeSettings();
  const settings = {
    rate: +$("log-rate").value, sources: s.sources, generator_hz: s.generator_hz,
    label: $("log-label").value.trim(),
    max_seconds: $("log-duration").value ? +$("log-duration").value : null,
  };
  try {
    await api("/api/logs/start", { settings });
    logger.error = "";
  } catch (e) {
    logger.error = e.message;
  }
  refreshLogs();
}

async function logStop() {
  try { await api("/api/logs/stop", {}); } catch (e) { logger.error = e.message; }
  refreshLogs();
}

async function logDelete(name) {
  if (!confirm(`Delete ${name}?`)) return;
  try { await api("/api/logs/delete", { name }); } catch (e) { logger.error = e.message; }
  refreshLogs();
}

function showLogs(r) {
  if (!r) return;
  logger.last = r;
  const st = r.status, cur = st.active ? st.current : null;
  const pill = $("log-status");
  pill.className = "pill pill-" + (cur ? "ok" : "wait");
  pill.textContent = cur ? "logging" : "idle";
  $("log-start").setAttribute("aria-pressed", String(!!cur));
  const free = st.free_bytes - st.reserve_bytes;
  const rate = cur ? cur.rate : +$("log-rate").value;
  const room = `${fmtBytes(Math.max(0, free))} free on the card: ${fmtDuration(Math.max(0, free) / (rate * LOG_POINT_BYTES))} at ${fmtPoints(+rate.toPrecision(6))}`;
  let msg = room;
  if (cur) {
    const secs = Date.now() / 1000 - cur.started;
    msg = `${cur.name}: ${cur.points.toLocaleString()} points, ${fmtBytes(cur.bytes)} in ${fmtDuration(secs)}; ${room}`;
  }
  $("log-msg").textContent = logger.error ? `${logger.error} - ${msg}` : msg;
  const rows = r.logs.map((l) => {
    const secs = l.points / l.rate;
    const state = l.state === "done" ? "done" : l.state;
    const enc = encodeURIComponent(l.name);
    return `<tr data-name="${l.name}"><td>${l.started_utc.replace("T", " ").replace("Z", "")}</td>` +
      `<td>${escapeHtml(l.label || "")}</td><td class="num">${fmtPoints(+l.rate.toPrecision(6))}</td>` +
      `<td class="num">${fmtDuration(secs)}</td><td class="num">${fmtBytes(l.bytes)}</td>` +
      `<td title="${escapeHtml(l.end_reason || "")}">${state}</td>` +
      `<td><a href="/api/logs/${enc}.csv" download>CSV</a><a href="/api/logs/${enc}.i16" download>raw</a>` +
      `<a href="/api/logs/${enc}.json" download>json</a></td>` +
      `<td>${l.state === "running" ? "" : `<button type="button" class="secondary" data-delete="${l.name}">Delete</button>`}</td></tr>`;
  });
  $("log-rows").innerHTML = rows.join("") || `<tr><td colspan="8" class="empty">No logs yet</td></tr>`;
  for (const b of $("log-rows").querySelectorAll("button[data-delete]")) b.onclick = () => logDelete(b.dataset.delete);
}

function escapeHtml(t) {
  return String(t).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
}

initScope();
loadVersion().catch((e) => { $("release-msg").textContent = "Version unknown: " + e.message; });
loadCoreInfo().catch((e) => { $("core-msg").textContent = "Core unknown: " + e.message; });
loadRsuInfo().catch((e) => { $("rsu-image").textContent = "unknown: " + e.message; });
setInterval(() => { if (!$("rsu-card").hidden) loadRsuInfo().catch(() => {}); }, 15000);
