#!/usr/bin/env python3
"""
deploy_web.py - update the DE25-Standard's web GUI over the network.

Packs linux/webapp/ (the three .py, VERSION, BOARD, static/) into a release, uploads
it (POST /api/update with its SHA-256 and the token), waits for the board's
server to restart into it, checks it (the version, the register file
answering with the board id), and confirms it. Anything short of that and
the board's supervisor reverts to the previous release by itself once the
test time runs out (see linux/board/de25web-supervisor.sh).

    python3 linux/tools/deploy_web.py                      # to 192.168.1.223
    python3 linux/tools/deploy_web.py --host 10.0.0.5 --token-file ~/.de25web_token_std
    python3 linux/tools/deploy_web.py --pack-only out.tar.gz
    python3 linux/tools/deploy_web.py --no-confirm         # leave it on test

The one-time install (python3, the supervisor, init) is install_webapp.py.
"""
import argparse
import hashlib
import io
import json
import os
import select
import subprocess
import sys
import tarfile
import time
import http.client
import urllib.parse

WEBAPP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "webapp")
EARLY_ANSWER_S = 1.0     # request(): how long a POST waits for an answer before its body
FILES = ("fpga_web.py", "fpga_access.py", "temp_control.py", "VERSION", "BOARD", "static")


def git_describe():
    try:
        return subprocess.check_output(
            ["git", "describe", "--always", "--dirty"], cwd=WEBAPP, text=True,
            stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def pack_release(webapp=WEBAPP):
    """A release archive (bytes) of webapp/: the files the board runs, with
    VERSION = the file's version plus the git state, so every build differs."""
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
            path = os.path.join(webapp, name)
            tar.add(path, arcname=name,
                    filter=lambda ti: None if "__pycache__" in ti.name else ti)
    return buf.getvalue(), full_version


def request(url, data=None, headers=None, timeout=10):
    """(status, JSON reply). A POST's headers go first, then a short wait: the
    board answers a refusal it can make from them (token, size) at once and
    closes without reading the body - sending the body then would end in a
    broken pipe instead of that answer."""
    u = urllib.parse.urlsplit(url)
    c = http.client.HTTPConnection(u.hostname, u.port or 80, timeout=timeout)
    try:
        c.putrequest("POST" if data is not None else "GET", u.path + ("?" + u.query if u.query else ""))
        for k, v in dict(headers or {}, **({"Content-Length": str(len(data))} if data is not None else {})).items():
            c.putheader(k, v)
        c.endheaders()
        if data and not select.select([c.sock], [], [], EARLY_ANSWER_S)[0]:
            c.sock.sendall(data)
        r = c.getresponse()
        body = r.read()
    finally:
        c.close()
    try:
        return r.status, json.loads(body or b"{}")
    except ValueError:
        return r.status, {"error": body.decode(errors="replace")}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="192.168.1.223")
    ap.add_argument("--port", type=int, default=80)
    ap.add_argument("--token", default=os.environ.get("DE25WEB_TOKEN"))
    ap.add_argument("--token-file", default=os.path.expanduser("~/.de25web_token_std"))
    ap.add_argument("--pack-only", metavar="OUT", help="write the release archive and stop")
    ap.add_argument("--no-confirm", action="store_true", help="leave the release on test")
    ap.add_argument("--wait", type=float, default=60, help="seconds to wait for the restart")
    args = ap.parse_args()

    blob, version = pack_release()
    sha = hashlib.sha256(blob).hexdigest()
    if args.pack_only:
        with open(args.pack_only, "wb") as f:
            f.write(blob)
        print(f"{args.pack_only}: {version}, {len(blob)} bytes, sha256 {sha}")
        return 0

    token = args.token
    if token is None and os.path.exists(args.token_file):
        token = open(args.token_file).read().strip()
    base = f"http://{args.host}:{args.port}"

    status, before = request(base + "/api/version")
    if status != 200:
        sys.exit(f"{base}: /api/version answered {status}: {before}")
    print(f">> board runs {before.get('release')} (previous {before.get('previous')})")
    # two boards on one LAN: check this is the board the release is for
    # (releases before Phase D only report it in /api/board)
    want = open(os.path.join(WEBAPP, "BOARD")).read().strip()
    there = before.get("board") or request(base + "/api/board")[1].get("board")
    if there != want:
        sys.exit(f"{base} is {there!r}, this release is for {want!r} - wrong --host?")

    headers = {"X-Sha256": sha, "Content-Type": "application/gzip"}
    if token:
        headers["X-Token"] = token
    print(f">> uploading {version} ({len(blob)} bytes)")
    status, r = request(base + "/api/update", blob, headers, timeout=60)
    if status != 202:
        sys.exit(f"update refused ({status}): {r.get('error', r)}")
    rel = r["installed"]
    print(f">> installed as {rel}, waiting for the restart")

    deadline = time.time() + args.wait
    now = None
    while time.time() < deadline:
        time.sleep(1)
        try:
            status, now = request(base + "/api/version", timeout=3)
        except (OSError, http.client.HTTPException):
            continue
        if status == 200 and now.get("release") == rel:
            break
    else:
        sys.exit(f"the board did not come back on {rel} within {args.wait:.0f} s "
                 f"(it reverts by itself if the test fails); last answer: {now}")

    status, board = request(base + "/api/board")
    if status != 200 or not board.get("id_ok"):
        sys.exit(f"{rel} is running but the board check failed ({status}): {board} - "
                 "not confirming; the supervisor will revert it")
    print(f">> {rel} answers: design {board['git_hash']}, blinker {board['blinker']['name']}")

    if args.no_confirm:
        print(">> left on test (--no-confirm): confirm from the GUI or it reverts")
        return 0
    # the server confirms only once all three processes answer - the
    # temperature controller can take a few seconds longer than the server
    for _ in range(12):
        status, c = request(base + "/api/update/confirm", b"{}", {"Content-Type": "application/json"})
        if status != 503:
            break
        time.sleep(5)
    if status != 200:
        sys.exit(f"confirm failed ({status}): {c}")
    print(f">> confirmed {rel}" if c.get("confirmed") else f">> {rel} was already confirmed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
