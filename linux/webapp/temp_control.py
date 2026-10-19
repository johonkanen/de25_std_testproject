#!/usr/bin/env python3
"""
temp_control.py - closed-loop die temperature control for the DE25-Standard.

Controlled variable: the hottest of the Agilex 5's die temperature sensors
(the kernel's soc64-hwmon, read by the SDM). Actuator: the fan's speed in
rpm - the MAX6650 closes the speed loop itself; register 9 takes its KTACH
target (fpga_access.rpm_to_ktach), through fpga_access.py - this process
never maps /dev/mem. Setpoint: 42.0 C unless changed (kept in --config).

    python3 temp_control.py [--run /run/de25web] [--config /opt/de25web/control.json]
    python3 temp_control.py --sim                         # against fpga_access.py --sim
    python3 temp_control.py --client state | history | set mode=auto setpoint=42

The control law (PI, positional, conditional-integration anti-windup):

    e    = T_max - setpoint                (positive: too hot -> more fan)
    u    = Kp * e + I,  rpm = clamp(u, 1500, 6000)
    I   += Ki * e * dt  unless that drives u further into a limit
    I    = clamp(I, 1500, 6000)

The written rpm is quantised by KTACH (an integer: 1507 rpm at the floor,
steps of ~1.3 % there, ~5 % near 6000).

The fan can only cool. With the fan at its minimum (1500 rpm, the fabric's
reset speed) and the die still below the setpoint, the loop is saturated
low: there is nothing left to do, and the state says so (saturated "low");
likewise "high" at full fan and still too hot. Modes: auto (the PI loop),
manual (a fixed rpm, never below 1500), off (the loop leaves the fan alone).

Failure behaviour:
  - every fan write carries a 10 s lease: if this process dies, hangs or is
    killed, fpga_access.py raises the fan to 4000 rpm (never lowers it) once
    the lease runs out; the supervisor restarts this process meanwhile, and
    the restart is bumpless (the integrator starts from the register's target)
  - no temperature for 5 samples in a row: fan to >= 4000 rpm, status says why
  - FPGA access down: the state says "FPGA access unavailable", the fan
    keeps its last target (the MAX6650 holds it), retried every sample
  - the MAX6650 has no thermal fail-safe of its own (plan §5.17): the lease
    above is the only net when this loop dies

State and commands: <run>/control.sock, one JSON object per line each way:
    {"op": "state"}                     the latest sample and settings
    {"op": "history"}                   the last 10 min: [[t, T_max, setpoint, target_rpm, rpm], ...]
    {"op": "set", "mode": "auto"|"manual"|"off", "setpoint": 42.0,
     "manual_rpm": 3000, "kp": .., "ki": ..}

Stdlib only.
"""
import argparse
import collections
import json
import os
import random
import re
import signal
import socket
import socketserver
import sys
import threading
import time

from fpga_access import (FAN_MAX_RPM, FAN_MIN_RPM, REG_FAN_KTACH, REG_FAN_TACH, SAFE_FAN_RPM,
                         FpgaClient, FpgaUnavailable, hwmon_root, ktach_to_rpm, rpm_to_ktach,
                         run_dir)

SOCKET_NAME = "control.sock"
MODES = ("auto", "manual", "off")
LEASE_S = 10.0
HISTORY_S = 600
SETTLE_BAND = 0.3                       # C: "at the setpoint"
SETTLE_S = 30                           # ... for this long
SENSOR_FAULT_SAMPLES = 5

# Starting gains: the DE25-Nano's (Kp 16 duty/C, Ki 0.55 duty/(C s) over 225
# duty steps) scaled to the Standard's 1500..6000 rpm span; fpga_access.py's
# simulated plant for this board is a first guess (gain ~ -0.0023 C/rpm at
# 2500 rpm, tau 30 s), so these stay conservative until the plant is re-fit
# on the board (plan C7). Kp 320 rpm/C, Ti 30 s -> Ki ~ 11 rpm/(C s).
DEFAULTS = {"mode": "auto", "setpoint": 42.0, "manual_rpm": 3000, "kp": 320.0, "ki": 11.0}


def log(*a):
    print(time.strftime("%F %T"), "temp_control:", *a, flush=True)


# --------------------------------------------------------------------------
# the SoC's sensors (also used by fpga_web.py)
# --------------------------------------------------------------------------
HWMON_NAME = "soc64hwmon"


