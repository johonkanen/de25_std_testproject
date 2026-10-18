#!/usr/bin/env python3
"""
sd_recover.py - write the DE25-Standard's SD card from U-Boot over TFTP:
no card reader, and no working card needed (U-Boot also lives in QSPI -
see linux/make_jic.sh). Adapted from the DE25-Nano's.

    ./linux/tools/make_sdcard_image.sh           # build the image
    python3 linux/tools/sd_recover.py            # write it to the board's card

What it does, over the board's serial console (found by id, see
push_to_board.py; --serial otherwise):
  1. starts tftp_server.py serving build/images/ - on Windows Python
     when run under WSL2 (the board can't reach a server inside WSL's NAT),
     bound to the Windows address on the board's subnet;
  2. gets to the U-Boot prompt: stops autoboot, or reboots a running Linux,
     or asks you to power-cycle;
  3. in U-Boot: checks the running U-Boot's device tree says
     "DE25-Standard" (so another board's card is never written), sets
     ipaddr/serverip, `tftpboot` the image to RAM, checks
     its CRC32 against the local file, `gzwrite mmc 0` (which checks the
     uncompressed size and CRC itself), lists the new partitions, and
     boots it - unless --no-boot.

The whole card's old contents are overwritten. Options: --image,
--serial, --board-ip, --server-ip, --no-server (a TFTP server of your own
already serves the image), --no-boot.
"""
import argparse
import ipaddress
import os
import re
import shutil
import subprocess
import sys
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
try:
    import serial
except ImportError:
    sys.exit("needs pyserial: pip install pyserial")
from push_to_board import default_console, console_or_exit  # noqa: E402

BUILD = os.path.normpath(os.path.join(os.environ.get("BUILD_DIR") or os.path.join(HERE, "..", "..", "build"), "images"))
PROMPT = "SOCFPGA_AGILEX5 # "
AUTOBOOT = "Hit any key to stop autoboot"
LOAD_ADDR = 0x90000000          # DDR is 0x8000_0000..0xBFFF_FFFF; U-Boot sits at the top
BOARD_MODEL = "DE25-Standard"   # in the U-Boot device tree's model string


def in_wsl():
    try:
        return "microsoft" in open("/proc/version").read().lower()
    except OSError:
        return False


def windows_ipv4s():
    out = subprocess.run(["ipconfig.exe"], capture_output=True, text=True, timeout=20).stdout
    ips, masks = re.findall(r"IPv4 Address[ .]*: ([\d.]+)", out), re.findall(r"Subnet Mask[ .]*: ([\d.]+)", out)
    return list(zip(ips, masks))


def pick_server_ip(board_ip):
    """the host address on the board's subnet"""
    board = ipaddress.ip_address(board_ip)
    if in_wsl():
        candidates = windows_ipv4s()
    else:
        out = subprocess.run(["ip", "-4", "-o", "addr"], capture_output=True, text=True).stdout
        candidates = [(m.group(1), str(ipaddress.ip_network("0.0.0.0/" + m.group(2)).netmask))
                      for m in re.finditer(r"inet ([\d.]+)/(\d+)", out)]
    for ip, mask in candidates:
        if board in ipaddress.ip_network(f"{ip}/{mask}", strict=False):
            return ip
    sys.exit(f"no host address on {board_ip}'s subnet (have {candidates}); pass --server-ip")


def find_windows_python():
    # a real install first: python.exe on the PATH can be the Microsoft
    # Store stub (WindowsApps), which opens the Store instead of running
    import glob
    found = sorted(glob.glob("/mnt/c/Users/*/AppData/Local/Programs/Python/Python3*/python.exe"))
    if found:
        return found[-1]
    p = shutil.which("py.exe")
    if p:
        return p
    sys.exit("no Windows Python found - install it, or run tftp_server.py yourself and pass --no-server")


