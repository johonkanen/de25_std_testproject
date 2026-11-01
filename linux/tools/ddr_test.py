#!/usr/bin/env python3
"""
ddr_test.py - the scope's DDR writer on the board (docs/plan_scope.md,
phase 2): what F2SDRAM and F2H give, measured before choosing one.

Runs on the board as root (scp it there; pure Python, no numpy). For each
bus setting it

  write   fills --size MB of the ring with a counter pattern from the
          fabric (the writer's pattern fill): clocks -> MB/s
  nc      reads it back through an uncached mapping (/dev/mem, O_SYNC):
          MB/s, and every word checked
  cached  reads it through a cached mapping: MB/s and words that differ.
          Right after a fill this mostly shows how fast cached reads are;
          the stale test below is the coherency check
  stale   --small KB: read through the cached mapping (the lines are now in
          the CPU's caches), a new fill with another seed, read cached
          again: words still holding the old pattern are stale cache lines.
          0 means the bus's writes reach the CPU coherently

and then a deep capture through the scope itself: --samples samples of
the test generator's counter at 50 MS/s into the ring, read back uncached,
the counter checked for steps of exactly one (nothing lost, nothing
repeated), and the writer's FIFO high-water mark.

    scp -s linux/tools/ddr_test.py root@BOARD:/tmp/ && ssh root@BOARD python3 /tmp/ddr_test.py
    python3 ddr_test.py --bus f2sdram --size 64 --small 1
    python3 ddr_test.py --bus f2h-outer --axuser 0x00
    python3 ddr_test.py --capture-only --bus f2sdram --samples 8000000

Bus settings (register 289: bus, AxCACHE, AxDOMAIN, AxPROT, AxUSER):
  f2sdram     F2SDRAM, AxCACHE 0010 (as Altera's f2sdram_adapter)
  f2h         F2H, AxCACHE 0011, non-shareable: not snooped
  f2h-inner   F2H, AxCACHE 1111, inner shareable
  f2h-outer   F2H, AxCACHE 1111, outer shareable

Stop the web GUI's scope (its Run) first: this uses the scope's
registers. The GUI's scope works again afterwards (deep mode off).
"""
import argparse
import array
import mmap
import os
import random
import struct
import subprocess
import sys
import time

LWH2F_BASE = 0x20000000
REG_STRIDE = 0x10
RING_PHYS = 0xB0000000          # linux/dts: reserved-memory scope-ring
RING_BYTES = 128 << 20
CLOCK_HZ = 50_000_000
SCOPE = 256                     # scope_capture's registers (scope_block.vhd)
W = SCOPE + 32                  # scope_ddr_writer's
W_BASE, W_BUS, W_CMD, W_LEN, W_SEED, W_CLOCKS, W_ANSWERS, W_ERRORS, W_RING, W_SIZES = range(W, W + 10)
REG_FEATURES, FEATURE_SCOPE = 16, 1 << 2
COUNTER_SOURCE = 7              # the test generator's counter

BUSES = {
    #             bus  AxCACHE AxDOMAIN
    "f2sdram":   (0, 0b0010, 0b00),
    "f2h":       (1, 0b0011, 0b00),
    "f2h-inner": (1, 0b1111, 0b01),
    "f2h-outer": (1, 0b1111, 0b10),
}


class Regs:
    def __init__(self):
        self.fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        self.mm = mmap.mmap(self.fd, 0xC0000, mmap.MAP_SHARED,
                            mmap.PROT_READ | mmap.PROT_WRITE, offset=LWH2F_BASE)

    def r(self, n):
        return struct.unpack_from("<I", self.mm, n * REG_STRIDE)[0]

    def w(self, n, v):
        struct.pack_into("<I", self.mm, n * REG_STRIDE, v & 0xFFFFFFFF)


def ring_map(cached):
    flags = os.O_RDWR | (0 if cached else os.O_SYNC)
    fd = os.open("/dev/mem", flags)
    try:
        return mmap.mmap(fd, RING_BYTES, mmap.MAP_SHARED,
                         mmap.PROT_READ | mmap.PROT_WRITE, offset=RING_PHYS)
    finally:
        os.close(fd)


def bus_word(name, axprot, axuser):
    bus, cache, domain = BUSES[name]
    return bus | cache << 4 | domain << 8 | axprot << 12 | axuser << 16


def status_text(s):
    return (f"status 0x{s:08x}: fill {s & 1}, restarting {s >> 1 & 1}, W {s >> 2 & 1}, "
            f"AW {s >> 3 & 1}, in flight {s >> 8 & 15}, FIFO high water {s >> 16}")