def find_hwmon(root):
    """the soc64hwmon directory under root (/sys/class/hwmon), or None"""
    try:
        for h in sorted(os.listdir(root)):
            d = os.path.join(root, h)
            try:
                with open(os.path.join(d, "name")) as f:
                    if f.read().strip() == HWMON_NAME:
                        return d
            except OSError:
                continue
    except OSError:
        pass
    return None


def read_hwmon(d, temps=True, volts=True):
    """([{"label", "c"}], [{"label", "v"}]) - each read is an SDM mailbox
    round trip on the board, so callers pick what they need"""
    t_out, v_out = [], []
    for name in sorted(os.listdir(d), key=lambda n: (len(n), n)):
        m = re.fullmatch(r"(temp|in)(\d+)_input", name)
        if not m or (m.group(1) == "temp" and not temps) or (m.group(1) == "in" and not volts):
            continue
        base = os.path.join(d, f"{m.group(1)}{m.group(2)}")
        try:
            with open(base + "_input") as f:
                value = int(f.read())
        except (OSError, ValueError):
            continue            # the SDM can refuse a read now and then
        try:
            with open(base + "_label") as f:
                label = f.read().strip()
        except OSError:
            label = f"{m.group(1)}{m.group(2)}"
        if m.group(1) == "temp":
            t_out.append({"label": label, "c": value / 1000})
        else:
            v_out.append({"label": label, "v": value / 1000})
    return t_out, v_out


# --------------------------------------------------------------------------
# the control law
# --------------------------------------------------------------------------
class PI:
    """Positional PI with output clamping and conditional integration."""

    def __init__(self, kp, ki, lo=FAN_MIN_RPM, hi=FAN_MAX_RPM):
        self.kp, self.ki, self.lo, self.hi = kp, ki, lo, hi
        self.i = float(lo)
        self.p = 0.0
        self.u_raw = float(lo)

    def reset(self, output, error=0.0):
        """bumpless: the next output equals `output` for this error"""
        self.i = min(self.hi, max(self.lo, output - self.kp * error))

    def step(self, error, dt):
        self.p = self.kp * error
        i_new = self.i + self.ki * error * dt
        u_new = self.p + i_new
        # integrate only when it does not push the output further into a limit
        if not ((u_new > self.hi and error > 0) or (u_new < self.lo and error < 0)):
            self.i = i_new
        self.i = min(self.hi, max(self.lo, self.i))
        self.u_raw = self.p + self.i
        return min(self.hi, max(self.lo, self.u_raw))

    def saturation(self, error):
        if self.u_raw > self.hi and error > 0:
            return "high"
        if self.u_raw < self.lo and error < 0:
            return "low"
        return None


