#!/usr/bin/env python3
"""
test_stream.py - the scope's stream end to end (docs/plan_scope.md,
phase 3): a WebSocket to the board's port 5004, channel 0 on the test
generator's counter, every sample checked.

    python3 linux/tools/test_stream.py [host] [seconds] [divider ...]
    python3 linux/tools/test_stream.py 192.168.1.223 10 12 9 6
    python3 linux/tools/test_stream.py localhost:5004 3 99     # fpga_access.py --sim

For each divider (a sample every divider+1 clocks of 50 MHz) it takes the
stream for the given seconds and checks that every message is whole
records and that the counter goes up by one from each sample to the next,
across messages: nothing lost, nothing twice. It prints the rate it
received. A rate the link cannot keep up with ends with the board's close
frame (an overrun), which is printed and counted as a failure.

Needs numpy (on the PC, not the board).
"""
import base64
import hashlib
import os
import socket
import struct
import sys
import time

import numpy as np

CLOCK_HZ = 50_000_000
CHANNELS = 8
COUNTER = 7                       # the test generator's counter
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class Frames:
    """the server's frames off a socket: (first byte, payload view), read
    into one buffer and parsed in place (fast enough for line rate)"""

    def __init__(self, sock):
        self.s = sock
        self.buf = bytearray(64 << 20)
        self.view = memoryview(self.buf)
        self.lo = self.hi = 0            # unparsed bytes: buf[lo:hi]

    def _need(self, n):
        if self.lo + n > len(self.buf):      # compact: move what is left to the front
            left = self.hi - self.lo
            self.buf[:left] = self.buf[self.lo:self.hi]
            self.lo, self.hi = 0, left
        while self.hi - self.lo < n:
            k = self.s.recv_into(self.view[self.hi:])
            if not k:
                raise ConnectionError("closed without a close frame")
            self.hi += k

    def next(self):
        self._need(2)
        b0, b1 = self.buf[self.lo], self.buf[self.lo + 1]
        n, at = b1 & 0x7F, 2
        if n == 126:
            self._need(4)
            n, at = struct.unpack_from(">H", self.buf, self.lo + 2)[0], 4
        elif n == 127:
            self._need(10)
            n, at = struct.unpack_from(">Q", self.buf, self.lo + 2)[0], 10
        self._need(at + n)
        payload = self.view[self.lo + at:self.lo + at + n]
        self.lo += at + n
        return b0, payload


def connect(host, port, divider, sources):
    s = socket.create_connection((host, port), timeout=10)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
    key = base64.b64encode(os.urandom(16)).decode()
    q = f"divider={divider}&sources={','.join(map(str, sources))}"
    s.sendall((f"GET /stream?{q} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\n"
               f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
               f"Sec-WebSocket-Version: 13\r\n\r\n").encode())
    reply = b""
    while b"\r\n\r\n" not in reply:
        part = s.recv(1)
        if not part:
            raise ConnectionError("no answer")
        reply += part
    accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest())
    if not reply.startswith(b"HTTP/1.1 101") or accept not in reply:
        raise ConnectionError(reply.decode(errors="replace"))
    return s


def close(s):
    """our close frame (masked, as a client's must be), then the socket"""
    try:
        payload = struct.pack(">H", 1000)
        mask = os.urandom(4)
        s.sendall(bytes([0x88, 0x80 | len(payload)]) + mask
                  + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))
    except OSError:
        pass
    s.close()


def stream(host, port, seconds, divider):
    s = connect(host, port, divider, [COUNTER, 0, 1, 2, 3, 4, 5, 6])
    frames = Frames(s)
    messages = errors = samples = received = 0
    last, ended = None, None
    start = time.monotonic()
    try:
        while time.monotonic() - start < seconds:
            b0, payload = frames.next()
            opcode = b0 & 0x0F
            if opcode == 0x8:
                code = struct.unpack(">H", payload[:2])[0] if len(payload) >= 2 else None
                ended = f"closed by the board ({code}): {bytes(payload[2:]).decode(errors='replace')}"
                break
            if opcode != 0x2 or not b0 & 0x80:
                errors += 1
                print(f"  message {messages}: opcode {opcode}, FIN {b0 >> 7}")
                continue
            received += len(payload)
            if len(payload) % (2 * CHANNELS):
                errors += 1
                print(f"  message {messages}: {len(payload)} bytes, not whole records")
                continue
            counter = np.frombuffer(payload, dtype="<u2").reshape(-1, CHANNELS)[:, 0]
            if last is not None:
                counter = np.concatenate(([last], counter))
            steps = (np.diff(counter.astype(np.int32)) & 0xFFFF) != 1
            if steps.any():
                errors += int(steps.sum())
                k = int(np.argmax(steps))
                if errors < 10:
                    print(f"  sample {samples + k}: counter {counter[k + 1]} after {counter[k]}")
            last = int(counter[-1])
            samples += len(payload) // (2 * CHANNELS)
            messages += 1
    except (ConnectionError, OSError) as e:
        ended = f"connection: {e}"
    elapsed = time.monotonic() - start
    close(s)
    rate = CLOCK_HZ / (divider + 1)
    print(f"divider {divider}: {rate / 1e6:.3f} MS/s, {16 * rate / 1e6:.1f} MB/s produced; "
          f"received {received / elapsed / 1e6:.1f} MB/s, {samples} samples in {messages} "
          f"messages, {errors} errors" + (f"; {ended}" if ended else ""))
    time.sleep(0.5)
    return errors + (ended is not None)


def main():
    args = sys.argv[1:]
    host = args[0] if args else "192.168.1.223"
    host, _, port = host.partition(":")
    port = int(port or 5004)
    seconds = float(args[1]) if len(args) > 1 else 5
    dividers = [int(d) for d in args[2:]] or [49, 12, 6]
    failures = sum(stream(host, port, seconds, d) for d in dividers)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