def start_server(root, server_ip, log_path):
    script = os.path.join(HERE, "tftp_server.py")
    if in_wsl():
        wpy = find_windows_python()
        win = lambda p: subprocess.check_output(["wslpath", "-w", p], text=True).strip()
        cmd = [wpy, win(script), "--root", win(root), "--bind", server_ip, "--lifetime", "3600"]
    else:
        cmd = [sys.executable, script, "--root", root, "--bind", server_ip, "--lifetime", "3600"]
    log = open(log_path, "w")
    proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    time.sleep(2.0)
    if proc.poll() is not None:
        sys.exit("tftp server did not start:\n" + open(log_path).read())
    return proc


class UBoot:
    def __init__(self, port):
        self.ser = serial.Serial(port, 115200, timeout=0.1)
        self.buf = ""

    def _read(self):
        data = self.ser.read(4096).decode(errors="replace")
        if data:
            sys.stdout.write(data.replace("\r", ""))
            sys.stdout.flush()
            self.buf += data
        return data

    def wait_for(self, patterns, timeout, poke=None):
        """until one of patterns appears in new output; returns it (or None).
        poke: text to send every half second meanwhile (stopping autoboot)."""
        start = len(self.buf)
        deadline = time.time() + timeout
        next_poke = 0
        while time.time() < deadline:
            self._read()
            for p in patterns:
                if p in self.buf[start:]:
                    return p
            if poke and time.time() >= next_poke:
                self.ser.write(poke.encode())
                next_poke = time.time() + 0.5
        return None

    def to_prompt(self, wait_boot):
        self.ser.write(b"\r")
        if self.wait_for([PROMPT], 2):
            return
        # without terminal escapes: Alpine's shell follows its prompt with a
        # cursor-position query (ESC [6n), which hid "~ #" from the check
        tail = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", self.buf[-200:])
        if re.search(r"[#$] ?$", tail.rstrip("\r\n ") + " ") and PROMPT not in tail:
            print("\n>> a Linux shell answers - rebooting into U-Boot")
            self.ser.write(b"\rreboot\r")
        else:
            print(f"\n>> no U-Boot prompt: power-cycle the board now (waiting {wait_boot} s)")
        got = self.wait_for([AUTOBOOT, PROMPT], wait_boot)
        if got is None:
            sys.exit("\nno U-Boot on the console - is the new .jic (U-Boot in QSPI) programmed?")
        if self.wait_for([PROMPT], 15, poke="\r") is None:
            sys.exit("\ncould not stop autoboot")
        time.sleep(0.3)
        self._read()

    def run(self, cmd, timeout=10):
        """one command; returns its output (without the echo and the prompt)"""
        self._read()
        start = len(self.buf)
        self.ser.write(cmd.encode() + b"\r")
        deadline = time.time() + timeout
        while time.time() < deadline:
            self._read()
            out = self.buf[start:]
            # the prompt that follows the command's own output
            i = out.find(cmd)
            j = out.find(PROMPT, i + len(cmd) if i >= 0 else 0)
            if j >= 0:
                return out[(i + len(cmd)) if i >= 0 else 0:j].replace("\r", "")
        sys.exit(f"\nU-Boot: no prompt after {cmd!r} within {timeout} s")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--image", default=os.path.join(BUILD, "sdcard.img.gz"))
    ap.add_argument("--serial", default=default_console())
    ap.add_argument("--board-ip", default="192.168.1.223")
    ap.add_argument("--netmask", default="255.255.255.0")
    ap.add_argument("--server-ip", help="the TFTP server's address (default: this host's, on the board's subnet)")
    ap.add_argument("--no-server", action="store_true", help="don't start tftp_server.py")
    ap.add_argument("--no-boot", action="store_true", help="stay in U-Boot after writing")
    ap.add_argument("--wait-boot", type=int, default=120, help="seconds to wait for U-Boot after a power cycle")
    args = ap.parse_args()

    image = os.path.abspath(args.image)
    if not os.path.isfile(image):
        sys.exit(f"{image} missing - run linux/tools/make_sdcard_image.sh first")
    data = open(image, "rb").read()
    size, crc = len(data), zlib.crc32(data) & 0xFFFFFFFF
    args.serial = console_or_exit(args.serial)
    server_ip = args.server_ip or pick_server_ip(args.board_ip)
    print(f">> image {os.path.basename(image)}: {size} bytes, crc32 {crc:08x}")
    print(f">> board {args.board_ip}, TFTP server {server_ip}, console {args.serial}")

    server = None
    if not args.no_server:
        log_path = os.path.join(BUILD, "tftp_server.log")
        server = start_server(os.path.dirname(image), server_ip, log_path)
        print(f">> tftp server running (log {log_path}); on Windows, allow Python through "
              "the firewall if asked")
    try:
        ub = UBoot(args.serial)
        ub.to_prompt(args.wait_boot)
        # the board check, before anything is written: the model string of
        # the device tree U-Boot itself runs with
        out = ub.run("fdt addr ${fdtcontroladdr}; fdt print / model")
        if BOARD_MODEL not in out:
            sys.exit(f"\nthis U-Boot's device tree model is not {BOARD_MODEL!r}:{out.strip()!r} - "
                     "wrong board or wrong console port? Nothing written.")
        print(f"\n>> board check: {BOARD_MODEL}")
        print("\n>> network")
        # netretry no: a failed download returns to the prompt instead of
        # retrying forever (and eating our next commands)
        ub.run(f"setenv autoload no; setenv netretry no; setenv ipaddr {args.board_ip}; "
               f"setenv netmask {args.netmask}; setenv serverip {server_ip}")
        print(">> download")
        out = ub.run(f"tftpboot {LOAD_ADDR:#x} {os.path.basename(image)}", timeout=600)
        m = re.search(r"Bytes transferred = (\d+)", out)
        if not m:
            if "phy_startup() failed" in out or "auto negotiation" in out and "TIMEOUT" in out:
                hint = (" - the ethernet link is down (the PHY heard no link partner): check the "
                        "cable and the switch port; `mii read 1 1` at the U-Boot prompt shows the link bit")
            elif "Retry count exceeded" in out or "T T" in out:
                hint = (" - the board got no answer: check the Windows firewall lets Python receive "
                        "UDP on this network")
            else:
                hint = ""
            sys.exit(f"\ntftp failed{hint}")
        if int(m.group(1)) != size:
            sys.exit(f"\ntftp: {m.group(1)} bytes arrived, the image is {size}")
        out = ub.run(f"crc32 {LOAD_ADDR:#x} {size:#x}")
        m = re.search(r"==> ([0-9a-fA-F]{8})", out)
        if not m or int(m.group(1), 16) != crc:
            sys.exit(f"\ncrc32 in RAM {m.group(1) if m else '?'} != {crc:08x}: not writing")
        print(f"\n>> crc32 matches - writing the card (everything on it is replaced)")
        ub.run("mmc dev 0")
        out = ub.run(f"gzwrite mmc 0 {LOAD_ADDR:#x} {size:#x}", timeout=1800)
        if not re.search(r"\d+ bytes, crc 0x[0-9a-f]{8}", out) or "uncompressed" in out or "rror" in out:
            sys.exit("\ngzwrite did not complete cleanly - the card is in an unknown state; run this again")
        ub.run("mmc rescan")
        ub.run("part list mmc 0")
        print("\n>> card written")
        if args.no_boot:
            print(">> staying in U-Boot (--no-boot)")
            return 0
        print(">> booting it")
        ub.ser.write(b"boot\r")
        if ub.wait_for(["Starting kernel"], 60) is None:
            sys.exit("\nU-Boot did not start a kernel - see the output above")
        ub.wait_for(["rc.local", "de25-std", "~ #", "/ #"], 120)
        print(f"\n>> Linux is up (first boot installs python3, needs internet); {args.board_ip}")
        return 0
    finally:
        if server:
            server.terminate()


if __name__ == "__main__":
    import signal
    # killed (not ^C): still run main()'s finally, which stops the TFTP
    # server - a Windows one would otherwise keep port 69 for its lifetime
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))
    sys.exit(main())
