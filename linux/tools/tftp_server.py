#!/usr/bin/env python3
"""
tftp_server.py - a small read-only TFTP server (RFC 1350, with the blksize
and tsize options of RFC 2348/2349 that U-Boot asks for), for
sd_recover.py: U-Boot on the DE25-Standard downloads the SD card image
from it. (Copied unchanged from the DE25-Nano repo.)

Stdlib only, so it runs on Windows Python as well - which it has to under
WSL2's default NAT networking, where the board cannot reach a server
inside WSL. sd_recover.py starts it there by itself; to run it by hand:

    python tftp_server.py --root DIR [--bind 0.0.0.0] [--port 69]

Only files directly in DIR are served; writes (WRQ) are refused. The first
run on Windows asks to let Python through the firewall - allow it on the
network the board is on.
"""
import argparse
import os
import socket
import struct
import sys
import threading
import time

RRQ, WRQ, DATA, ACK, ERROR, OACK = 1, 2, 3, 4, 5, 6
ERR_NOT_FOUND, ERR_ACCESS, ERR_ILLEGAL, ERR_OPTION = 1, 2, 4, 8
TIMEOUT_S = 1.0
RETRIES = 8


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def error_packet(code, msg):
    return struct.pack("!HH", ERROR, code) + msg.encode() + b"\0"


def parse_request(pkt):
    parts = pkt[2:].split(b"\0")
    filename, mode = parts[0].decode(errors="replace"), parts[1].decode().lower()
    opts = {}
    rest = parts[2:]
    for i in range(0, len(rest) - 1, 2):
        if rest[i]:
            opts[rest[i].decode().lower()] = rest[i + 1].decode()
    return filename, mode, opts


def serve_file(path, client, opts):
    """One transfer, from its own socket (the TFTP 'TID')."""
    size = os.path.getsize(path)
    blksize = 512
    oack = {}
    if "blksize" in opts:
        blksize = max(8, min(65464, int(opts["blksize"])))
        oack["blksize"] = str(blksize)
    if "tsize" in opts:
        oack["tsize"] = str(size)
    if "timeout" in opts:
        oack["timeout"] = opts["timeout"]

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("", 0))
    sock.settimeout(TIMEOUT_S)
    t0 = time.time()

    def send_wait(pkt, want_block):
        """send pkt until the client ACKs want_block"""
        for _ in range(RETRIES):
            sock.sendto(pkt, client)
            deadline = time.time() + TIMEOUT_S
            while time.time() < deadline:
                try:
                    data, addr = sock.recvfrom(2048)
                except socket.timeout:
                    break
                if addr != client or len(data) < 4:
                    continue
                op, num = struct.unpack("!HH", data[:4])
                if op == ACK and num == want_block:
                    return True
                if op == ERROR:
                    raise ConnectionAbortedError(data[4:-1].decode(errors="replace"))
                # older ACK (duplicate): keep waiting for ours
        return False

    try:
        if oack:
            pkt = struct.pack("!H", OACK) + b"".join(
                k.encode() + b"\0" + v.encode() + b"\0" for k, v in oack.items())
            if not send_wait(pkt, 0):
                raise TimeoutError("no ACK for OACK")
        with open(path, "rb") as f:
            block = 1
            while True:
                chunk = f.read(blksize)
                pkt = struct.pack("!HH", DATA, block & 0xFFFF) + chunk
                if not send_wait(pkt, block & 0xFFFF):
                    raise TimeoutError(f"no ACK for block {block}")
                if len(chunk) < blksize:
                    break
                block += 1
        dt = time.time() - t0
        log(f"sent {os.path.basename(path)} to {client[0]}: {size} bytes in {dt:.1f} s "
            f"({size / max(dt, 1e-3) / 1e6:.2f} MB/s, blksize {blksize})")
    except (TimeoutError, ConnectionAbortedError) as e:
        log(f"transfer of {os.path.basename(path)} to {client[0]} failed: {e}")
    finally:
        sock.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", required=True, help="directory to serve")
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=69)
    ap.add_argument("--lifetime", type=float, default=0,
                    help="exit after this many seconds (0: run until stopped) - so a server "
                         "started from WSL on Windows can't outlive its job")
    args = ap.parse_args()
    root = os.path.abspath(args.root)

    srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    srv.bind((args.bind, args.port))
    log(f"tftp: serving {root} on {args.bind}:{args.port}")
    end = time.time() + args.lifetime if args.lifetime else None
    srv.settimeout(1.0)
    while end is None or time.time() < end:
        try:
            pkt, client = srv.recvfrom(2048)
        except socket.timeout:
            continue
        if len(pkt) < 4:
            continue
        op = struct.unpack("!H", pkt[:2])[0]
        if op == WRQ:
            srv.sendto(error_packet(ERR_ACCESS, "read-only server"), client)
            continue
        if op != RRQ:
            srv.sendto(error_packet(ERR_ILLEGAL, "expected a read request"), client)
            continue
        try:
            filename, mode, opts = parse_request(pkt)
        except (IndexError, UnicodeDecodeError, ValueError):
            srv.sendto(error_packet(ERR_ILLEGAL, "malformed request"), client)
            continue
        name = os.path.basename(filename.replace("\\", "/"))
        path = os.path.join(root, name)
        if mode != "octet" or not name or not os.path.isfile(path):
            log(f"{client[0]} asked for {filename!r} ({mode}): not served")
            srv.sendto(error_packet(ERR_NOT_FOUND, "file not found"), client)
            continue
        log(f"{client[0]} reads {name} (options {opts})")
        threading.Thread(target=serve_file, args=(path, client, opts), daemon=True).start()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
    except PermissionError as e:
        sys.exit(f"tftp: {e} - port 69 needs administrator rights on some systems; try --port")
