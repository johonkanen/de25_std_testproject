#!/usr/bin/env python3
"""
install_webapp.py - one-time install of the web GUI on a running
DE25-Standard (Alpine rootfs), for a card written before the image carried
the GUI (make_sdcard_image.sh installs it too). After this, GUI updates go
over HTTP: deploy_web.py, or the GUI's own "GUI release" panel.

Driven over the HPS UART1 serial console (the board has no ssh): it

  1. installs python3 (`apk add python3` - the board needs internet),
  2. pushes linux/webapp/ as the first release plus the supervisor
     (linux/board/de25web-supervisor.sh) to /opt/de25web,
  3. writes an update token to /opt/de25web/token (and ~/.de25web_token_std
     here) unless one exists,
  4. adds `::respawn:/opt/de25web/supervisor.sh` to /etc/inittab and makes
     init re-read it (kill -HUP 1), so the GUI runs now and on every boot,
  5. checks http://<board>/api/version answers.

    python3 linux/tools/install_webapp.py [--serial PORT] [--board-ip 192.168.1.223]

--serial defaults to the DE25-Standard's console port by id
(push_to_board.py's default_console(), which never picks a DE25-Nano).

Needs pyserial. Re-running it reinstalls (the token is kept).
"""
import argparse
import io
import os
import secrets
import socket
import sys
import tarfile
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from deploy_web import pack_release                      # noqa: E402

try:
    import serial
except ImportError:
    sys.exit("needs pyserial: pip install pyserial")
from push_to_board import console_or_exit, default_console  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SUPERVISOR = os.path.join(HERE, "..", "board", "de25web-supervisor.sh")
BASE = "/opt/de25web"
INITTAB_LINE = f"::respawn:{BASE}/supervisor.sh"
MARK = "__DE25WEB_DONE__"


class Console:
    def __init__(self, port, baud):
        self.ser = serial.Serial(port, baud, timeout=0.2)
        self.ser.write(b"\n")
        time.sleep(0.5)
        self.ser.read(65536)

    def run(self, cmd, timeout=10.0, echo=True):
        """Run one shell command, wait for its end marker, return the output."""
        self.ser.write(f"{cmd}; echo {MARK}$?\n".encode())
        out = b""
        deadline = time.time() + timeout
        while time.time() < deadline:
            out += self.ser.read(65536)
            # the marker also appears in the echoed command line: wait for
            # the one followed by the exit status
            text = out.decode(errors="replace")
            idx = text.rfind(MARK)
            if idx >= 0 and text[idx + len(MARK):].strip()[:1].isdigit():
                tail = text[idx + len(MARK):].strip().split()[0]
                body = text[:idx]
                body = body.split("\n", 1)[1] if "\n" in body else ""
                if echo and body.strip():
                    print(body.rstrip())
                return int("".join(c for c in tail if c.isdigit()) or 1), body
        raise TimeoutError(f"no answer to {cmd!r} within {timeout:.0f} s")

    def must(self, cmd, timeout=10.0, what=None):
        rc, out = self.run(cmd, timeout)
        if rc != 0:
            sys.exit(f"board: {what or cmd} failed ({rc})")
        return out


def bundle():
    """supervisor.sh + releases/<name>/... as one .tar.gz"""
    rel_blob, version = pack_release()
    rel_name = "%s-initial" % version
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w:gz") as tar:
        sup = open(SUPERVISOR, "rb").read()
        info = tarfile.TarInfo("supervisor.sh")
        info.size, info.mode, info.mtime = len(sup), 0o755, int(time.time())
        tar.addfile(info, io.BytesIO(sup))
        with tarfile.open(fileobj=io.BytesIO(rel_blob), mode="r:gz") as rel:
            for m in rel.getmembers():
                data = rel.extractfile(m) if m.isfile() else None
                m.name = f"releases/{rel_name}/{m.name}"
                tar.addfile(m, data)
    return out.getvalue(), rel_name


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--serial", default=default_console())
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--board-ip", default="192.168.1.223")
    ap.add_argument("--port", type=int, default=8080, help="TCP port for the file transfer")
    ap.add_argument("--token-file", default=os.path.expanduser("~/.de25web_token_std"))
    ap.add_argument("--skip-apk", action="store_true", help="python3 is already there")
    args = ap.parse_args()

    blob, rel_name = bundle()
    con = Console(console_or_exit(args.serial), args.baud)

    con.must("test -f /etc/alpine-release", what="this is not the Alpine rootfs (see linux/README.md)")
    if not args.skip_apk:
        print(">> python3")
        rc, _ = con.run("command -v python3 >/dev/null", echo=False)
        if rc != 0:
            con.must("apk add python3", timeout=300, what="apk add python3 (is the board online?)")

    print(f">> pushing {len(blob)} bytes ({rel_name} + supervisor)")
    # stdin /dev/null and -w: busybox nc then ends with the transfer (with the
    # console as stdin it waits on, and the shell never comes back)
    con.ser.write(f"nc -l -p {args.port} -w 5 < /dev/null > /tmp/de25web.tar.gz\n".encode())
    time.sleep(1.0)
    with socket.create_connection((args.board_ip, args.port), timeout=10) as sock:
        sock.sendall(blob)
        sock.shutdown(socket.SHUT_WR)
    time.sleep(1.0)
    con.ser.read(65536)
    size = con.must("wc -c < /tmp/de25web.tar.gz", what="the transfer").strip().split()[-1]
    if int(size) != len(blob):
        sys.exit(f"transfer: {size} bytes arrived, {len(blob)} sent")

    print(f">> installing to {BASE}")
    con.must(f"mkdir -p {BASE}/releases && tar xzf /tmp/de25web.tar.gz -C {BASE} && rm /tmp/de25web.tar.gz")
    con.must(f"ln -sfn releases/{rel_name} {BASE}/current && rm -f {BASE}/pending")

    token = None
    rc, _ = con.run(f"test -f {BASE}/token", echo=False)
    if rc != 0:
        token = secrets.token_hex(16)
        con.must(f"umask 077; echo {token} > {BASE}/token")
        with open(args.token_file, "w") as f:
            f.write(token + "\n")
        os.chmod(args.token_file, 0o600)
        print(f">> new update token in {args.token_file}")
    else:
        print(f">> keeping the board's token ({BASE}/token)")

    print(">> init")
    con.must(f"grep -qxF '{INITTAB_LINE}' /etc/inittab || echo '{INITTAB_LINE}' >> /etc/inittab")
    # a reinstall: stop the running server so the supervisor restarts it
    con.run(f"pkill -f '{BASE}/current/fpga_web.py' 2>/dev/null; true", echo=False)
    con.must("kill -HUP 1")

    url = f"http://{args.board_ip}/api/version"
    for _ in range(30):
        time.sleep(1)
        try:
            print(">> answering:", urllib.request.urlopen(url, timeout=3).read().decode())
            print(f">> GUI: http://{args.board_ip}/   updates: python3 linux/tools/deploy_web.py")
            return 0
        except OSError:
            pass
    sys.exit(f"{url} did not answer - see {BASE}/supervisor.log and {BASE}/server.log on the board")


if __name__ == "__main__":
    sys.exit(main())
