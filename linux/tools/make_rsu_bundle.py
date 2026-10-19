#!/usr/bin/env python3
"""
make_rsu_bundle.py - pack an RSU update for the DE25-Standard: everything
one QSPI application slot needs, with a manifest (plan F3; from the
DE25-Nano's).

    ./build.sh jic                               # RSU layout: writes the inputs
    python3 linux/tools/make_rsu_bundle.py       # -> build/images/de25_std_rsu_<build>.tar.gz
    python3 linux/tools/make_rsu_bundle.py --check BUNDLE   # verify one

The bundle (.tar.gz):
    rsu.json             the manifest (below)
    app.rpd              the application image: phase 1 + SPL, start address
                         0, bitswapped - librsu relocates it into the slot
    u-boot.itb           the slot's U-Boot (QSPI SSBL.<slot>, card
                         u-boot_<slot>.itb - F2)
    de25_std.core.rbf    the slot's FPGA core (HPS-first: U-Boot's preboot
                         loads it, fpga_access.py reloads it)
    de25_std.core.json   the core's manifest (make_jic.sh)

rsu.json: format, kind "de25_std_rsu", board "de25-std" (the board refuses
a bundle for another one), build_id and periphery_sha256 (from
the core's manifest - all three files come from one build), git, built, and
per file its size and SHA-256. The core is only valid on the phase 1 it was
built with, so a bundle is all or nothing.

Reproducible: fixed member order, mtime (the build id), owner and mode, and
a gzip header without a timestamp - the same inputs give the same bytes.
"""
import argparse
import gzip
import hashlib
import io
import json
import os
import sys
import tarfile

BUILD = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "build"))
OUT = os.path.join(BUILD, "images")
KIND = "de25_std_rsu"
BOARD = "de25-std"
# member name -> default input under build/ (make_jic.sh, build_de25_linux.sh)
FILES = {
    "app.rpd": "images/de25_std_app.rpd",
    "u-boot.itb": "linux/out/u-boot.itb",
    "de25_std.core.rbf": "images/de25_std.core.rbf",
    "de25_std.core.json": "images/de25_std.core.json",
}
MANIFEST = "rsu.json"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def pack(inputs):
    data = {name: open(path, "rb").read() for name, path in inputs.items()}
    core_manifest = json.loads(data["de25_std.core.json"])
    if core_manifest.get("core_sha256") != sha256(data["de25_std.core.rbf"]):
        sys.exit("de25_std.core.rbf does not match de25_std.core.json - rerun make_jic.sh")
    if core_manifest.get("board") != BOARD:
        sys.exit(f"the core is for {core_manifest.get('board')!r}, not {BOARD!r}")
    build_id = int(core_manifest["build_id"])
    manifest = {
        "format": 1,
        "kind": KIND,
        "board": BOARD,
        "build_id": build_id,
        "periphery_sha256": core_manifest["periphery_sha256"],
        "git": core_manifest.get("git", ""),
        "built": core_manifest.get("built", ""),
        "files": {name: {"size": len(data[name]), "sha256": sha256(data[name])} for name in FILES},
    }
    raw = (json.dumps(manifest, indent=1, sort_keys=True) + "\n").encode()
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0, filename="") as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.PAX_FORMAT) as tar:
            for name, blob in [(MANIFEST, raw)] + [(n, data[n]) for n in FILES]:
                info = tarfile.TarInfo(name)
                info.size, info.mtime, info.mode = len(blob), build_id, 0o644
                info.uid = info.gid = 0
                info.uname = info.gname = "root"
                tar.addfile(info, io.BytesIO(blob))
    return buf.getvalue(), manifest


def check(blob):
    """the manifest of a bundle whose files all match it, else SystemExit"""
    try:
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
            members = {m.name: tar.extractfile(m).read() for m in tar.getmembers() if m.isfile()}
    except (OSError, EOFError, tarfile.TarError) as e:
        sys.exit(f"not an RSU bundle: {e}")
    if MANIFEST not in members:
        sys.exit("not an RSU bundle: no " + MANIFEST)
    manifest = json.loads(members[MANIFEST])
    if manifest.get("kind") != KIND or manifest.get("board") != BOARD:
        sys.exit(f"not a {KIND} bundle for {BOARD}: {manifest.get('kind')!r}, {manifest.get('board')!r}")
    for name, want in manifest["files"].items():
        got = members.get(name)
        if got is None or len(got) != want["size"] or sha256(got) != want["sha256"]:
            sys.exit(f"{name} does not match the manifest (missing, truncated or corrupt)")
    return manifest


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", help="bundle path (default build/images/de25_std_rsu_<build>.tar.gz)")
    ap.add_argument("--check", metavar="BUNDLE", help="verify a bundle and print its manifest")
    for name, default in FILES.items():
        ap.add_argument("--" + name.replace(".", "-"), dest=name, default=os.path.join(BUILD, default),
                        help=f"default build/{default}")
    args = ap.parse_args()

    if args.check:
        print(json.dumps(check(open(args.check, "rb").read()), indent=1))
        return 0
    blob, manifest = pack({name: getattr(args, name) for name in FILES})
    out = args.out or os.path.join(OUT, f"de25_std_rsu_{manifest['build_id']}.tar.gz")
    with open(out, "wb") as f:
        f.write(blob)
    print(f"{out}: build {manifest['build_id']} ({manifest['built']}, git {manifest['git']}), "
          f"{len(blob)} bytes, sha256 {sha256(blob)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