def fill(regs, beats, seed, timeout=10.0):
    """the writer's pattern fill: word i = seed + i; returns clocks or None"""
    regs.w(W_CMD, 2)                      # clear the counters
    regs.w(W_LEN, beats)
    regs.w(W_SEED, seed)
    regs.w(W_CMD, 1)
    t_end = time.monotonic() + timeout
    while time.monotonic() < t_end:
        if not regs.r(W_CMD) & 0xF and regs.r(W_CLOCKS):
            return regs.r(W_CLOCKS)
        time.sleep(0.001)
    print("  fill did not finish:", status_text(regs.r(W_CMD)))
    return None


def expected(seed, words):
    return array.array("I", range(seed, seed + words)).tobytes()


def compare(got, want):
    """(words that differ, byte offset of the first), 4 KB at a time"""
    if got == want:
        return 0, None
    bad, first = 0, None
    for off in range(0, len(want), 4096):
        a, b = got[off:off + 4096], want[off:off + 4096]
        if a != b:
            wa, wb = array.array("I", a), array.array("I", b)
            n = sum(1 for x, y in zip(wa, wb) if x != y)
            bad += n
            if first is None:
                first = off + next(i for i, (x, y) in enumerate(zip(wa, wb)) if x != y) * 4
    return bad, first


def timed_read(mm, size):
    t = time.monotonic()
    data = mm[:size]
    return data, time.monotonic() - t


def mbs(nbytes, seconds):
    return nbytes / seconds / 1e6 if seconds > 0 else float("inf")


