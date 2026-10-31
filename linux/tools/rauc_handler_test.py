#!/usr/bin/env python3
"""
rauc_handler_test.py - the board side of RAUC bundles (docs/plan_rauc.md,
step 1) on the host: POST /api/bundle, the detached install, and the
post-install handler (linux/board/rauc/post-install) against the real
supervisor and the three processes with --sim (supervisor_test.py's
harness and layout, /tmp/d25s).

What is not real here: `rauc install` itself (it needs root, loop devices
and dm-verity). A stand-in does what RAUC does before the handler - the
bundle's trees into the artifact repositories, the mount point with its
manifest.raucm (both from `rauc-host extract` of a real signed bundle) -
and then runs the real handler. The signature and verity refusals are
tested on the board.

    python3 linux/tools/rauc_handler_test.py            # every case, ~2 min
    python3 linux/tools/rauc_handler_test.py gui_confirmed refusals

Cases (each from a fresh layout with one confirmed release):
    gui_confirmed    a GUI bundle: on test, confirmed -> rauc install exit 0;
                     the same bundle again -> "already", exit 0
    gui_unconfirmed  never confirmed: the supervisor reverts -> exit 1
    refusals         no token 403, wrong SHA 400, a second install while one
                     runs 409, no rauc on the board 501 (another server)
    core_sim         a core bundle to fpga_access.py --sim: refused without an
                     installed manifest (exit 1); loaded over one of the same
                     periphery (exit 0, the old one kept as previous); again:
                     "already running"
    deploy_tool      deploy_bundle.py with a GUI + core bundle: confirmed, loaded,
                     exit 0; a bundle from another CA: refused before the upload
    unknown_repo     a bundle for a repository this board lacks -> exit 1

Needs busybox, python3, build/rauc/rauc-host (./build.sh rauc), the keys
(rauc_keys.sh) and a core in build/images.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import supervisor_test as st                                 # noqa: E402
from make_bundle import RAUC, make                           # noqa: E402

HANDLER = os.path.normpath(os.path.join(HERE, "..", "board", "rauc", "post-install"))
KEYS = os.environ.get("RAUC_KEYS", os.path.expanduser("~/.de25_rauc_keys"))
CORE = os.path.normpath(os.path.join(HERE, "..", "..", "build", "images", "de25_std.core.rbf"))
WORK = os.path.join(st.ROOT, "rauc")           # under /tmp/d25s: wiped by fresh_layout
MNT, ARTIFACTS, FAKE = (os.path.join(WORK, d) for d in ("mnt", "artifacts", "fake-rauc"))
BUNDLES = "/tmp/d25s-bundles"                  # made once, kept across cases


def bundle(parts):
    os.makedirs(BUNDLES, exist_ok=True)
    out = os.path.join(BUNDLES, "+".join(parts) + ".raucb")
    if not os.path.exists(out):
        make(set(parts), CORE, CORE.replace(".rbf", ".json"), KEYS, out)
    return out


def stage(path, extra_section=None):
    """what `rauc install` leaves for the handler: the mount point with the
    manifest, each artifact's tree in its repository"""
    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK)
    conf = os.path.join(WORK, "host.conf")
    with open(conf, "w") as f:
        f.write(f"[system]\ncompatible=de25-std\nbootloader=noop\n[keyring]\n"
                f"path={KEYS}/ca.cert.pem\ncheck-purpose=codesign\n")
    subprocess.run([RAUC, "-c", conf, "extract", path, MNT], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    man = open(os.path.join(MNT, "manifest.raucm")).read()
    for repo, name in (("gui", "de25web"), ("core", "de25_std")):
        if f"[image.{repo}/{name}]" in man:
            shutil.copytree(os.path.join(MNT, f"{repo}.tar.extracted"),
                            os.path.join(ARTIFACTS, repo, name))
    if extra_section:
        os.chmod(os.path.join(MNT, "manifest.raucm"), 0o644)
        with open(os.path.join(MNT, "manifest.raucm"), "a") as f:
            f.write("\n" + extra_section + "\n")
    # the stand-in rauc: checks it got the upload, runs the real handler
    with open(FAKE, "w") as f:
        f.write(f"""#!/bin/sh
[ "$1" = install ] && [ -s "$2" ] || {{ echo "stand-in rauc: bad call $*"; exit 2; }}
echo "stand-in rauc: installing $2 ($(wc -c < "$2") bytes)"
sleep 1
RAUC_BUNDLE_MOUNT_POINT={MNT} RAUC_ARTIFACTS={ARTIFACTS} \\
DE25WEB_BASE={st.BASE} DE25WEB_RUN={st.RUN} DE25WEB_PORT={st.PORT} \\
DE25WEB_TEST_SECONDS={st.TEST_SECONDS} python3 {HANDLER}
""")
    os.chmod(FAKE, 0o755)
    return open(path, "rb").read()


def post_bundle(blob, token=st.TOKEN, sha=None):
    headers = {"X-Sha256": sha or hashlib.sha256(blob).hexdigest()}
    if token:
        headers["X-Token"] = token
    return st.request("/api/bundle", blob, headers, timeout=30)


def bundle_status():
    for _ in range(10):
        try:
            status, r = st.request("/api/bundle", timeout=3)
            if status == 200:
                return r
        except OSError:
            pass                       # the server restarting into a new release
        time.sleep(0.5)
    raise AssertionError("GET /api/bundle does not answer")


def wait_rc(timeout):
    t0 = time.time()
    while time.time() - t0 < timeout:
        r = bundle_status()
        if r.get("rc") is not None:
            return r
        time.sleep(1)
    raise AssertionError(f"the install did not finish within {timeout} s: {bundle_status()}")


def run_handler():
    env = dict(os.environ, RAUC_BUNDLE_MOUNT_POINT=MNT, RAUC_ARTIFACTS=ARTIFACTS,
               DE25WEB_BASE=st.BASE, DE25WEB_RUN=st.RUN, DE25WEB_PORT=str(st.PORT),
               DE25WEB_TEST_SECONDS=str(st.TEST_SECONDS))
    return subprocess.run(["python3", HANDLER], env=env, capture_output=True, text=True, timeout=120)


# ---------------------------------------------------------------------------
def case_gui_confirmed(sup, first):
    blob = stage(bundle(["gui"]))
    status, r = post_bundle(blob)
    assert status == 202 and r.get("started"), f"POST /api/bundle: {status} {r}"
    v = st.wait_for("the bundle's release on test",
                    lambda v: v.get("pending") and v.get("release") == v.get("pending"), 40)
    rel = v["release"]
    assert rel != first, v
    st.confirm(rel)
    r = wait_rc(30)
    assert r["rc"] == 0 and f"GUI release {rel} confirmed" in r["log"], r
    v = st.version()
    assert v["current"] == rel and v["previous"] == first and v["pending"] is None, v
    # the same bundle again: nothing to do
    res = run_handler()
    assert res.returncode == 0 and "already the confirmed one" in res.stdout, res.stdout + res.stderr


def case_gui_unconfirmed(sup, first):
    blob = stage(bundle(["gui"]))
    status, r = post_bundle(blob)
    assert status == 202, f"POST /api/bundle: {status} {r}"
    r = wait_rc(st.TEST_SECONDS + 60)
    assert r["rc"] == 1 and "reverted by the supervisor" in r["log"], r
    st.wait_for("back on the first release", lambda v: v.get("release") == first, 30)


def case_refusals(sup, first):
    blob = stage(bundle(["gui"]))
    status, r = post_bundle(blob, token=None)
    assert status == 403, f"no token: {status} {r}"
    status, r = post_bundle(blob, token="wrong")
    assert status == 403, f"wrong token: {status} {r}"
    status, r = post_bundle(blob, sha="0" * 64)
    assert status == 400 and "sha256" in r.get("error", ""), f"wrong SHA: {status} {r}"
    assert bundle_status().get("rc") is None and not bundle_status().get("running")
    status, r = post_bundle(blob)
    assert status == 202, f"first: {status} {r}"
    status, r = post_bundle(blob)
    assert status == 409 and "already running" in r.get("error", ""), f"second: {status} {r}"
    # let the first one end (unconfirmed: reverted) before the next case
    wait_rc(st.TEST_SECONDS + 60)
    # a board without rauc (an older image): 501
    with open(FAKE, "w") as f:
        f.write("")
    os.chmod(FAKE, 0o644)                       # not executable = not there
    status, r = post_bundle(blob)
    assert status == 501 and "no rauc" in r.get("error", ""), f"no rauc: {status} {r}"


def case_core_sim(sup, first):
    stage(bundle(["core"]))
    time.sleep(3)                               # fpga_access.py up
    # the simulated board has no installed manifest: refused, nothing loaded
    res = run_handler()
    assert res.returncode == 1 and "FPGA core refused" in res.stdout \
        and "no manifest" in res.stdout, res.stdout + res.stderr
    # with one of the same periphery (another build): loaded and kept
    man = json.load(open(CORE.replace(".rbf", ".json")))
    old = dict(man, build_id=man["build_id"] - 1000, core_sha256="0" * 64)
    with open(os.path.join(st.RUN, "sim-firmware", "de25_std.core.json"), "w") as f:
        json.dump(old, f)
    res = run_handler()
    assert res.returncode == 0 and f"FPGA core build {man['build_id']} runs" in res.stdout, \
        res.stdout + res.stderr
    status, core = st.request("/api/fpga")
    assert core["installed"]["build_id"] == man["build_id"], core
    assert core["previous"]["build_id"] == old["build_id"], core
    # again: already running, nothing loaded
    res = run_handler()
    assert res.returncode == 0 and "already running" in res.stdout, res.stdout + res.stderr


def case_deploy_tool(sup, first):
    """deploy_bundle.py end to end: checks, uploads, confirms, reports"""
    path = bundle(["gui", "core"])
    stage(path)
    man = json.load(open(CORE.replace(".rbf", ".json")))
    with open(os.path.join(st.RUN, "sim-firmware", "de25_std.core.json"), "w") as f:
        json.dump(dict(man, build_id=man["build_id"] - 1000, core_sha256="0" * 64), f)
    tok = os.path.join(WORK, "token")
    open(tok, "w").write(st.TOKEN)
    tool = os.path.join(HERE, "deploy_bundle.py")
    common = ["--host", "127.0.0.1", "--port", str(st.PORT), "--token-file", tok, "--keys", KEYS]
    res = subprocess.run(["python3", tool, "--bundle", path] + common,
                         capture_output=True, text=True, timeout=200)
    out = res.stdout + res.stderr
    print("      " + "\n      ".join(out.strip().splitlines()))
    assert res.returncode == 0 and "confirmed" in out and "installed in" in out, out
    v = st.version()
    assert v["pending"] is None and v["current"] != first, v
    # a bundle signed by another CA: refused here, before the upload
    other = os.path.join(BUNDLES, "foreign.raucb")
    if not os.path.exists(other):
        keys2 = os.path.join(BUNDLES, "foreign-keys")
        subprocess.run([os.path.join(HERE, "rauc_keys.sh"), keys2], check=True, stdout=subprocess.DEVNULL)
        make({"gui"}, CORE, CORE.replace(".rbf", ".json"), keys2, other)
    res = subprocess.run(["python3", tool, "--bundle", other] + common,
                         capture_output=True, text=True, timeout=60)
    assert res.returncode != 0 and "unable to get local issuer" in res.stdout + res.stderr, \
        res.stdout + res.stderr


def case_unknown_repo(sup, first):
    stage(bundle(["gui"]), extra_section="[image.nothere/x]\nfilename=x.img")
    res = run_handler()
    assert res.returncode == 1 and "unknown artifact repository 'nothere'" in res.stdout, \
        res.stdout + res.stderr
    assert st.version()["pending"] is None, "a refused bundle must not start a GUI test"


CASES = {n[len("case_"):]: f for n, f in globals().items() if n.startswith("case_")}


def main():
    names = sys.argv[1:] or list(CASES)
    bad = set(names) - set(CASES)
    if bad:
        sys.exit(f"unknown case(s) {', '.join(sorted(bad))}; known: {', '.join(CASES)}")
    os.environ["DE25WEB_RAUC"] = FAKE           # the supervisor's children inherit it
    sup = st.Supervisor()
    failed = []
    try:
        for name in names:
            t0 = time.time()
            first = st.fresh_layout(sup)
            try:
                CASES[name](sup, first)
                print(f"PASS  {name} ({time.time() - t0:.0f} s)", flush=True)
            except AssertionError as e:
                failed.append(name)
                print(f"FAIL  {name}: {e}\n      log: {st.log_tail()}", flush=True)
    finally:
        sup.kill()
    print("FAIL: " + " ".join(failed) if failed else "PASS")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
