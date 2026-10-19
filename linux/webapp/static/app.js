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
  $("update-form").addEventListener("submit", (e) => { e.preventDefault(); upload(); });
  $("rollback").addEventListener("click", rollback);
  $("core-form").addEventListener("submit", (e) => { e.preventDefault(); loadCore(); });
  $("core-reload").addEventListener("click", reloadCore);
  $("rsu-form").addEventListener("submit", (e) => { e.preventDefault(); uploadRsu(); });
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
  $("fan-ok").textContent = s.fan.i2c_error ? "I2C error" : s.fan.init_done ? "ok" : "starting";
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
  $("core-force").checked = !c.installed;
  return c;
}

function coreBusy(busy) {
  $("core-form").querySelectorAll("input, button").forEach((el) => { el.disabled = busy; });
}

async function loadCore() {
  const file = $("core-file").files[0];
  if (!file) { $("core-msg").textContent = "Pick a core bundle .tar.gz first (deploy_fpga.py --pack-only)."; return; }
  const buf = await file.arrayBuffer();
  const sha = await sha256hex(buf);
  const headers = { "X-Sha256": sha, "X-Token": $("core-token").value };
  if ($("core-force").checked) headers["X-Force"] = "1";
  $("core-msg").textContent = `Loading ${file.name} - the board pauses for about 2 s...`;
  coreBusy(true);
  try {
    const r = await api("/api/fpga", new Blob([buf]), headers);
    $("core-msg").textContent = `Build ${r.build_id} running (${r.seconds} s); SD card copy ` +
      (r.boot && r.boot.written ? "written." : "NOT written: " + ((r.boot && r.boot.error) || "?"));
  } catch (e) {
    $("core-msg").textContent = "Core not loaded: " + e.message;
  } finally {
    coreBusy(false);
    loadCoreInfo().catch(() => {});
  }
}

async function reloadCore() {
  $("core-msg").textContent = "Reloading the installed core...";
  coreBusy(true);
  try {
    const r = await api("/api/fpga/reload", {}, { "X-Token": $("core-token").value });
    $("core-msg").textContent = `Reloaded build ${r.build_id} in ${r.seconds} s.`;
  } catch (e) {
    $("core-msg").textContent = "Reload failed: " + e.message;
  } finally {
    coreBusy(false);
    loadCoreInfo().catch(() => {});
  }
}

// ---------------------------------------------------------------- FPGA image (RSU)
const IMAGES = { 0x220000: "factory image", 0x400000: "P1" };

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
  $("rsu-p1").textContent = r.p1_priority === "[disabled]" ? "nothing bootable (erased or disabled)"
    : r.installed ? buildName(r.installed.build_id) + (r.installed.git ? ", git " + r.installed.git : "")
    : "(written by the .jic)";
  $("rsu-fail").hidden = !fail;
  $("rsu-fail").textContent = fail ? `${IMAGES[fail] || "0x" + fail.toString(16)} failed (state ${st.state}) - the SDM fell back` : "";
  return r;
}

async function uploadRsu() {
  const file = $("rsu-file").files[0];
  if (!file) { $("rsu-msg").textContent = "Pick an RSU bundle .tar.gz first (make_rsu_bundle.py)."; return; }
  const buf = await file.arrayBuffer();
  const sha = await sha256hex(buf);
  $("rsu-msg").textContent = `Writing ${file.name} to P1 - this takes a few minutes, then the board reboots...`;
  $("rsu-form").querySelectorAll("input, button").forEach((el) => { el.disabled = true; });
  try {
    const r = await api("/api/rsu", new Blob([buf]), { "X-Sha256": sha, "X-Token": $("rsu-token").value });
    $("rsu-msg").textContent = `Build ${r.build_id} written in ${r.seconds} s; rebooting into it. ` +
      "The page comes back once the board is up; the image counts when it shows \"confirmed\".";
    waitForBoard();
  } catch (e) {
    $("rsu-msg").textContent = "Update not written: " + e.message;
    $("rsu-form").querySelectorAll("input, button").forEach((el) => { el.disabled = false; });
  }
}

function waitForBoard() {
  // the board reboots: wait for it to go away, then reload when it answers
  let down = false;
  const t0 = Date.now();
  const tick = async () => {
    try {
      await api("/api/version");
      if (down) { location.reload(); return; }
    } catch (e) { down = true; }
    if (Date.now() - t0 < 600000) setTimeout(tick, 3000);
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
  $("update-form").querySelectorAll("input, button").forEach((el) => { el.disabled = !managed; });
  if (!managed) $("update-msg").textContent = "Not an installed release - updates are off (development run).";
  // This page loaded and read the board: the release on test works. Keep it.
  if (managed && release.pending && release.pending === release.release) {
    // the server only confirms once all three processes answer; retry a while
    for (let i = 0; i < 20; i++) {
      try {
        await api("/api/update/confirm", {});
        $("update-msg").textContent = `Release ${release.release} confirmed.`;
        $("pending").hidden = true;
        return;
      } catch (e) {
        $("update-msg").textContent = "Not confirmed yet: " + e.message;
        await new Promise((r) => setTimeout(r, 3000));
      }
    }
  }
}

async function upload() {
  const file = $("update-file").files[0];
  if (!file) { $("update-msg").textContent = "Pick a release .tar.gz first."; return; }
  const buf = await file.arrayBuffer();
  const sha = await sha256hex(buf);
  $("update-msg").textContent = `Uploading ${file.name} (${buf.byteLength} bytes)...`;
  try {
    const r = await api("/api/update", new Blob([buf]), {
      "X-Sha256": sha, "X-Token": $("update-token").value,
    });
    $("update-msg").textContent = `Installed ${r.installed}; restarting...`;
    waitForRestart();
  } catch (e) {
    $("update-msg").textContent = "Update refused: " + e.message;
  }
}

async function rollback() {
  try {
    const r = await api("/api/update/rollback", {}, { "X-Token": $("update-token").value });
    $("update-msg").textContent = `Rolling back to ${r.current}...`;
    waitForRestart();
  } catch (e) {
    $("update-msg").textContent = "Rollback refused: " + e.message;
  }
}

function waitForRestart() {
  // the server restarts into the new release; reload once it answers again
  const t0 = Date.now();
  const tick = async () => {
    try {
      const v = await api("/api/version");
      if (v.release !== release.release) { location.reload(); return; }
    } catch (e) { /* still restarting */ }
    if (Date.now() - t0 < 60000) setTimeout(tick, 1000);
    else $("update-msg").textContent = "The board did not come back within a minute.";
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

// ---------------------------------------------------------------- start
buildControl();
drawPlots();
buildPanels();
buildLedBar();
loadBoard().then(connect);
loadVersion().catch((e) => { $("update-msg").textContent = "Version unknown: " + e.message; });
loadCoreInfo().catch((e) => { $("core-msg").textContent = "Core unknown: " + e.message; });
loadRsuInfo().catch((e) => { $("rsu-msg").textContent = "RSU state unknown: " + e.message; });
setInterval(() => { if (!$("rsu-card").hidden) loadRsuInfo().catch(() => {}); }, 15000);
