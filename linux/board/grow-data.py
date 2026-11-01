#!/usr/bin/env python3
"""
grow-data - the data partition (/data, the last logical partition of the
SD card) grown to the end of the card, once, at boot (inittab, after /data
is mounted). The card image is 3 GB; the rest of the card is for the data
logger's files (docs/plan_scope.md, phase 4).

Only sizes change, never a start: the extended partition's size in the MBR
and the last logical partition's size in its EBR, each one 512-byte sector
written in place. Then the kernel is told the partition's new length
(BLKPG_RESIZE_PARTITION, so no reboot) and resize2fs grows the mounted ext4
online. Nothing happens when the partition already ends within 1 MB of the
card's end, or when the layout is not the expected one (MBR, the last
partition logical and last on the card).

    grow-data                     # on the board (inittab); prints what it did
    grow-data --image FILE --dry-run
    grow-data --image FILE        # a card image: the table only (tests)
"""
import argparse
import fcntl
import os
import struct
import subprocess
import sys

DISK = "/dev/mmcblk0"
SECTOR = 512
ALIGN = 2048                       # 1 MiB
EXTENDED = (0x05, 0x0F, 0x85)
BLKPG = 0x1269
BLKPG_RESIZE_PARTITION = 3


def say(*a):
    print("grow-data:", *a, flush=True)


def entry(sector, i):
    """(type, start, size) of entry i of an MBR / EBR sector"""
    off = 446 + 16 * i
    ptype = sector[off + 4]
    start, size = struct.unpack_from("<II", sector, off + 8)
    return ptype, start, size


def set_size(sector, i, size):
    off = 446 + 16 * i
    struct.pack_into("<I", sector, off + 12, size)
    sector[off + 5:off + 8] = b"\xfe\xff\xff"        # end CHS: beyond what CHS can say


def read_sector(f, lba):
    f.seek(lba * SECTOR)
    s = bytearray(f.read(SECTOR))
    if len(s) != SECTOR or s[510:512] != b"\x55\xaa":
        raise ValueError(f"no partition table signature in sector {lba}")
    return s


def plan(f, disk_sectors):
    """what to change: None (nothing to do, with the reason said) or a dict"""
    mbr = read_sector(f, 0)
    ext = [(i,) + entry(mbr, i) for i in range(4) if entry(mbr, i)[0] in EXTENDED]
    if len(ext) != 1:
        say("no extended partition: nothing to do")
        return None
    ext_i, _, ext_start, ext_size = ext[0]
    primaries_end = max(s + n for t, s, n in (entry(mbr, i) for i in range(4)) if t)
    # the logical partitions: a chain of EBRs, each link relative to ext_start
    ebr_lba, number, last = ext_start, 5, None
    for _ in range(64):
        ebr = read_sector(f, ebr_lba)
        ptype, rel, size = entry(ebr, 0)
        if ptype:
            last = {"ebr": ebr_lba, "number": number, "start": ebr_lba + rel, "size": size}
        ntype, nrel, _ = entry(ebr, 1)
        if not ntype:
            break
        ebr_lba, number = ext_start + nrel, number + 1
    if last is None:
        say("no logical partition: nothing to do")
        return None
    end = last["start"] + last["size"]
    if end != ext_start + ext_size or end < primaries_end:
        say(f"partition {last['number']} is not the last thing on the card: nothing to do")
        return None
    target = disk_sectors // ALIGN * ALIGN
    if target - end < ALIGN:
        say(f"partition {last['number']} already ends at the card's end "
            f"({end * SECTOR >> 20} of {disk_sectors * SECTOR >> 20} MiB)")
        return None
    return {"mbr_entry": ext_i, "ext_start": ext_start, "ext_size": target - ext_start,
            "ebr": last["ebr"], "number": last["number"], "start": last["start"],
            "old_size": last["size"], "size": target - last["start"]}


def write_table(f, p):
    ebr = read_sector(f, p["ebr"])
    set_size(ebr, 0, p["size"])
    f.seek(p["ebr"] * SECTOR)
    f.write(ebr)
    mbr = read_sector(f, 0)
    set_size(mbr, p["mbr_entry"], p["ext_size"])
    f.seek(0)
    f.write(mbr)
    f.flush()
    os.fsync(f.fileno())


def tell_kernel(fd, p):
    """BLKPG_RESIZE_PARTITION: struct blkpg_partition {long long start, length;
    int pno; char devname[64], volname[64];} behind struct blkpg_ioctl_arg
    {int op, flags, datalen; void *data;}"""
    import ctypes
    part = struct.pack("qqi64s64s", p["start"] * SECTOR, p["size"] * SECTOR, p["number"], b"", b"")
    buf = ctypes.create_string_buffer(part, len(part))
    arg = struct.pack("iiiP", BLKPG_RESIZE_PARTITION, 0, len(part), ctypes.addressof(buf))
    fcntl.ioctl(fd, BLKPG, arg)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--image", help="a card image file instead of the board's card")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    path = args.image or DISK
    if args.image:
        sectors = os.path.getsize(path) // SECTOR
    else:
        with open(f"/sys/block/{os.path.basename(DISK)}/size") as s:
            sectors = int(s.read())
    try:
        with open(path, "rb" if args.dry_run else "r+b") as f:
            p = plan(f, sectors)
            if p is None:
                return 0
            say(f"partition {p['number']}: {p['old_size'] * SECTOR >> 20} MiB -> "
                f"{p['size'] * SECTOR >> 20} MiB" + (" (dry run)" if args.dry_run else ""))
            if args.dry_run:
                return 0
            write_table(f, p)
            if not args.image:
                tell_kernel(f.fileno(), p)
    except (OSError, ValueError) as e:
        say("failed:", e)
        return 1
    if not args.image:
        part = f"{DISK}p{p['number']}"
        r = subprocess.run(["resize2fs", part], capture_output=True, text=True)
        say(f"resize2fs {part}: " + (r.stdout + r.stderr).strip().splitlines()[-1]
            if (r.stdout + r.stderr).strip() else f"resize2fs {part}: exit {r.returncode}")
        return r.returncode
    return 0


if __name__ == "__main__":
    sys.exit(main())