class Controller:
    def __init__(self, fpga, sensors_root, config_path, period=1.0):
        self.fpga = fpga
        self.root = sensors_root
        self.config_path = config_path
        self.period = period
        self.cfg = dict(DEFAULTS)
        self._load_config()
        self.pi = PI(self.cfg["kp"], self.cfg["ki"])
        self.lock = threading.RLock()       # RLock: the SIGTERM handler saves the history
        self.boot = "%08x" % random.getrandbits(32)
        self.history = collections.deque(maxlen=int(HISTORY_S / period) + 1)
        self.errors = collections.deque(maxlen=max(1, int(SETTLE_S / period)))
        self.n = 0
        self.sensor_fails = 0
        self.need_reset = True             # bumpless start from the register's target
        self.target_rpm = None
        self.hwdir = None
        self.state = {"boot": self.boot, "n": 0, "status": "starting", **self._settings()}

    # ---------------------------------------------------------------- config
    def _load_config(self):
        try:
            with open(self.config_path) as f:
                saved = json.load(f)
            self._apply(saved, persist=False)
        except FileNotFoundError:
            pass
        except (OSError, ValueError) as e:
            log(f"{self.config_path}: {e} - using defaults")

    def _apply(self, req, persist=True):
        new = dict(self.cfg)
        if "mode" in req:
            if req["mode"] not in MODES:
                raise ValueError("mode is one of " + ", ".join(MODES))
            new["mode"] = req["mode"]
        if "setpoint" in req:
            sp = float(req["setpoint"])
            if not 25.0 <= sp <= 85.0:
                raise ValueError("setpoint 25..85 C")
            new["setpoint"] = round(sp, 2)
        if "manual_rpm" in req:
            r = int(req["manual_rpm"])
            if not 0 <= r <= FAN_MAX_RPM:
                raise ValueError(f"manual_rpm 0..{FAN_MAX_RPM}")
            new["manual_rpm"] = max(FAN_MIN_RPM, r)
        for k in ("kp", "ki"):
            if k in req:
                v = float(req[k])
                if not 0 <= v <= 10000:
                    raise ValueError(f"{k} 0..10000")
                new[k] = v
        old = self.cfg
        self.cfg = new
        if hasattr(self, "pi"):
            self.pi.kp, self.pi.ki = new["kp"], new["ki"]
            if new["mode"] == "auto" and (old["mode"] != "auto" or new["kp"] != old["kp"]):
                self.need_reset = True
            if new["mode"] == "off" and old["mode"] != "off":
                self._release()
        if persist and new != old:
            tmp = self.config_path + ".tmp"
            try:
                with open(tmp, "w") as f:
                    json.dump(new, f, indent=1)
                os.replace(tmp, self.config_path)
            except OSError as e:
                log(f"cannot save {self.config_path}: {e}")
        if new != old and hasattr(self, "pi"):
            log("settings: " + ", ".join(f"{k} {new[k]}" for k in new if new[k] != old[k]))

    def _settings(self):
        return {"mode": self.cfg["mode"], "setpoint": self.cfg["setpoint"],
                "manual_rpm": self.cfg["manual_rpm"], "kp": self.cfg["kp"], "ki": self.cfg["ki"],
                "period_s": self.period, "rpm_min": FAN_MIN_RPM, "rpm_max": FAN_MAX_RPM,
                "safe_rpm": SAFE_FAN_RPM, "settle_band": SETTLE_BAND}

    def set(self, req):
        with self.lock:
            self._apply(req)
            self.state.update(self._settings())
            return dict(self.state)

    def _release(self):
        try:
            self.fpga.call(op="release", reg=REG_FAN_KTACH)
        except (FpgaUnavailable, ValueError):
            pass

    # ------------------------------------------------- history across restarts
    # Written once on a clean stop (a release switch) and read back by the
    # next start, so the plot keeps its 10 minutes; no periodic writes (the
    # run directory may be on the SD card). A crash loses it - a gap.
    def save_history(self, path):
        try:
            with self.lock:
                data = list(self.history)
            with open(path + ".tmp", "w") as f:
                json.dump(data, f)
            os.replace(path + ".tmp", path)
        except OSError as e:
            log(f"cannot save the history: {e}")

    def load_history(self, path):
        try:
            with open(path) as f:
                data = json.load(f)
            os.remove(path)
        except (OSError, ValueError):
            return
        now = time.monotonic()
        self.history.extend(h for h in data if isinstance(h, list) and len(h) == 5
                            and now - HISTORY_S <= h[0] <= now)

    # ---------------------------------------------------------------- loop
    def _measure(self):
        if not self.hwdir or not os.path.isdir(self.hwdir):
            self.hwdir = find_hwmon(self.root)
            if not self.hwdir:
                return None, []
        temps, _ = read_hwmon(self.hwdir, volts=False)
        if not temps:
            return None, []
        return max(temps, key=lambda t: t["c"]), temps

    def sample(self, dt):
        with self.lock:
            return self._sample(dt)

    def _sample(self, dt):
        cfg = self.cfg
        mode, sp = cfg["mode"], cfg["setpoint"]
        hottest, temps = self._measure()
        st = {"boot": self.boot, "n": self.n, "t": round(time.monotonic(), 2), **self._settings(),
              "temps": temps, "measured": hottest["c"] if hottest else None,
              "hottest": hottest["label"] if hottest else None,
              "saturated": None, "fpga_ok": True, "fpga_error": None, "sensor_ok": hottest is not None}
        self.n += 1
        error = hottest["c"] - sp if hottest else None
        self.sensor_fails = 0 if hottest else self.sensor_fails + 1

        try:
            reg_target = round(ktach_to_rpm(self.fpga.read(REG_FAN_KTACH)))
            rpm = self.fpga.read(REG_FAN_TACH) >> 8 & 0xFFFF
        except FpgaUnavailable as e:
            st.update(fpga_ok=False, fpga_error=str(e), target_rpm=self.target_rpm, rpm=None,
                      p=round(self.pi.p, 2), i=round(self.pi.i, 2),
                      status=str(e) + " - the fan keeps its last target")
            self.need_reset = True
            return self._finish(st, error)

        want = None
        status = ""
        if mode == "off":
            status = "off - the fan is left as it is"
            self.need_reset = True
        elif mode == "manual":
            want = max(FAN_MIN_RPM, cfg["manual_rpm"])
            status = f"manual - {want} rpm"
            self.need_reset = True
        elif hottest is None:
            if self.sensor_fails >= SENSOR_FAULT_SAMPLES:
                want = max(reg_target, SAFE_FAN_RPM)
                status = f"no die temperature for {self.sensor_fails} samples - fan at {want} rpm (safe)"
            else:
                want = reg_target
                status = "no die temperature this sample"
            self.need_reset = True
        else:
            if self.need_reset:
                self.pi.reset(reg_target, error)
                self.need_reset = False
            want = int(round(self.pi.step(error, dt)))
            sat = self.pi.saturation(error)
            st["saturated"] = sat
            if sat == "low":
                status = (f"saturated: fan at minimum ({FAN_MIN_RPM} rpm) and the die is still "
                          f"{-error:.1f} C below the setpoint - a fan cannot heat")
            elif sat == "high":
                status = f"saturated: fan at full and the die is {error:.1f} C above the setpoint"
            else:
                status = "regulating"
        if want is not None:
            try:
                reg_target = round(ktach_to_rpm(
                    self.fpga.write(REG_FAN_KTACH, rpm_to_ktach(want), lease=LEASE_S)))
            except FpgaUnavailable as e:
                st.update(fpga_ok=False, fpga_error=str(e))
                status = str(e)
        self.target_rpm = reg_target
        st.update(target_rpm=reg_target, rpm=rpm, p=round(self.pi.p, 2), i=round(self.pi.i, 2),
                  status=status)
        return self._finish(st, error)

    def _finish(self, st, error):
        if error is not None and st["mode"] == "auto":
            self.errors.append(error)
        else:
            self.errors.clear()
        full = len(self.errors) == self.errors.maxlen
        st["error"] = round(error, 3) if error is not None else None
        # settled: every 5-sample average of the last SETTLE_S within the band
        # (the average takes the sensor noise out, not the loop's own swings)
        e = list(self.errors)
        avgs = [sum(e[i:i + 5]) / 5 for i in range(len(e) - 4)]
        st["settled"] = bool(full and avgs and max(abs(a) for a in avgs) <= SETTLE_BAND)
        st["mean_error"] = round(sum(self.errors) / len(self.errors), 3) if self.errors else None
        if st["settled"] and st["status"] == "regulating":
            st["status"] = f"settled within {SETTLE_BAND} C"
        self.history.append([st["t"], st["measured"], st["setpoint"] if st["mode"] == "auto" else None,
                             st["target_rpm"], st.get("rpm")])
        self.state = st
        return st

    def run(self):
        log(f"setpoint {self.cfg['setpoint']} C, mode {self.cfg['mode']}, "
            f"Kp {self.cfg['kp']}, Ki {self.cfg['ki']}, period {self.period} s, sensors {self.root}")
        if self.cfg["mode"] == "off":
            self._release()            # a lease left by a previous run must not fire
        last = time.monotonic()
        next_t = last
        prev_status = None
        while True:
            next_t += self.period
            now = time.monotonic()
            dt, last = now - last, now
            try:
                st = self.sample(min(dt, 5 * self.period))
            except Exception as e:      # a bug must not leave the fan unattended
                log(f"sample failed: {e!r}")
                raise
            status = st["status"].split(" - ")[0].split(":")[0]
            if status != prev_status:
                log(f"{st['status']} (T {st.get('measured')} C, target {st.get('target_rpm')} rpm)")
                prev_status = status
            time.sleep(max(0.0, next_t - time.monotonic()))
            if next_t < time.monotonic() - 5 * self.period:
                next_t = time.monotonic()           # fell far behind: do not catch up


