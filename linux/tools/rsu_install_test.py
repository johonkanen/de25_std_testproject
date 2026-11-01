#!/usr/bin/env python3
"""
rsu_install_test.py - fpga_access.py's install_rsu (the RAUC image hook's
QSPI write) against a fake rsu_client with the board's A/B layout, on any
host:

    fits       a core that fits CORE.P2 is written there, as before
    oversize   a core larger than CORE.P2 (the scope's block RAM made the
               core 1.23 MB, the slot holds 1.11 MB): the update goes on,
               CORE.P2 is erased and never written (no older core left there
               to load with the new image), the card and /lib/firmware get
               the core, P2 is written and verified

    python3 linux/tools/rsu_install_test.py
"""
import hashlib
import io
import json
import os
import sys
import tarfile
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "webapp"))
import fpga_access as fa  # noqa: E402

# the board's partitions (make_jic.sh, RSU=1 AB=1): name, offset, size
LAYOUT = [("P1", 0x400000, 0x100000), ("SSBL.P1", 0x600000, 0x100000),
          ("P2", 0x700000, 0x100000), ("SSBL.P2", 0x800000, 0x100000),
          ("UBOOT", 0xA00000, 0x100000), ("CORE.FACTORY_IM", 0xC00000, 0x110000),
          ("CORE.P1", 0xD10000, 0x110000), ("CORE.P2", 0xE20000, 0x110000)]
calls = []


def fake_rsu_client(*args, timeout=300):
    args = [str(a) for a in args]
    calls.append(args)
    if args == ["--count"]:
        return True, f"number of slots is {len(LAYOUT)}"
    if args[0] == "--list":
        name, off, size = LAYOUT[int(args[1])]
        return True, f"NAME: {name}\nOFFSET: 0x{off:016x}\nSIZE: 0x{size:08x}\nPRIORITY: [disabled]"
    return True, "Operation completed"


def bundle(path, core_size):
    files = {"app.rpd": os.urandom(4096), "u-boot.itb": os.urandom(2048),
             fa.CORE_NAME: os.urandom(core_size),
             fa.MANIFEST_NAME: json.dumps({"board": fa.BOARD_NAME, "build_id": 42}).encode()}
    manifest = {"kind": fa.RSU_KIND, "board": fa.BOARD_NAME, "build_id": 42,
                "files": {n: {"size": len(d), "sha256": hashlib.sha256(d).hexdigest()}
                          for n, d in files.items()}}
    files[fa.RSU_MANIFEST] = json.dumps(manifest).encode()
    with tarfile.open(path, "w:gz") as tar:
        for n, d in files.items():
            info = tarfile.TarInfo(n)
            info.size = len(d)
            tar.addfile(info, io.BytesIO(d))
    return files


def run(name, core_size, tmp):
    calls.clear()
    firmware = os.path.join(tmp, name, "firmware", "rsu", "running")
    boot = os.path.join(tmp, name, "boot")
    os.makedirs(firmware)
    os.makedirs(boot)
    files = bundle(os.path.join(tmp, name + ".tar.gz"), core_size)
    a = fa.Access(fa.SimBridge(), firmware=firmware, boot=boot, slot="P1")
    a.sim = True                         # the card: a plain directory, no mount
    r = a.install_rsu(os.path.join(tmp, name + ".tar.gz"), reboot=False)
    card = os.path.join(boot, "de25_std_P2.core.rbf")
    lib = os.path.join(os.path.dirname(firmware), "P2", fa.CORE_NAME)
    return r, calls[:], card, lib, files


def main():
    fa.rsu_client = fake_rsu_client
    failures = 0

    def check(ok, text):
        nonlocal failures
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}  {text}")

    # rsu_client takes slot numbers: the place in the layout
    core_p2, p2 = (str([n for n, _, _ in LAYOUT].index(x)) for x in ("CORE.P2", "P2"))
    with tempfile.TemporaryDirectory() as tmp:
        for name, size in (("fits", 0x100000), ("oversize", 1228800)):
            r, raw, card, lib, files = run(name, size, tmp)
            core_erase = any(c[0] == "--erase" and c[-1] == core_p2 for c in raw)
            core_write = any(c[0] == "--add-raw" and c[-1] == core_p2 for c in raw)
            p2_written = any(c[0] == "--add" and c[-1] == p2 for c in raw)
            p2_verified = any(c[0] == "--verify" and c[-1] == p2 for c in raw)
            on_card = os.path.isfile(card) and open(card, "rb").read() == files[fa.CORE_NAME]
            in_lib = os.path.isfile(lib) and open(lib, "rb").read() == files[fa.CORE_NAME]
            want_write = name == "fits"
            check(r.get("ok") and r.get("slot") == "P2",
                  f"{name} ({size} bytes): install {'ok' if r.get('ok') else r.get('error')}, slot {r.get('slot')}")
            check(core_erase and core_write == want_write,
                  f"{name}: CORE.P2 erased {core_erase}, written {core_write} (want {want_write})")
            check(on_card and in_lib, f"{name}: core on the card {on_card}, in /lib/firmware {in_lib}")
            check(p2_written and p2_verified, f"{name}: P2 written {p2_written}, verified {p2_verified}")
    print("PASS" if not failures else f"{failures} FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
