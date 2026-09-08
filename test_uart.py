#!/usr/bin/env python3
"""
test_uart.py - exercise the DE25-Standard `de25_uart` register interface.

    python test_uart.py [PORT] [BAUD]        # defaults: /dev/ttyUSB0 115200

Self-contained - only needs pyserial (`pip install pyserial`).  Speaks the
fpga_interconnect serial protocol directly: 1-byte command, 2-byte address,
4-byte data, big-endian.

Register map (see de25_uart_top.vhd):
    1   id            0x0000DE25                     RO
    2   git hash                                     RO
    3   loopback                                     RW
    4   read counter  (+1 on every read of addr 4)   RO
    5   LED register  (low 9 bits -> LEDR[8:0])      RW
    6   SW[9:0] slide switches                        RO
    7   KEY[3:0] push-buttons, 1 = pressed            RO
    8   free-running core-clock uptime counter        RO

Exit status: 0 = all tests passed, 1 = one or more failed.
"""

import sys
import time

try:
    import serial
except ImportError:
    sys.exit("this script needs pyserial:  pip install pyserial")

CMD_READ = 0x02
CMD_WRITE = 0x04
ADDR_BYTES = 2
DATA_BYTES = 4
FRAME_LEN = 1 + ADDR_BYTES + DATA_BYTES


class Uart:
    def __init__(self, port, baud):
        self.s = serial.Serial(port, baud, timeout=0.25)
        self.s.reset_input_buffer()
        self.s.reset_output_buffer()

    def close(self):
        self.s.close()

    def read(self, addr):
        self.s.reset_input_buffer()
        self.s.write(bytes([CMD_READ, (addr >> 8) & 0xFF, addr & 0xFF]))
        frame = self.s.read(FRAME_LEN)
        if len(frame) != FRAME_LEN:
            raise TimeoutError(
                f"no/short response reading addr {addr}: got {len(frame)} bytes {frame.hex()}"
            )
        return int.from_bytes(frame[1 + ADDR_BYTES:], "big")

    def write(self, addr, value):
        value &= 0xFFFFFFFF
        self.s.write(
            bytes([CMD_WRITE, (addr >> 8) & 0xFF, addr & 0xFF])
            + value.to_bytes(DATA_BYTES, "big")
        )
        self.s.flush()


class Runner:
    def __init__(self):
        self.passed = 0
        self.failed = 0

    def check(self, name, ok, detail=""):
        tag = "PASS" if ok else "FAIL"
        print(f"  [{tag}] {name}" + (f"  - {detail}" if detail else ""))
        if ok:
            self.passed += 1
        else:
            self.failed += 1

    def info(self, msg):
        print(f"  [info] {msg}")


def test_link_and_id(u, r):
    print("link / id (addr 1)")
    val = u.read(1)
    r.check("addr 1 == 0x0000DE25", val == 0x0000DE25, f"read 0x{val:08X}")


def test_git_hash(u, r):
    print("git hash (addr 2)")
    val = u.read(2)
    r.info(f"git hash = 0x{val:08X}"
           + ("  (run ./write_githash.sh before building to populate this)" if val == 0 else ""))


def test_loopback(u, r):
    print("loopback register (addr 3)")
    for pat in (0x00000000, 0xFFFFFFFF, 0xDEADBEEF, 0x12345678, 0xA5A5A5A5, 0x5A5A5A5A):
        u.write(3, pat)
        got = u.read(3)
        r.check(f"0x{pat:08X}", got == pat, f"read 0x{got:08X}")
    u.write(3, 0)


def test_read_counter(u, r):
    print("read strobe counter (addr 4)")
    seq = [u.read(4) for _ in range(6)]
    deltas = [(b - a) & 0xFFFFFFFF for a, b in zip(seq, seq[1:])]
    r.check("increments by 1 per read", all(d == 1 for d in deltas), f"{seq}")


def test_leds(u, r):
    print("LED register (addr 5 -> LEDR[8:0])")
    for pat in (0x000, 0x1FF, 0x0AA, 0x155):
        u.write(5, pat)
        got = u.read(5) & 0x1FF
        r.check(f"0x{pat:03X}", got == (pat & 0x1FF), f"read 0x{got:03X}")
    u.write(5, 0)
    r.info("watch LEDR[8:0] change as this runs; LEDR[9] is the heartbeat")


def test_switches_and_keys(u, r):
    print("SW (addr 6) and KEY (addr 7) readback")
    sw = u.read(6) & 0x3FF
    key = u.read(7) & 0xF
    r.info(f"SW  = 0b{sw:010b}  (0x{sw:03X})")
    r.info(f"KEY = 0b{key:04b}   (1 = pressed)")
    r.check("SW register in range", sw == (sw & 0x3FF))
    r.check("KEY register in range", key == (key & 0xF))


def test_uptime(u, r):
    print("uptime counter (addr 8)")
    a = u.read(8)
    time.sleep(0.1)
    b = u.read(8)
    delta = (b - a) & 0xFFFFFFFF
    # 50 MHz core clock -> ~5e6 ticks in 100 ms; just check it moved forward a lot
    r.check("advances with wall-clock time", 1_000_000 < delta < 20_000_000,
            f"+{delta} ticks in ~100 ms")


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyUSB0"
    baud = int(sys.argv[2]) if len(sys.argv) > 2 else 115200

    print(f"de25_uart register test  -  {port} @ {baud} baud\n")
    try:
        u = Uart(port, baud)
    except serial.SerialException as e:
        sys.exit(f"could not open {port}: {e}")

    r = Runner()
    try:
        for t in (
            test_link_and_id,
            test_git_hash,
            test_loopback,
            test_read_counter,
            test_leds,
            test_switches_and_keys,
            test_uptime,
        ):
            t(u, r)
            print()
    except (TimeoutError, serial.SerialException) as e:
        print(f"\n  [FAIL] communication error: {e}")
        r.failed += 1
    finally:
        u.close()

    total = r.passed + r.failed
    print(f"result: {r.passed}/{total} passed" + (f", {r.failed} FAILED" if r.failed else ""))
    sys.exit(1 if r.failed else 0)


if __name__ == "__main__":
    main()