def serve(ctl, path):
    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            for line in self.rfile:
                if not line.strip():
                    continue
                try:
                    req = json.loads(line)
                    op = req.get("op")
                    if op == "state":
                        resp = {"ok": True, "state": ctl.state}
                    elif op == "history":
                        with ctl.lock:
                            hist = list(ctl.history)
                        resp = {"ok": True, "boot": ctl.boot, "history": hist}
                    elif op == "set":
                        resp = {"ok": True, "state": ctl.set({k: v for k, v in req.items() if k != "op"})}
                    elif op == "ping":
                        resp = {"ok": True, "pid": os.getpid()}
                    else:
                        resp = {"ok": False, "error": f"unknown op {op!r}"}
                except (ValueError, KeyError, TypeError) as e:
                    resp = {"ok": False, "error": str(e)}
                try:
                    self.wfile.write(json.dumps(resp).encode() + b"\n")
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    return

    class Server(socketserver.ThreadingUnixStreamServer):
        daemon_threads = True

    tmp = path + ".new"
    if os.path.exists(tmp):
        os.remove(tmp)
    srv = Server(tmp, Handler)
    os.chmod(tmp, 0o660)
    os.replace(tmp, path)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


class ControlUnavailable(Exception):
    pass


class ControlClient:
    """fpga_web.py's side of control.sock: thread-safe, reconnecting."""

    def __init__(self, run, timeout=2.0):
        self.path = os.path.join(run, SOCKET_NAME)
        self.timeout = timeout
        self._sock = self._rfile = None
        self._lock = threading.Lock()

    def call(self, **req):
        with self._lock:
            for attempt in (0, 1):
                try:
                    if self._sock is None:
                        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                        s.settimeout(self.timeout)
                        s.connect(self.path)
                        self._sock, self._rfile = s, s.makefile("rb")
                    self._sock.sendall(json.dumps(req).encode() + b"\n")
                    line = self._rfile.readline()
                    if not line:
                        raise ConnectionResetError("closed")
                    resp = json.loads(line)
                    break
                except (OSError, ValueError) as e:
                    try:
                        if self._sock:
                            self._sock.close()
                    except OSError:
                        pass
                    self._sock = self._rfile = None
                    if attempt:
                        raise ControlUnavailable("temperature control unavailable (%s)" % e) from None
        if not resp.get("ok"):
            raise ValueError(resp.get("error", "request failed"))
        return resp


