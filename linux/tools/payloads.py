"""
payloads.py - what goes into a RAUC bundle's artifacts (make_bundle.py), and
into a card image's first GUI release (install_webapp.py):

    pack_release()   linux/webapp/ as a GUI release: the three .py, static/,
                     BOARD, and VERSION with the git state, so every build
                     differs (1.0.0+a1b5e2b)
    pack_core()      the FPGA core and its manifest (make_jic.sh writes both),
                     after the checks the board makes too

(These were deploy_web.py's and deploy_fpga.py's, from before updates went
through RAUC - docs/plan_rauc.md.)
"""
import hashlib
import io
import json
import os
import subprocess
import sys
import tarfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
WEBAPP = os.path.join(HERE, "..", "webapp")
FILES = ("fpga_web.py", "fpga_access.py", "temp_control.py", "VERSION", "BOARD", "static")
OUT = os.path.normpath(os.path.join(HERE, "..", "..", "build", "images"))
CORE_NAME = "de25_std.core.rbf"
MANIFEST_NAME = "de25_std.core.json"
BOARD_NAME = "de25-std"


def git_describe():
    try:
        return subprocess.check_output(
            ["git", "describe", "--always", "--dirty"], cwd=WEBAPP, text=True,
            stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def pack_release(webapp=WEBAPP):
    """a GUI release archive (.tar.gz bytes) of webapp/, and its full version"""
    version = open(os.path.join(webapp, "VERSION")).read().strip()
    desc = git_describe()
    full_version = version + ("+" + desc if desc else "")
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        def add_bytes(name, data):
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mtime = int(time.time())
            info.mode = 0o644
            tar.addfile(info, io.BytesIO(data))
        add_bytes("VERSION", (full_version + "\n").encode())
        for name in FILES:
            if name == "VERSION":
                continue
            tar.add(os.path.join(webapp, name), arcname=name,
                    filter=lambda ti: None if "__pycache__" in ti.name else ti)
    return buf.getvalue(), full_version


def pack_core(core_path, manifest_path):
    """the core and its manifest as a .tar.gz (bytes), and the manifest"""
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
