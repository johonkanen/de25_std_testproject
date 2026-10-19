#!/usr/bin/env python3
"""
supervisor_test.py - the GUI release cases (plan Phase D) against the real
supervisor, on the host: linux/board/de25web-supervisor.sh under busybox sh,
the three processes with --sim, a throw-away /opt/de25web layout.

    python3 linux/tools/supervisor_test.py            # every case, ~3 min
    python3 linux/tools/supervisor_test.py crash rollback_broken

Cases (each starts from a fresh layout with one confirmed release):
    good             upload, confirm: the new one stays, previous = the old
    two_updates      two uploads within the test time, then confirm the second
    two_unconfirmed  two uploads, neither confirmed: back to the confirmed one
    no_confirm       no confirmation: reverted after the test time
    crash            a release whose server exits at once: reverted after 3 exits
    restart          the board restarts during the test: reverted at start-up
    rollback_broken  roll back onto a broken release: that reverts too
    wrong_board      a release for another board (or none): refused, 400

Needs busybox and python3. The layout and sockets go to /tmp/d25s (short:
Unix socket paths, plan §5.20).
"""
import hashlib
import io
import json
import os
import shutil
import signal
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.modules.setdefault("serial", type(sys)("serial"))      # install_webapp imports it
sys.path.insert(0, HERE)
import install_webapp                                       # noqa: E402
from deploy_web import WEBAPP, pack_release                 # noqa: E402

ROOT = "/tmp/d25s"
BASE = os.path.join(ROOT, "base")
RUN = os.path.join(ROOT, "run")
PORT = 8765
TEST_SECONDS = 15
TOKEN = "test-token"
URL = f"http://127.0.0.1:{PORT}"


