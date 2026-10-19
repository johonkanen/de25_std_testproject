#!/usr/bin/env python3
"""
push_to_board.py - push a file to the DE25-Standard's running Linux over
the network, using the HPS UART1 serial console to drive the remote side
(the board's rootfs has no scp/ssh, only plain `nc`).

Requires the board running Linux with eth0 up, and pyserial.

Usage:
  python3 push_to_board.py <local_file> <remote_path> [--run] [--port PORT]
                           [--serial PORT] [--board-ip 192.168.1.223]

  --run     chmod +x the remote file and execute it, streaming its output
  --port    TCP port to use for the transfer (default 8080)

The board listens (`nc -l -p PORT ... > file`, started over the console) and
this host connects: WSL2's NAT lets the host reach a LAN device, not the
other way round. Adapted from the DE25-Nano's push_to_nano.py.
"""
import argparse
import glob
import os
import socket
import sys
import time

# The DE25-Standard's HPS console, by id (ttyUSB numbers move with whatever
# else is plugged in). HPS UART1 is on dedicated HPS pins to the board's
# USB-UART: a CP2105 on boards with a separate USB-UART port, or a channel
# of the USB-Blaster III (interface 1; 0 is JTAG) on rev D (one Type-C). The
# DE25-Nano is never matched, so a tool that writes the SD card cannot hit
# the wrong board. Override with --serial or DE25_STD_CONSOLE.
CONSOLE_PATTERNS = (
    "/dev/serial/by-id/usb-TERASIC_DE25-Standard_*-if01-port0",
    "/dev/serial/by-id/usb-Silicon_Labs_CP2105_*-if00-port0",
)


def default_console():
    if os.environ.get("DE25_STD_CONSOLE"):
        return os.environ["DE25_STD_CONSOLE"]
    for pattern in CONSOLE_PATTERNS:
        found = [p for p in sorted(glob.glob(pattern)) if "DE25-Nano" not in p]
        if found:
            return found[0]
    return None


def console_or_exit(port):
    if port:
        return port
    ports = sorted(glob.glob("/dev/serial/by-id/*"))
    sys.exit("no DE25-Standard console found - pass --serial (or set DE25_STD_CONSOLE) to the\n"
             "port that prints the SPL banner at power-on. Present:\n  "
             + ("\n  ".join(ports) or "(none)"))


def drain(ser, settle=0.3):
    time.sleep(settle)
    return ser.read(65536)


def send_and_wait(ser, cmd, wait=1.0):
    ser.write((cmd + "\n").encode())
    return drain(ser, wait)


def main():
    import serial
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("local_file")
    ap.add_argument("remote_path")
    ap.add_argument("--run", action="store_true", help="chmod +x and execute after transfer")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--serial", default=default_console())
    ap.add_argument("--board-ip", default="192.168.1.223")
    ap.add_argument("--baud", type=int, default=115200)
    args = ap.parse_args()

    with open(args.local_file, "rb") as f:
        data = f.read()

    ser = serial.Serial(console_or_exit(args.serial), args.baud, timeout=0.5)
    drain(ser)  # clear any pending output

    # busybox nc: -w 5 and stdin from /dev/null, or it never exits after
    # the sender closes (it keeps waiting on the console for input)
    listen = f"nc -l -p {args.port} -w 5 < /dev/null > {args.remote_path}"
    print(f">> starting listener on the board: {listen}")
    out = send_and_wait(ser, listen, wait=0.5)
    sys.stdout.write(out.decode(errors="replace"))
    time.sleep(1.0)  # let the listener actually bind before we connect

    print(f">> pushing {len(data)} bytes to {args.board_ip}:{args.port}")
    sock = socket.create_connection((args.board_ip, args.port), timeout=5)
    sock.sendall(data)
    sock.shutdown(socket.SHUT_WR)
    sock.close()

    out = drain(ser, 1.0)
    sys.stdout.write(out.decode(errors="replace"))
    print(">> transfer complete")

    if args.run:
        print(f">> running {args.remote_path}")
        out = send_and_wait(ser, f"chmod +x {args.remote_path} && {args.remote_path}", wait=2.0)
        sys.stdout.write(out.decode(errors="replace"))

    ser.close()


if __name__ == "__main__":
    main()
