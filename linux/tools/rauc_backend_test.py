#!/usr/bin/env python3
"""
rauc_backend_test.py - RAUC's boot backend (linux/board/rauc/bootloader,
docs/plan_rauc.md step 2) on the host, against a stand-in rsu_client that
keeps the flash's slots and the SDM's log in a JSON file and prints what
the real one prints (--count, --list N, --log, --enable N, --disable N).

    python3 linux/tools/rauc_backend_test.py

The slot table is the A/B layout of make_jic.sh (P1 0x400000, P2 0x700000
and the SSBL./CORE. partitions in between); priorities as librsu's
(1 = highest, "[disabled]").
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.normpath(os.path.join(HERE, "..", "board", "rauc", "bootloader"))

FAKE = r'''#!/usr/bin/env python3
import json, os, sys
path = os.environ["FAKE_RSU_STATE"]
st = json.load(open(path))
a = sys.argv[1:]
def save(): json.dump(st, open(path, "w"))
if a == ["--count"]:
    print(f"number of slots is {len(st['slots'])}")
elif a[0] == "--list":
    s = st["slots"][int(a[1])]
    print(f"      NAME: {s['name']}\n    OFFSET: 0x{s['offset']:016X}\n      SIZE: 0x{s['size']:08X}")
    print(f"  PRIORITY: {s['prio']}" if s["prio"] else "  PRIORITY: [disabled]")
elif a == ["--log"]:
    print(f"      VERSION: 0x00000202\n        STATE: 0x00000000\nCURRENT IMAGE: 0x{st['current']:016X}")
    print(f"   FAIL IMAGE: 0x{st['fail']:016X}\n    ERROR LOC: 0x00000000\nERROR DETAILS: 0x00000000")
elif a[0] == "--enable":
    n = int(a[1])
    for s in st["slots"]:
        if s["prio"]:
            s["prio"] += 1
    st["slots"][n]["prio"] = 1
    st["calls"].append(" ".join(a)); save()
elif a == ["--clear-error-status"]:
    st["fail"] = 0
    st["calls"].append(" ".join(a)); save()
elif a[0] == "--disable":
    st["slots"][int(a[1])]["prio"] = None
    st["calls"].append(" ".join(a)); save()
else:
    print("ERROR: unknown command " + " ".join(a)); sys.exit(1)
'''


def layout(p1, p2, current=0x400000, fail=0):
    def slot(name, offset, prio=None):
        return {"name": name, "offset": offset, "size": 0x100000, "prio": prio}
    return {"slots": [slot("P1", 0x400000, p1), slot("SSBL.FACTORY_IM", 0x500000),
                      slot("SSBL.P1", 0x600000), slot("P2", 0x700000, p2), slot("SSBL.P2", 0x800000),
                      slot("UBOOT", 0xA00000), slot("CORE.FACTORY_IM", 0xC00000),
                      slot("CORE.P1", 0xD10000), slot("CORE.P2", 0xE20000)],
            "current": current, "fail": fail, "calls": []}


def main():
    work = tempfile.mkdtemp(prefix="rauc-backend-")
    fake = os.path.join(work, "rsu_client")
    with open(fake, "w") as f:
        f.write(FAKE)
    os.chmod(fake, 0o755)
    state = os.path.join(work, "state.json")
    sysfs = os.path.join(work, "sysfs")
    os.makedirs(sysfs)
    env = dict(os.environ, RSU_CLIENT=fake, FAKE_RSU_STATE=state, RSU_SYSFS=sysfs)

    def run(*args):
        r = subprocess.run([sys.executable, BACKEND, *args], env=env, capture_output=True, text=True)
        return r.returncode, r.stdout.strip(), r.stderr.strip()

    def given(**kw):
        json.dump(layout(**kw), open(state, "w"))

    def calls():
        return json.load(open(state))["calls"]

    failed = []

    def check(name, got, want):
        ok = got == want
        print(f"{'PASS' if ok else 'FAIL'}  {name}: {got}" + ("" if ok else f" (want {want})"))
        if not ok:
            failed.append(name)

    # a fresh card: P1 only (P2 empty = disabled)
    given(p1=1, p2=None)
    check("primary, P2 empty", run("get-primary"), (0, "P1", ""))
    check("state P1", run("get-state", "P1"), (0, "good", ""))
    check("state P2 empty", run("get-state", "P2"), (0, "bad", ""))
    check("state factory", run("get-state", "FACTORY_IMAGE"), (0, "good", ""))
    check("current", run("get-current"), (0, "P1", ""))
    # an install into P2: RAUC marks it bad (already disabled: no call),
    # writes, then makes it primary
    check("mark P2 bad (empty)", run("set-state", "P2", "bad")[0], 0)
    check("no disable call for an empty slot", calls(), [])
    check("P2 primary", run("set-primary", "P2")[0], 0)
    check("enable call", calls(), ["--enable 3"])
    check("reboot_image = P2's offset", open(os.path.join(sysfs, "reboot_image")).read(), "0x700000")
    check("primary after", run("get-primary"), (0, "P2", ""))
    check("P1 still good", run("get-state", "P1"), (0, "good", ""))
    # booted into P2, then the next install goes into P1: disabled first
    given(p1=2, p2=1, current=0x700000)
    check("current P2", run("get-current"), (0, "P2", ""))
    check("mark P1 bad", run("set-state", "P1", "bad")[0], 0)
    check("disable call", calls(), ["--disable 0"])
    check("P1 bad now", run("get-state", "P1"), (0, "bad", ""))
    check("primary P2 meanwhile", run("get-primary"), (0, "P2", ""))
    # P2 failed (the watchdog fell back to P1): the SDM's fail record
    given(p1=2, p2=1, current=0x400000, fail=0x700000)
    check("P2 failed = bad", run("get-state", "P2"), (0, "bad", ""))
    check("P1 good", run("get-state", "P1"), (0, "good", ""))
    check("primary skips the failed P2", run("get-primary"), (0, "P1", ""))
    # a new image into P2 after that: made primary, the failure record cleared
    check("P2 primary again", run("set-primary", "P2")[0], 0)
    check("enable + clear", calls(), ["--enable 3", "--clear-error-status"])
    check("P2 primary after the clear", run("get-primary"), (0, "P2", ""))
    # both disabled: the factory image is what boots
    given(p1=None, p2=None, current=0x220000)
    check("primary none", run("get-primary"), (0, "FACTORY_IMAGE", ""))
    check("current factory", run("get-current"), (0, "FACTORY_IMAGE", ""))
    # refusals
    check("factory not bad", run("set-state", "FACTORY_IMAGE", "bad")[0], 1)
    check("factory not primary", run("set-primary", "FACTORY_IMAGE")[0], 1)
    check("unknown image", run("get-state", "P3")[0], 1)
    check("bad call", run("set-state", "P1")[0], 1)
    print("FAIL: " + " ".join(failed) if failed else "PASS")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