def request(path, data=None, headers=None, timeout=5):
    req = urllib.request.Request(URL + path, data=data, headers=headers or {},
                                 method="POST" if data is not None else "GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def version():
    try:
        status, v = request("/api/version", timeout=2)
        return v if status == 200 else None
    except OSError:
        return None


def wait_for(what, cond, timeout):
    t0 = time.time()
    while time.time() - t0 < timeout:
        v = version()
        if v and cond(v):
            return v
        time.sleep(0.5)
    raise AssertionError(f"{what}: not within {timeout} s (last: {version()})")


def release(variant=None):
    """a release archive: linux/webapp as it is, or changed by variant(dir)"""
    if variant is None:
        return pack_release()[0]
    tmp = os.path.join(ROOT, "variant")
    shutil.rmtree(tmp, ignore_errors=True)
    shutil.copytree(WEBAPP, tmp, ignore=shutil.ignore_patterns("__pycache__"))
    variant(tmp)
    return pack_release(tmp)[0]


def crashing(d):      # the server exits at once: the release can never answer
    p = os.path.join(d, "fpga_web.py")
    src = open(p).read()
    open(p, "w").write(src.replace('\nimport argparse\n', '\nimport sys; sys.exit(7)\nimport argparse\n', 1))


def upload(blob, expect=202):
    status, r = request("/api/update", blob, {"X-Sha256": hashlib.sha256(blob).hexdigest(),
                                              "X-Token": TOKEN}, timeout=30)
    assert status == expect, f"upload: {status} {r}"
    return r


def confirm(rel):
    wait_for(f"{rel} running", lambda v: v.get("release") == rel, 30)
    t0 = time.time()
    while True:         # 503 until fpga_access and temp_control answer
        status, r = request("/api/update/confirm", b"{}")
        if status == 200:
            return
        assert time.time() - t0 < 20, f"confirm: {status} {r}"
        time.sleep(0.5)


class Supervisor:
    def __init__(self):
        self.proc = None

    def start(self):
        env = dict(os.environ, DE25WEB_BASE=BASE, DE25WEB_RUN=RUN, DE25WEB_PORT=str(PORT),
                   DE25WEB_TEST_SECONDS=str(TEST_SECONDS), DE25WEB_ARGS="--sim")
        self.proc = subprocess.Popen(["busybox", "sh", os.path.join(BASE, "supervisor.sh")],
                                     env=env, start_new_session=True)

    def kill(self):
        """everything at once, as a power cut would"""
        if self.proc:
            os.killpg(self.proc.pid, signal.SIGKILL)
            self.proc.wait()
            self.proc = None


def fresh_layout(sup):
    sup.kill()
    shutil.rmtree(ROOT, ignore_errors=True)
    os.makedirs(BASE)
    blob, rel = install_webapp.bundle()
    tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz").extractall(BASE)
    os.symlink(os.path.join("releases", rel), os.path.join(BASE, "current"))
    open(os.path.join(BASE, "token"), "w").write(TOKEN + "\n")
    sup.start()
    wait_for("the first release", lambda v: v.get("release") == rel, 30)
    return rel


def wait_log(text, timeout, times=1):
    """a crashing release never answers: watch the supervisor's log"""
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            if open(os.path.join(BASE, "supervisor.log")).read().count(text) >= times:
                return
        except OSError:
            pass
        time.sleep(0.5)
    raise AssertionError(f"no {text!r} in the supervisor log within {timeout} s")


def log_tail():
    try:
        return open(os.path.join(BASE, "supervisor.log")).read().strip().splitlines()[-1]
    except OSError:
        return ""


# ---------------------------------------------------------------------------
def case_good(sup, first):
    rel = upload(release())["installed"]
    confirm(rel)
    v = version()
    assert v["current"] == rel and v["previous"] == first and v["pending"] is None, v


def case_two_updates(sup, first):
    a = upload(release())["installed"]
    wait_for("A running", lambda v: v.get("release") == a, 30)
    b = upload(release())["installed"]
    confirm(b)
    v = version()
    assert v["current"] == b and v["pending"] is None, v
    assert v["previous"] == first, f"previous should be the last confirmed ({first}): {v}"
    time.sleep(TEST_SECONDS + 3)            # and it stays
    assert version()["release"] == b, version()


def case_two_unconfirmed(sup, first):
    a = upload(release())["installed"]
    wait_for("A running", lambda v: v.get("release") == a, 30)
    upload(release())
    wait_for("back to the confirmed release", lambda v: v.get("release") == first,
             TEST_SECONDS + 30)
    assert version()["pending"] is None, version()


def case_no_confirm(sup, first):
    rel = upload(release())["installed"]
    wait_for("new running", lambda v: v.get("release") == rel, 30)
    wait_for("reverted", lambda v: v.get("release") == first, TEST_SECONDS + 30)
    v = version()
    assert v["previous"] == rel and v["pending"] is None, v


def case_crash(sup, first):
    rel = upload(release(crashing))["installed"]
    wait_log(f"reverted {rel} -> {first}: exited 3 times", TEST_SECONDS + 30)
    wait_for("the old one answering", lambda v: v.get("release") == first, 30)
    return rel


def case_restart(sup, first):
    rel = upload(release())["installed"]
    wait_for("new running", lambda v: v.get("release") == rel, 30)
    sup.kill()
    sup.start()
    wait_for("reverted at start-up", lambda v: v.get("release") == first, 30)
    assert "restarted while" in open(os.path.join(BASE, "supervisor.log")).read(), log_tail()


def case_rollback_broken(sup, first):
    broken = case_crash(sup, first)
    assert version()["previous"] == broken, version()
    status, r = request("/api/update/rollback", b"{}", {"X-Token": TOKEN})
    assert status == 202 and r["current"] == broken, (status, r)
    wait_log(f"reverted {broken} -> {first}: exited 3 times", TEST_SECONDS + 30, times=2)
    wait_for("the old one answering", lambda v: v.get("release") == first, 30)


def case_wrong_board(sup, first):
    nano = upload(release(lambda d: open(os.path.join(d, "BOARD"), "w").write("de25-nano\n")), 400)
    assert "de25-nano" in nano.get("error", ""), nano
    # no BOARD at all (a DE25-Nano release): the archive without it
    src = tarfile.open(fileobj=io.BytesIO(release()), mode="r:gz")
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for m in src.getmembers():
            if m.name != "BOARD":
                tar.addfile(m, src.extractfile(m) if m.isfile() else None)
    upload(buf.getvalue(), 400)
    v = version()
    assert v["release"] == first and v["pending"] is None, v


CASES = [n[5:] for n in dir() if n.startswith("case_")]


def main():
    names = sys.argv[1:] or ["good", "two_updates", "two_unconfirmed", "no_confirm", "crash",
                             "restart", "rollback_broken", "wrong_board"]
    bad = set(names) - set(CASES)
    if bad:
        sys.exit(f"unknown case(s) {', '.join(sorted(bad))}; known: {', '.join(CASES)}")
    sup = Supervisor()
    failed = []
    try:
        for name in names:
            t0 = time.time()
            first = fresh_layout(sup)
            try:
                globals()["case_" + name](sup, first)
                print(f"PASS  {name} ({time.time() - t0:.0f} s)", flush=True)
            except AssertionError as e:
                failed.append(name)
                print(f"FAIL  {name}: {e}\n      log: {log_tail()}", flush=True)
    finally:
        sup.kill()
    print("FAIL: " + " ".join(failed) if failed else "PASS")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
