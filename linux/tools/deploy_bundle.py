#!/usr/bin/env python3
"""
deploy_bundle.py - install a signed RAUC bundle on the DE25-Standard over
the network (docs/plan_rauc.md, step 1).

Checks the bundle here first (signature against the CA in the key
directory, compatible), uploads it (POST /api/bundle with its SHA-256 and the
token), and follows the board's `rauc install` until it ends. A GUI release
in the bundle goes on test on the board: this checks it the way
deploy_web.py does (the version answers, the register file answers with the
board id) and confirms it, which is what lets the install succeed. An FPGA
core is loaded and checked by the board itself. An image (step 2) goes into
the application image not running; the board reboots into it, and this
follows it until that image is confirmed (rsu-confirm) - or reports the
SDM's fallback.

    python3 linux/tools/make_bundle.py gui core && python3 linux/tools/deploy_bundle.py
    python3 linux/tools/deploy_bundle.py --bundle X.raucb --host 10.0.0.5
    python3 linux/tools/deploy_bundle.py --no-confirm        # leave a GUI release on test
    python3 linux/tools/deploy_bundle.py --skip-check X.raucb  # upload without the local check
                                                               # (refusal tests)
"""
import argparse
import glob
import hashlib
import http.client
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from deploy_web import request  # noqa: E402
from make_bundle import COMPATIBLE, OUT, RAUC  # noqa: E402


def local_info(path, keys):
    """the bundle's manifest as RAUC sees it, signature checked against keys"""
    with tempfile.NamedTemporaryFile("w", suffix=".conf") as conf:
        conf.write(f"[system]\ncompatible={COMPATIBLE}\nbootloader=noop\n"
                   f"[keyring]\npath={keys}/ca.cert.pem\ncheck-purpose=codesign\n")
        conf.flush()
        r = subprocess.run([RAUC, "-c", conf.name, "info", "--output-format=shell", path],
                           capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"{path}: {r.stderr.strip().splitlines()[-1] if r.stderr.strip() else 'rauc info failed'}")
    info = {}
    for line in r.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            info[k] = v.strip("'")
    return info


def get(base, path, timeout=5):
    """GET, or None while the server restarts"""
    try:
        status, r = request(base + path, timeout=timeout)
        return r if status == 200 else None
    except (OSError, http.client.HTTPException):
        return None


