#!/usr/bin/env python3
"""
deploy_rsu.py - put a whole new FPGA image on the DE25-Standard over the
network (remote system update, plan F6; from the DE25-Nano's).

Uploads an RSU bundle (linux/tools/make_rsu_bundle.py: the application
image, its U-Boot and its FPGA core) with its SHA-256 and the token
(POST /api/rsu). The board writes it to QSPI slot P1 - P1 erased first, so a
power cut boots the factory image - and reboots into it. Then this follows
the reboot: the image counts once the board's rsu-confirm has confirmed it
(GUI up, board id read over LWH2F) and the running build id is the
bundle's; if it never comes up healthy, the watchdog makes the SDM fall back
to the factory image, and this reports that.

    ./build.sh jic && python3 linux/tools/make_rsu_bundle.py
    python3 linux/tools/deploy_rsu.py                       # newest bundle in build/images
    python3 linux/tools/deploy_rsu.py --bundle X.tar.gz --host 10.0.0.5
    python3 linux/tools/deploy_rsu.py --no-reboot           # write P1 only
    python3 linux/tools/deploy_rsu.py --status              # what the board runs

One application slot: a failed update leaves the board on the factory
image (its own U-Boot and core), from where a good bundle goes in again.
"""
import argparse
import glob
import hashlib
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from deploy_web import request  # noqa: E402
from make_rsu_bundle import BOARD, OUT, check  # noqa: E402

FACTORY, P1 = 0x220000, 0x400000


def status(base):
    """(rsu, fpga) from the board, or (None, None) while it does not answer"""
    try:
        s1, rsu = request(base + "/api/rsu", timeout=10)
        s2, fpga = request(base + "/api/fpga", timeout=10)
    except OSError:
        return None, None
    if s1 != 200 or s2 != 200:
        return None, None
    return rsu, fpga


def image_of(rsu):
    st = rsu.get("status") or {}
    try:
        return int(st.get("current_image", "0"), 16), int(st.get("fail_image", "0"), 16)
    except ValueError:
        return None, None


def describe(rsu, fpga):
    cur, fail = image_of(rsu)
    inst = rsu.get("installed") or {}
    name = {FACTORY: "factory", P1: "P1"}.get(cur, hex(cur) if cur is not None else "?")
    p1 = (f"P1 holds build {inst.get('build_id', '?')}" if rsu.get("p1_priority") not in ("[disabled]",)
          else "P1 is empty (erased or disabled)")
    return (f"image {name}, build {fpga.get('running_build_id')}, confirm {rsu.get('confirm')!r}, "
            f"{p1}" + (f", FAILED image {fail:#x}" if fail else ""))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="192.168.1.223")
    ap.add_argument("--port", type=int, default=80)
    ap.add_argument("--token", default=os.environ.get("DE25WEB_TOKEN"))
    ap.add_argument("--token-file", default=os.path.expanduser("~/.de25web_token_std"))
    ap.add_argument("--bundle", help="default: the newest build/images/de25_std_rsu_*.tar.gz")
    ap.add_argument("--no-reboot", action="store_true", help="write P1, do not reboot into it")
    ap.add_argument("--status", action="store_true", help="only show what the board runs")
    ap.add_argument("--wait", type=float, default=600, help="seconds to wait for the confirmation")
    args = ap.parse_args()
    base = f"http://{args.host}:{args.port}"

    # two boards on one LAN: check this is the board the bundle is for
    code, ver = request(base + "/api/version", timeout=10)
    if code != 200 or ver.get("board") != BOARD:
        sys.exit(f"{base} is {ver.get('board')!r} ({code}), the bundles here are for {BOARD!r} - wrong --host?")
    rsu, fpga = status(base)
    if rsu is None:
        sys.exit(f"{base} does not answer /api/rsu")
    if args.status:
        print(">> " + describe(rsu, fpga))
        return 0
    if not rsu.get("rsu"):
        sys.exit("the board has no RSU flash layout (make_jic.sh RSU=1, rsu_client)")

    path = args.bundle or max(glob.glob(os.path.join(OUT, "de25_std_rsu_*.tar.gz")),
                              key=os.path.getmtime, default=None)
    if not path:
        sys.exit("no bundle - run make_rsu_bundle.py, or give --bundle")
    blob = open(path, "rb").read()
    manifest = check(blob)
    build = manifest["build_id"]
    print(f">> board: {describe(rsu, fpga)}")
    print(f">> bundle {os.path.basename(path)}: build {build} ({manifest['built']}, git {manifest['git']})")

    token = args.token
    if token is None and os.path.exists(args.token_file):
        token = open(args.token_file).read().strip()
    headers = {"X-Sha256": hashlib.sha256(blob).hexdigest(), "Content-Type": "application/gzip"}
    if token:
        headers["X-Token"] = token
    if args.no_reboot:
        headers["X-No-Reboot"] = "1"
    print(f">> uploading {len(blob)} bytes; the board writes P1 (a few minutes)")
    t0 = time.time()
    code, r = request(base + "/api/rsu", blob, headers, timeout=900)
    if code != 200 or not r.get("ok"):
        sys.exit(f"update not written ({code}): {r.get('error', r)}" + (f" - {r['note']}" if r.get("note") else ""))
    print(f">> written in {r['seconds']} s ({', '.join(r['steps'])})")
    if args.no_reboot:
        print(">> not rebooting (--no-reboot): the new image runs after the next reboot")
        return 0

    print(">> the board reboots into it; waiting for rsu-confirm")
    deadline, seen_down, last = time.time() + args.wait, False, ""
    while time.time() < deadline:
        time.sleep(5)
        rsu, fpga = status(base)
        if rsu is None:
            seen_down = True
            continue
        if not seen_down:
            continue                       # still the old boot, before the reboot
        cur, fail = image_of(rsu)
        line = describe(rsu, fpga)
        if line != last:
            print(f"   {time.time() - t0:5.0f} s  {line}")
            last = line
        confirm = rsu.get("confirm") or ""
        if cur == P1 and confirm.startswith("confirmed") and fpga.get("running_build_id") == build:
            print(f">> build {build} confirmed in P1, {time.time() - t0:.0f} s after the upload")
            return 0
        if cur == FACTORY and fail == P1:
            sys.exit(f">> P1 did not come up healthy: the SDM fell back to the factory image "
                     f"(state {rsu['status'].get('state')}). Fix the image and deploy again; "
                     "rsu_client --clear-error-status clears the record")
    sys.exit(f"no confirmation within {args.wait:.0f} s; last: {last or 'no answer'}")


if __name__ == "__main__":
    sys.exit(main())