def bus_test(regs, nc, cached, name, args):
    regs.w(W_BUS, bus_word(name, args.axprot, args.axuser))
    size = args.size << 20
    small = args.small << 10
    seed = random.randrange(1, 1 << 30)
    result = {"bus": name}

    clocks = fill(regs, size // 32, seed)
    errors = regs.r(W_ERRORS)
    result["answers"] = regs.r(W_ANSWERS)
    result["errors"] = errors & 0xFFFF
    if clocks is None:
        result["write"] = "stuck"
        return result
    result["write"] = mbs(size, clocks / CLOCK_HZ)
    if errors & 0xFFFF:
        print(f"  {name}: {errors & 0xFFFF} bursts answered with BRESP {errors >> 16 & 3}"
              " (2 SLVERR, 3 DECERR)")

    want = expected(seed, size // 4)
    data, t = timed_read(nc, size)
    result["nc"] = mbs(size, t)
    result["nc_bad"], first = compare(data, want)
    if result["nc_bad"]:
        print(f"  {name}: uncached read: {result['nc_bad']} words differ, the first at "
              f"+0x{first:x}: 0x{struct.unpack_from('<I', data, first)[0]:08x}, "
              f"want 0x{struct.unpack_from('<I', want, first)[0]:08x}")
    data, t = timed_read(cached, size)
    result["cached"] = mbs(size, t)
    result["cached_bad"], _ = compare(data, want)

    # the coherency check: the old pattern in the caches, a new one in memory
    seed2 = random.randrange(1, 1 << 30)
    for _ in range(4):
        cached[:small]
    if fill(regs, small // 32, seed2) is None:
        result["stale"] = "stuck"
        return result
    want2 = expected(seed2, small // 4)
    result["stale"], _ = compare(cached[:small], want2)
    result["stale_nc"], _ = compare(nc[:small], want2)
    return result


def capture_test(regs, nc, name, args):
    """a deep capture of the counter at 50 MS/s, read back uncached"""
    regs.w(W_BUS, bus_word(name, args.axprot, args.axuser))
    n = args.samples
    ring = regs.r(W_RING)
    saved = {r: regs.r(r) for r in (SCOPE + 1, SCOPE + 2, SCOPE + 4, SCOPE + 5, SCOPE + 6,
                                    SCOPE + 10, SCOPE + 14)}
    regs.w(SCOPE + 0, 4)                      # stop
    regs.w(SCOPE + 1, 0)                      # every clock: 50 MS/s
    regs.w(SCOPE + 2, 0)                      # no trigger: at once
    regs.w(SCOPE + 4, 0)
    regs.w(SCOPE + 5, n)
    regs.w(SCOPE + 6, COUNTER_SOURCE | 0 << 8 | 1 << 16 | 2 << 24)
    regs.w(SCOPE + 14, 3 | 4 << 8 | 5 << 16 | 6 << 24)
    regs.w(SCOPE + 10, 1)                     # deep
    regs.w(SCOPE + 0, 1)                      # arm
    t_end = time.monotonic() + 5 + n / 1e6
    while time.monotonic() < t_end and regs.r(SCOPE + 0) & 7 != 4:
        time.sleep(0.01)
    state = regs.r(SCOPE + 0) & 7
    lost, start, written = regs.r(SCOPE + 11), regs.r(SCOPE + 12), regs.r(SCOPE + 22)
    high_water = regs.r(W_CMD) >> 16
    regs.w(SCOPE + 0, 4)
    for r, v in saved.items():
        regs.w(r, v)
    result = {"bus": name, "samples": n, "state": state, "lost": lost, "written": written,
              "high_water": high_water}
    if state != 4:
        print(f"  capture over {name} did not finish: state {state}, written {written},",
              status_text(regs.r(W_CMD)))
        return result
    # the records in time order, the ring wrapped if need be
    first = start * 16
    if start + n <= ring:
        data = nc[first:first + n * 16]
    else:
        data = nc[first:] + nc[:(start + n - ring) * 16]
    counter = array.array("H", data)[0::8]
    c0 = counter[0]
    want = array.array("H", ((c0 + i) & 0xFFFF for i in range(n)))
    if counter == want:
        result["counter_bad"] = 0
    else:
        bad = [i for i in range(n) if counter[i] != want[i]]
        result["counter_bad"] = len(bad)
        i = bad[0]
        print(f"  capture over {name}: the counter breaks at sample {i}: "
              f"{counter[max(i - 2, 0):i + 3].tolist()}")
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bus", action="append", choices=list(BUSES),
                    help="bus settings to test (default: all)")
    ap.add_argument("--size", type=int, default=64, help="MB per fill (default 64)")
    ap.add_argument("--small", type=int, default=64,
                    help="KB for the stale check, small enough to stay in the caches (default 64)")
    ap.add_argument("--repeat", type=int, default=1, help="runs per bus setting")
    ap.add_argument("--samples", type=int, default=4_000_000,
                    help="deep capture samples (default 4M = 64 MB)")
    ap.add_argument("--axprot", type=lambda x: int(x, 0), default=0b011)
    ap.add_argument("--axuser", type=lambda x: int(x, 0), default=0xE0)
    ap.add_argument("--capture-only", action="store_true")
    ap.add_argument("--no-capture", action="store_true")
    args = ap.parse_args()
    buses = args.bus or list(BUSES)

    regs = Regs()
    if not regs.r(REG_FEATURES) & FEATURE_SCOPE or regs.r(W_RING) == 0xFFFFFFFF:
        sys.exit("no scope in this core")
    ring = regs.r(W_RING)
    sizes = regs.r(W_SIZES)
    if ring == 0 or ring * 16 > RING_BYTES:
        sys.exit(f"no DDR writer in this core (register {W_RING} reads {ring})")
    print(f"writer: ring {ring} records ({ring * 16 >> 20} MB) at 0x{RING_PHYS:08x}, "
          f"bursts of {sizes & 0xFFFF} beats, FIFO {sizes >> 16} beats")
    regs.w(W_BASE, RING_PHYS)
    nc, cached = ring_map(False), ring_map(True)

    results = []
    if not args.capture_only:
        for name in buses:
            for _ in range(args.repeat):
                print(f"{name} ...", flush=True)
                results.append(bus_test(regs, nc, cached, name, args))
        print()
        print(f"{'bus':10} {'write MB/s':>10} {'nc MB/s':>8} {'bad':>5} {'cached MB/s':>11}"
              f" {'differ':>7} {'stale':>7} {'errors':>6}")
        for r in results:
            def f(k):
                v = r.get(k, "-")
                return f"{v:.0f}" if isinstance(v, float) else str(v)
            print(f"{r['bus']:10} {f('write'):>10} {f('nc'):>8} {f('nc_bad'):>5} "
                  f"{f('cached'):>11} {f('cached_bad'):>7} {f('stale'):>7} {f('errors'):>6}")
    if not args.no_capture:
        print()
        for name in buses:
            r = capture_test(regs, nc, name, args)
            print(f"capture {name}: {r['samples']} samples at 50 MS/s, state {r['state']}, "
                  f"lost {r['lost']}, counter breaks {r.get('counter_bad', '-')}, "
                  f"FIFO high water {r['high_water']} beats")
    smmu = subprocess.run("dmesg | grep -i smmu | tail -5", shell=True,
                          capture_output=True, text=True).stdout.strip()
    if smmu:
        print("\ndmesg (smmu):\n" + smmu)


if __name__ == "__main__":
    main()
