#!/usr/bin/env python3
"""
test_logger.py - the data logger end to end (docs/plan_scope.md, phase 4):
a log on the board with channel 0 on the test generator's counter, every
point checked.

    python3 linux/tools/test_logger.py [host] [seconds] [rate ...]
    python3 linux/tools/test_logger.py 192.168.1.223 20 1000 100000
    python3 linux/tools/test_logger.py localhost:8000 5 100      # fpga_web.py --sim

For each rate (points/s) it starts a log through the GUI's API, lets it run
for the given seconds, stops it and downloads its .i16 and .json. The counter
goes up by one each sample, so a point of n samples starting at c has
minimum c, maximum c + n - 1 and mean c + (n - 1) / 2 (rounded half away
from zero), modulo 2**16 (a point across the wrap: 0 and 65535 and the mean
of its values). Each point must start where the last ended, and the points'
numbers (their fourth record) go 0, 1, 2, ...: nothing lost, nothing twice. The log is deleted afterwards (--keep keeps it).
"""
import argparse
import http.client
import json
import sys
import time

import numpy as np

COUNTER = 7
POINT_BYTES = 64


def call(host, port, method, path, body=None):
    c = http.client.HTTPConnection(host, port, timeout=120)
    c.request(method, path, body=None if body is None else json.dumps(body),
              headers={"Content-Type": "application/json"} if body is not None else {})
    r = c.getresponse()
    data = r.read()
    c.close()
    if r.status != 200:
        raise RuntimeError(f"{method} {path}: {r.status} {data[:200]!r}")
    return data


def expected(first, n):
    """(min, max, mean) of the counter's n values from first, modulo 2**16"""
    first = np.asarray(first, dtype=np.int64)
    last = first + n - 1
    wraps = last >= 65536
    mn = np.where(wraps, 0, first)
    mx = np.where(wraps, 65535, last)
    total = n * first + n * (n - 1) // 2 - np.where(wraps, (last - 65535) * 65536, 0)
    mean = (total + n // 2) // n            # all values >= 0: half up = away from zero
    return mn, mx, mean


def check(points, n):
    recs = points.reshape(-1, 4, 8).astype(np.int64)
    rec = recs[:, :, 0]                                             # channel 0: the counter
    mn, mx, mean = rec[:, 0], rec[:, 1], rec[:, 2]
    number = recs[:, 3, 0] << 16 | recs[:, 3, 1]
    errors = 0
    wrong = number != np.arange(len(number))
    if wrong.any():
        k = int(np.argmax(wrong))
        print(f"  point {k}: number {number[k]}")
        errors += int(wrong.sum())
    if (recs[:, 3, 4] << 16 | recs[:, 3, 5] != n).any():
        print("  a point's n is not the log's")
        errors += 1
    # each point's first value: from a point not across the wrap (its
    # minimum), the others n further on each
    if n >= 65536:
        # every value in every point: the minimum 0, the maximum 65535 (the
        # mean depends on where the point starts: not checked)
        bad = (mn != 0) | (mx != 65535)
        if bad.any():
            print(f"  point {int(np.argmax(bad))}: min {mn[bad][0]}, max {mx[bad][0]}")
        return errors + int(bad.sum()), None
    whole = np.flatnonzero(mx - mn == n - 1)
    if not len(whole):
        return errors + len(rec), "every point across the wrap: cannot tell their starts"
    k0 = int(whole[0])
    first = (mn[k0] + (np.arange(len(rec)) - k0) * n) % 65536
    emn, emx, emean = expected(first, n)
    bad = (mn != emn) | (mx != emx) | (mean != emean)
    errors += int(bad.sum())
    if bad.any():
        k = int(np.argmax(bad))
        print(f"  point {k}: min/max/mean {mn[k]} {mx[k]} {mean[k]}, "
              f"expected {emn[k]} {emx[k]} {emean[k]}")
    return errors, None


def run(host, port, seconds, rate, keep):
    settings = {"rate": rate, "sources": [COUNTER, 0, 1, 2, 3, 4, 5, 6],
                "generator_hz": 1000, "label": f"test-logger-{rate:g}"}
    started = json.loads(call(host, port, "POST", "/api/logs/start", {"settings": settings}))
    if not started.get("ok", True) or started.get("error"):
        print(f"rate {rate:g}: start refused: {started}")
        return 1
    time.sleep(seconds)
    call(host, port, "POST", "/api/logs/stop", {})
    logs = json.loads(call(host, port, "GET", "/api/logs"))
    logs = logs.get("logs", logs)
    meta = next(m for m in logs if m.get("label") == settings["label"])
    name = meta["name"]
    for _ in range(50):
        meta = json.loads(call(host, port, "GET", f"/api/logs/{name}.json"))
        if meta["state"] != "running":
            break
        time.sleep(0.2)
    t = time.monotonic()
    data = call(host, port, "GET", f"/api/logs/{name}.i16")
    took = time.monotonic() - t
    points = np.frombuffer(data, dtype="<u2")
    count = len(data) // POINT_BYTES
    errors, why = check(points[:count * POINT_BYTES // 2], meta["n"])
    span = count / meta["rate"]
    print(f"rate {meta['rate']:g} points/s (n {meta['n']}, input {meta['input_rate'] / 1e6:g} MS/s): "
          f"{count} points = {span:.1f} s, state {meta['state']}, lost {meta['lost']}, "
          f"{len(data) % POINT_BYTES} stray bytes, {errors} errors"
          + (f" ({why})" if why else "")
          + f"; .i16 {len(data) / 1e6:.1f} MB in {took:.1f} s")
    if not keep:
        call(host, port, "POST", "/api/logs/delete", {"name": name})
    return errors + bool(why) + bool(meta["lost"]) + bool(len(data) % POINT_BYTES) + (count == 0)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("host", nargs="?", default="192.168.1.223")
    ap.add_argument("seconds", nargs="?", type=float, default=10)
    ap.add_argument("rates", nargs="*", type=float)
    ap.add_argument("--keep", action="store_true", help="keep the logs on the board")
    args = ap.parse_args()
    host, _, port = args.host.partition(":")
    port = int(port or 80)
    failures = sum(run(host, port, args.seconds, r, args.keep) for r in (args.rates or [1000, 100000]))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
