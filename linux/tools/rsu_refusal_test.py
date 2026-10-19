#!/usr/bin/env python3
"""
rsu_refusal_test.py - the RSU updates the DE25-Standard must turn away
(plan F7), on the board: each one is refused before P1 is erased, and the
board is left as it was (same image, P1 still enabled, nothing staged).

    python3 linux/tools/rsu_refusal_test.py                 # newest bundle in build/images
    python3 linux/tools/rsu_refusal_test.py --bundle X.tar.gz --host 10.0.0.5

Every case starts from a good bundle (make_rsu_bundle.py) and breaks one
thing:
    no_token         no X-Token                                 403
    bad_token        a wrong X-Token                            403
    wrong_sha        X-Sha256 not the upload's                  400
    too_big          Content-Length over the 32 MiB limit       400
    not_gzip         random bytes                               409
    cut_archive      the .tar.gz cut in half                    409
    core_bundle      a deploy_fpga.py core bundle               409
    nano_bundle      board "de25-nano" in rsu.json              409
    wrong_kind       kind "de25_std_core" in rsu.json           409
    truncated_part   app.rpd cut short, rsu.json as it was      409
    corrupt_part     a byte of u-boot.itb flipped               409
    missing_part     no de25_std.core.rbf                       409
    slot_overflow    app.rpd over P1's size, rsu.json matching  409

Never a corrupt image with a matching manifest: that one would be written.
"""
import argparse
import glob
import gzip
import hashlib
import http.client
import io
import json
import os
import sys
import tarfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from deploy_web import request  # noqa: E402
from make_rsu_bundle import BOARD, OUT, check  # noqa: E402

RSU_BUNDLE_MAX = 32 << 20      # fpga_web.py
P1_SIZE = 0x100000             # make_jic.sh: P1 0x400000, SSBL.FACTORY_IM 0x500000


def unpack(blob):
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
        return [(m.name, tar.extractfile(m).read()) for m in tar.getmembers() if m.isfile()]


def repack(members):
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.PAX_FORMAT) as tar:
            for name, data in members:
                info = tarfile.TarInfo(name)
                info.size, info.mode = len(data), 0o644
                tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


def edit(blob, files=None, manifest=None, drop=(), rehash=False):
    """the bundle with files replaced, manifest fields changed, members
    dropped; rehash: the manifest made to match the new files"""
    members = unpack(blob)
    man = json.loads(dict(members)["rsu.json"])
    man.update(manifest or {})
    out = []
    for name, data in members:
        if name in drop:
            continue
        data = (files or {}).get(name, data)
        if rehash and name in man["files"]:
            man["files"][name] = {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        out.append((name, data))
    return repack([(n, (json.dumps(man, indent=1) + "\n").encode() if n == "rsu.json" else d)
                   for n, d in out])


def core_bundle(blob):
    members = dict(unpack(blob))
    return repack([(n, members[n]) for n in ("de25_std.core.json", "de25_std.core.rbf")])


def post(base, blob, token, sha=None, length=None):
    """POST /api/rsu; length: only the headers, with that Content-Length"""
    headers = {"X-Sha256": sha or hashlib.sha256(blob).hexdigest(), "Content-Type": "application/gzip",
               "X-No-Reboot": "1"}         # belt and braces: a case that got written must not reboot
    if token is not None:
        headers["X-Token"] = token
    if length is None:
        return request(base + "/api/rsu", blob, headers, timeout=120)
    host, port = base.split("//")[1].split(":")
    c = http.client.HTTPConnection(host, int(port), timeout=30)
    c.putrequest("POST", "/api/rsu")
    for k, v in dict(headers, **{"Content-Length": str(length)}).items():
        c.putheader(k, v)
    c.endheaders()
    r = c.getresponse()
    code, body = r.status, json.loads(r.read() or b"{}")
    c.close()
    return code, body


def board_state(base):
    code, rsu = request(base + "/api/rsu", timeout=30)
    assert code == 200, (code, rsu)
    st = rsu.get("status") or {}
    return (st.get("current_image"), st.get("fail_image"), rsu.get("p1_priority"), rsu.get("confirm"))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="192.168.1.223")
    ap.add_argument("--port", type=int, default=80)
    ap.add_argument("--token-file", default=os.path.expanduser("~/.de25web_token_std"))
    ap.add_argument("--bundle", help="default: the newest build/images/de25_std_rsu_*.tar.gz")
    ap.add_argument("cases", nargs="*")
    args = ap.parse_args()
    base = f"http://{args.host}:{args.port}"
    token = open(args.token_file).read().strip()
    path = args.bundle or max(glob.glob(os.path.join(OUT, "de25_std_rsu_*.tar.gz")),
                              key=os.path.getmtime, default=None)
    if not path:
        sys.exit("no bundle - run make_rsu_bundle.py, or give --bundle")
    good = open(path, "rb").read()
    check(good)
    members = dict(unpack(good))

    code, ver = request(base + "/api/version", timeout=10)
    if code != 200 or ver.get("board") != BOARD:
        sys.exit(f"{base} is {ver.get('board')!r} ({code}), not {BOARD!r}")

    flipped = bytearray(members["u-boot.itb"])
    flipped[len(flipped) // 2] ^= 0x01
    cases = {
        "no_token":       (403, lambda: post(base, good, None)),
        "bad_token":      (403, lambda: post(base, good, "not-the-token")),
        "wrong_sha":      (400, lambda: post(base, good, token, sha="0" * 64)),
        "too_big":        (400, lambda: post(base, b"", token, length=RSU_BUNDLE_MAX + 1)),
        "not_gzip":       (409, lambda: post(base, os.urandom(4096), token)),
        "cut_archive":    (409, lambda: post(base, good[:len(good) // 2], token)),
        "core_bundle":    (409, lambda: post(base, core_bundle(good), token)),
        "nano_bundle":    (409, lambda: post(base, edit(good, manifest={"board": "de25-nano"}), token)),
        "wrong_kind":     (409, lambda: post(base, edit(good, manifest={"kind": "de25_std_core"}), token)),
        "truncated_part": (409, lambda: post(base, edit(good, files={"app.rpd": members["app.rpd"][:-4096]}), token)),
        "corrupt_part":   (409, lambda: post(base, edit(good, files={"u-boot.itb": bytes(flipped)}), token)),
        "missing_part":   (409, lambda: post(base, edit(good, drop=("de25_std.core.rbf",)), token)),
        "slot_overflow":  (409, lambda: post(base, edit(good, files={"app.rpd": members["app.rpd"]
                                             + b"\xff" * (P1_SIZE + 4096 - len(members["app.rpd"]))},
                                             rehash=True), token)),
    }
    names = args.cases or list(cases)
    bad = set(names) - set(cases)
    if bad:
        sys.exit(f"unknown case(s) {', '.join(sorted(bad))}; known: {', '.join(cases)}")

    before = board_state(base)
    print(f">> board: image {before[0]}, fail {before[1]}, P1 priority {before[2]}, {before[3]!r}")
    failed = []
    for name in names:
        want, send = cases[name]
        code, r = send()
        after = board_state(base)
        written = (r.get("steps") or []) if isinstance(r, dict) else []
        ok = code == want and after == before and not written
        print(f"{'PASS' if ok else 'FAIL'}  {name:15s} {code}  {r.get('error', r)}"
              + ("" if after == before else f"  board now {after}") + (f"  steps {written}" if written else ""),
              flush=True)
        if not ok:
            failed.append(name)
    print("FAIL: " + " ".join(failed) if failed else "PASS")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
