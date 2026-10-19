#!/usr/bin/env python3
"""
deploy_fpga.py - load a new FPGA core onto the running DE25-Standard over
the network, without a reboot (HPS-first images; plan Phase E). Adapted
from the DE25-Nano's.

Packs the core and its manifest (linux/make_jic.sh writes both:
de25_std.core.rbf, de25_std.core.json) into a bundle and uploads it
(POST /api/fpga with its SHA-256 and the token). On the board
fpga_access.py refuses a core from a different build than the first stage
in QSPI (the manifest's periphery hash: pins, HPS, DDR), a core for
another board (the manifest's "board") and a truncated or corrupt one,
keeps the running core, loads the new one (~2 s: register traffic pauses), checks the
board id, the board variant and the build id (register 19), and loads the
previous core back if any of that fails. A core that loads is also copied
to the SD card, so the next power-on keeps it.

    python3 linux/tools/deploy_fpga.py                    # build/images' core, to 192.168.1.223
    python3 linux/tools/deploy_fpga.py --core X.core.rbf --manifest X.core.json
    python3 linux/tools/deploy_fpga.py --pack-only core.tar.gz
    python3 linux/tools/deploy_fpga.py --force            # the board's core has no manifest yet
    python3 linux/tools/deploy_fpga.py --reload           # load the installed core again
"""
import argparse
import hashlib
import io
import json
import os
import sys
import tarfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from deploy_web import request  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "build", "images")
CORE_NAME = "de25_std.core.rbf"
MANIFEST_NAME = "de25_std.core.json"
BOARD_NAME = "de25-std"


def pack_bundle(core_path, manifest_path):
    """The bundle (bytes) and its manifest, after the checks the board makes too."""
    core = open(core_path, "rb").read()
    raw = open(manifest_path, "rb").read()
    manifest = json.loads(raw)
    if len(core) != manifest["core_size"] or hashlib.sha256(core).hexdigest() != manifest["core_sha256"]:
        sys.exit(f"{core_path} does not match {manifest_path} - rerun make_jic.sh")
    if manifest.get("board") != BOARD_NAME:
        sys.exit(f"{manifest_path} is for {manifest.get('board')!r}, not {BOARD_NAME!r}")
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for name, data in ((MANIFEST_NAME, raw), (CORE_NAME, core)):
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mtime = int(time.time())
            info.mode = 0o644
            tar.addfile(info, io.BytesIO(data))
    return buf.getvalue(), manifest


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="192.168.1.223")
    ap.add_argument("--port", type=int, default=80)
    ap.add_argument("--token", default=os.environ.get("DE25WEB_TOKEN"))
    ap.add_argument("--token-file", default=os.path.expanduser("~/.de25web_token_std"))
    ap.add_argument("--core", default=os.path.join(OUT, CORE_NAME))
    ap.add_argument("--manifest", default=None, help="default: the .json beside --core")
    ap.add_argument("--pack-only", metavar="OUT", help="write the bundle and stop")
    ap.add_argument("--force", action="store_true",
                    help="install although the board's core has no manifest, or another periphery")
    ap.add_argument("--reload", action="store_true", help="only load the installed core again")
    args = ap.parse_args()

    token = args.token
    if token is None and os.path.exists(args.token_file):
        token = open(args.token_file).read().strip()
    headers = {"X-Token": token} if token else {}
    base = f"http://{args.host}:{args.port}"

    if args.reload:
        status, r = request(base + "/api/fpga/reload", b"", headers, timeout=150)
        if status != 200:
            sys.exit(f"reload failed ({status}): {r.get('error', r)}")
        print(f">> reloaded: build {r['build_id']}, {r['seconds']} s")
        return 0

    manifest_path = args.manifest or args.core.replace(".rbf", ".json")
    blob, manifest = pack_bundle(args.core, manifest_path)
    sha = hashlib.sha256(blob).hexdigest()
    built = time.strftime("%F %T", time.localtime(manifest["build_id"]))
    if args.pack_only:
        with open(args.pack_only, "wb") as f:
            f.write(blob)
        print(f"{args.pack_only}: build {manifest['build_id']} ({built}), {len(blob)} bytes, sha256 {sha}")
        return 0

    # two boards on one LAN: check this is the board the core is for
    # (the board refuses it anyway; this fails before the upload)
    status, ver = request(base + "/api/version")
    if status != 200 or ver.get("board") != BOARD_NAME:
        sys.exit(f"{base} is {ver.get('board')!r} ({status}), this core is for {BOARD_NAME!r} - wrong --host?")

    status, before = request(base + "/api/fpga")
    if status != 200:
        sys.exit(f"{base}: /api/fpga answered {status}: {before}")
    inst = before.get("installed") or {}
    print(f">> board runs build {before.get('running_build_id')} "
          f"(installed {inst.get('build_id', 'without a manifest')})")
    if not args.force and inst.get("periphery_sha256") not in (None, manifest["periphery_sha256"]):
        sys.exit(f"build {manifest['build_id']} needs periphery {manifest['periphery_sha256'][:12]}, "
                 f"the board has {inst['periphery_sha256'][:12]} - program the .jic (or RSU) first")

    headers.update({"X-Sha256": sha, "Content-Type": "application/gzip"})
    if args.force:
        headers["X-Force"] = "1"
    print(f">> uploading build {manifest['build_id']} ({built}, git {manifest.get('git', '?')}), "
          f"{len(blob)} bytes")
    status, r = request(base + "/api/fpga", blob, headers, timeout=150)
    if status != 200 or not r.get("ok"):
        msg = f"core not installed ({status}): {r.get('error', r)}"
        if r.get("rolled_back"):
            msg += f" - the previous core is back (build {r['previous']['build_id']})"
        elif "rollback_error" in r:
            msg += f" - and the previous core did not load either: {r['rollback_error']}"
        sys.exit(msg)
    boot = r.get("boot", {})
    print(f">> build {r['build_id']} running, loaded in {r['seconds']} s; SD card copy "
          + ("written" if boot.get("written") else f"NOT written ({boot.get('error', 'no /boot')})"))

    # the GUI samples the registers 20 times a second: the first answers can
    # still be from the pause
    deadline = time.time() + 10
    while True:
        status, board = request(base + "/api/board")
        if status == 200 and board.get("id_ok") and board.get("build_id") == manifest["build_id"]:
            break
        if time.time() > deadline:
            sys.exit(f"the GUI does not see the new core ({status}): "
                     f"{board.get('error', board.get('build_id'))}")
        time.sleep(0.5)
    print(f">> GUI sees build {board['build_id']}, fan {board['fan']['target_rpm']} rpm, "
          f"blinker {board['blinker']['name']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