def main():
    ap = argparse.ArgumentParser(description="DE25-Standard die temperature controller")
    ap.add_argument("--run", default=None, help="socket directory (as fpga_access.py)")
    ap.add_argument("--sim", action="store_true", help="read the simulated plant's sensors")
    ap.add_argument("--hwmon-root", default=None, help="default /sys/class/hwmon (<run>/sim-hwmon with --sim)")
    ap.add_argument("--config", default=None,
                    help="settings file (default <DE25WEB_BASE or /opt/de25web>/control.json, "
                         "<run>/control.json with --sim)")
    ap.add_argument("--period", type=float, default=1.0, help="sample period, s")
    ap.add_argument("--client", nargs=argparse.REMAINDER, help="state | history | set key=value ...")
    args = ap.parse_args()
    run = run_dir(args.run, args.sim)

    if args.client is not None:
        c, a = ControlClient(run), args.client
        try:
            if a and a[0] == "set":
                kv = dict(x.split("=", 1) for x in a[1:])
                print(json.dumps(c.call(op="set", **kv)["state"], indent=1))
            elif a and a[0] == "history":
                print(json.dumps(c.call(op="history")["history"]))
            else:
                print(json.dumps(c.call(op="state")["state"], indent=1))
        except (ControlUnavailable, ValueError) as e:
            sys.exit(str(e))
        return

    os.makedirs(run, exist_ok=True)
    config = args.config or (os.path.join(run, "control.json") if args.sim else
                             os.path.join(os.environ.get("DE25WEB_BASE", "/opt/de25web"), "control.json"))
    fpga = FpgaClient(run)
    ctl = Controller(fpga, args.hwmon_root or hwmon_root(run, args.sim), config, args.period)
    hist_file = os.path.join(run, "control-history.json")
    ctl.load_history(hist_file)

    def stop(signum, _frame):
        # a clean stop (the supervisor switching releases): the fan keeps its
        # target and its lease - if no controller is back within LEASE_S,
        # fpga_access raises the fan to the safe speed
        log(f"stopping (signal {signum}), fan stays at {ctl.target_rpm} rpm")
        ctl.save_history(hist_file)
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    serve(ctl, os.path.join(run, SOCKET_NAME))
    try:
        ctl.run()
    except Exception:
        # a crash: push the fan to the safe speed now rather than after the lease
        try:
            ktach, safe = fpga.read(REG_FAN_KTACH) & 0xFF, rpm_to_ktach(SAFE_FAN_RPM)
            if ctl.cfg["mode"] != "off" and ktach > safe:
                fpga.write(REG_FAN_KTACH, safe)
                log(f"crashed: fan {ktach_to_rpm(ktach):.0f} -> {SAFE_FAN_RPM} rpm")
        except (FpgaUnavailable, ValueError):
            pass
        raise


if __name__ == "__main__":
    main()