def confirm_release(base, before_release):
    """the GUI release on test: checked and confirmed, as deploy_web.py does.
    True once confirmed, None while it is not up yet."""
    v = get(base, "/api/version")
    if not v or not v.get("pending") or v.get("release") != v.get("pending") \
            or v.get("release") == before_release:
        return None
    rel = v["release"]
    b = get(base, "/api/board")
    if not b or not b.get("id_ok"):
        return None
    for _ in range(12):     # 503 until all three processes answer
        status, c = request(base + "/api/update/confirm", b"{}", {"Content-Type": "application/json"})
        if status != 503:
            break
        time.sleep(5)
    if status != 200:
        sys.exit(f"confirming {rel} failed ({status}): {c}")
    print(f"   GUI release {rel} answers (design {b.get('git_hash')}): confirmed")
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="192.168.1.223")
    ap.add_argument("--port", type=int, default=80)
    ap.add_argument("--token", default=os.environ.get("DE25WEB_TOKEN"))
    ap.add_argument("--token-file", default=os.path.expanduser("~/.de25web_token_std"))
    ap.add_argument("--bundle", help="default: the newest build/images/de25_std_*.raucb")
    ap.add_argument("--keys", default=os.environ.get("RAUC_KEYS", os.path.expanduser("~/.de25_rauc_keys")))
    ap.add_argument("--skip-check", action="store_true", help="upload without checking the bundle here")
    ap.add_argument("--no-confirm", action="store_true", help="leave a GUI release on test")
    ap.add_argument("--wait", type=float, default=400, help="seconds to wait for the install")
    args = ap.parse_args()
    base = f"http://{args.host}:{args.port}"

    path = args.bundle or max(glob.glob(os.path.join(OUT, "de25_std_*.raucb")),
                              key=os.path.getmtime, default=None)
    if not path:
        sys.exit("no bundle - run make_bundle.py, or give --bundle")
    parts = set()          # unknown with --skip-check
    if args.skip_check:
        print(f">> {os.path.basename(path)} (not checked here)")
    else:
        info = local_info(path, args.keys)
        parts = {info.get(f"RAUC_IMAGE_CLASS_{i}") for i in range(int(info.get("RAUC_MF_IMAGES", "0")))}
        print(f">> {os.path.basename(path)}: {info.get('RAUC_MF_DESCRIPTION')} "
              f"(signature ok, {', '.join(sorted(parts))})")

    # two boards on one LAN: check this is the board the bundle is for
    try:
        status, ver = request(base + "/api/version", timeout=10)
    except (OSError, http.client.HTTPException) as e:
        sys.exit(f"{base} does not answer ({e}) - still booting, or wrong --host?")
    if status != 200 or ver.get("board") != COMPATIBLE:
        sys.exit(f"{base} is {ver.get('board')!r} ({status}), this bundle is for {COMPATIBLE!r} - wrong --host?")
    st = get(base, "/api/bundle")
    if st is None or not st.get("rauc"):
        sys.exit(f"{base} has no rauc (an image from before docs/plan_rauc.md step 1)")
    if st.get("running"):
        sys.exit(f"{base} is already installing a bundle")
    before = ver.get("release")
    rsu_before = get(base, "/api/rsu", timeout=30)
    print(f">> board runs GUI {before}" + (f", image {rsu_before.get('slot')}" if rsu_before and rsu_before.get("slot") else ""))

    token = args.token
    if token is None and os.path.exists(args.token_file):
        token = open(args.token_file).read().strip()
    blob = open(path, "rb").read()
    headers = {"X-Sha256": hashlib.sha256(blob).hexdigest(), "Content-Type": "application/octet-stream"}
    if token:
        headers["X-Token"] = token
    print(f">> uploading {len(blob)} bytes")
    t0 = time.time()
    status, r = request(base + "/api/bundle", blob, headers, timeout=120)
    if status != 202:
        sys.exit(f"bundle refused ({status}): {r.get('error', r)}")

    shown, confirmed = 0, False
    while time.time() - t0 < args.wait:
        time.sleep(2)
        st = get(base, "/api/bundle")
        if st is None:
            continue                            # the GUI restarting into the new release
        log = st.get("log") or ""
        lines = log.splitlines()
        for line in lines[shown:]:
            print("   " + line)
        shown = len(lines)
        # a GUI release from the bundle on test (also with --skip-check,
        # where the parts are unknown): check it and confirm it
        if not confirmed and not args.no_confirm and st.get("running"):
            confirmed = bool(confirm_release(base, before))
        if st.get("rc") is not None:
            if st["rc"] != 0:
                sys.exit(f">> rauc install failed (exit {st['rc']}) - the board keeps what it had")
            print(f">> installed in {time.time() - t0:.0f} s")
            if st.get("reboot"):
                return follow_reboot(base, rsu_before, t0, args.wait)
            return 0
    sys.exit(f"no result within {args.wait:.0f} s")


def follow_reboot(base, before, t0, wait):
    """an image bundle: the board reboots into the slot group that was not
    running. Done once /api/rsu says that image runs and is confirmed;
    the SDM falling back to another image is a failure."""
    was = (before or {}).get("slot")
    print(f">> rebooting from {was} into the other image; waiting for its confirmation")
    deadline, seen_down, last = time.time() + max(wait, 600), False, ""
    while time.time() < deadline:
        time.sleep(5)
        rsu = get(base, "/api/rsu", timeout=10)
        if rsu is None:
            seen_down = True
            continue
        if not seen_down:
            continue                            # still the old boot
        st = rsu.get("status") or {}
        line = (f"image {rsu.get('slot')}, confirm {rsu.get('confirm')!r}, "
                f"fail image {st.get('fail_image')}")
        if line != last:
            print(f"   {time.time() - t0:5.0f} s  {line}")
            last = line
        if rsu.get("slot") and rsu.get("slot") != was and (rsu.get("confirm") or "").startswith("confirmed"):
            print(f">> {rsu['slot']} confirmed, {time.time() - t0:.0f} s after the upload")
            return 0
        if rsu.get("slot") == was or rsu.get("slot") == "FACTORY_IMAGE":
            if (rsu.get("confirm") or "").startswith(("confirmed", "factory")):
                sys.exit(f">> the new image did not come up healthy: the SDM fell back to {rsu.get('slot')}")
    sys.exit(f"no confirmation within {max(wait, 600):.0f} s; last: {last or 'no answer'}")


if __name__ == "__main__":
    sys.exit(main())
