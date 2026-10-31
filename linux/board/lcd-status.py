#!/usr/bin/python3
"""
lcd-status - the board's address (and a little more) on the DE25-Standard's
128x64 LCD module.

    de25-std
    192.168.1.223
    eth0 up 1000M
    up 0d 01:23

The module is a Sitronix ST7567 on the HPS's SPIM0 (write only), with its
reset, A0 (data/command) and backlight on GPIO1 (portb) IO10, IO11, IO18 -
the pin mux in fpga/hps/, the DT node in linux/dts/. No kernel driver drives
an ST7567 over SPI, so this binds spidev to the DT node and draws the frame
itself; the GPIO lines go through the GPIO character device. Run by init
(respawn); refreshes every second, writes the screen only when it changed.
On SIGTERM (shutdown) it says so on the screen.

    lcd-status             run (on the board)
    lcd-status --flip on   turn the picture 180 degrees (board seen from the
                           other side); --flip off: back; --flip: show it
    lcd-status --dump      print the screen as text, no hardware (any host)

The flip is kept in /etc/de25/lcd (on /data: survives image updates) as
flip=1; the running lcd-status picks it up within a second.

The font is the kernel's VGA 8x16 (lib/fonts/font_8x16.c, GPL-2.0),
ASCII 0x20..0x7e: 16 characters by 4 lines.
"""
import fcntl
import glob
import os
import signal
import socket
import struct
import sys
import time

WIDTH, HEIGHT = 128, 64
GPIO_CTRL = "10c03300.gpio"        # GPIO1 (DT: gpio1/portb)
LINE_RST, LINE_A0, LINE_BK = 10, 11, 18
SPI_COMPAT = "sitronix,st7567"
IFACE = "eth0"
SETTINGS = "/etc/de25/lcd"         # flip=1: picture turned 180 degrees

FONT = (  # 8x16, ASCII 0x20..0x7e, 16 rows each, MSB = left (lib/fonts/font_8x16.c)
    "00000000000000000000000000000000", "0000183c3c3c18181800181800000000",
    "00666666240000000000000000000000", "0000006c6cfe6c6c6cfe6c6c00000000",
    "18187cc6c2c07c060686c67c18180000", "00000000c2c60c183060c68600000000",
    "0000386c6c3876dccccccc7600000000", "00303030600000000000000000000000",
    "00000c18303030303030180c00000000", "000030180c0c0c0c0c0c183000000000",
    "0000000000663cff3c66000000000000", "000000000018187e1818000000000000",
    "00000000000000000018181830000000", "00000000000000fe0000000000000000",
    "00000000000000000000181800000000", "0000000002060c183060c08000000000",
    "0000386cc6c6d6d6c6c66c3800000000", "00001838781818181818187e00000000",
    "00007cc6060c183060c0c6fe00000000", "00007cc606063c060606c67c00000000",
    "00000c1c3c6cccfe0c0c0c1e00000000", "0000fec0c0c0fc060606c67c00000000",
    "00003860c0c0fcc6c6c6c67c00000000", "0000fec606060c183030303000000000",
    "00007cc6c6c67cc6c6c6c67c00000000", "00007cc6c6c67e0606060c7800000000",
    "00000000181800000018180000000000", "00000000181800000018183000000000",
    "000000060c18306030180c0600000000", "00000000007e00007e00000000000000",
    "0000006030180c060c18306000000000", "00007cc6c60c18181800181800000000",
    "0000007cc6c6dedededcc07c00000000", "000010386cc6c6fec6c6c6c600000000",
    "0000fc6666667c66666666fc00000000", "00003c66c2c0c0c0c0c2663c00000000",
    "0000f86c6666666666666cf800000000", "0000fe6662687868606266fe00000000",
    "0000fe6662687868606060f000000000", "00003c66c2c0c0dec6c6663a00000000",
    "0000c6c6c6c6fec6c6c6c6c600000000", "00003c18181818181818183c00000000",
    "00001e0c0c0c0c0ccccccc7800000000", "0000e666666c78786c6666e600000000",
    "0000f06060606060606266fe00000000", "0000c6eefefed6c6c6c6c6c600000000",
    "0000c6e6f6fedecec6c6c6c600000000", "00007cc6c6c6c6c6c6c6c67c00000000",
    "0000fc6666667c60606060f000000000", "00007cc6c6c6c6c6c6d6de7c0c0e0000",
    "0000fc6666667c6c666666e600000000", "00007cc6c660380c06c6c67c00000000",
    "00007e7e5a1818181818183c00000000", "0000c6c6c6c6c6c6c6c6c67c00000000",
    "0000c6c6c6c6c6c6c66c381000000000", "0000c6c6c6c6d6d6d6feee6c00000000",
    "0000c6c66c7c38387c6cc6c600000000", "0000666666663c181818183c00000000",
    "0000fec6860c183060c2c6fe00000000", "00003c30303030303030303c00000000",
    "00000080c0e070381c0e060200000000", "00003c0c0c0c0c0c0c0c0c3c00000000",
    "10386cc6000000000000000000000000", "00000000000000000000000000ff0000",
    "0030180c000000000000000000000000", "0000000000780c7ccccccc7600000000",
    "0000e06060786c666666667c00000000", "00000000007cc6c0c0c0c67c00000000",
    "00001c0c0c3c6ccccccccc7600000000", "00000000007cc6fec0c0c67c00000000",
    "00001c36323078303030307800000000", "000000000076cccccccccc7c0ccc7800",
    "0000e060606c7666666666e600000000", "00001818003818181818183c00000000",
    "00000606000e06060606060666663c00", "0000e06060666c78786c66e600000000",
    "00003818181818181818183c00000000", "0000000000ecfed6d6d6d6c600000000",
    "0000000000dc66666666666600000000", "00000000007cc6c6c6c6c67c00000000",
    "0000000000dc66666666667c6060f000", "000000000076cccccccccc7c0c0c1e00",
    "0000000000dc7666606060f000000000", "00000000007cc660380cc67c00000000",
    "0000103030fc30303030361c00000000", "0000000000cccccccccccc7600000000",
    "0000000000c6c6c6c6c66c3800000000", "0000000000c6c6d6d6d6fe6c00000000",
    "0000000000c66c3838386cc600000000", "0000000000c6c6c6c6c6c67e060cf800",
    "0000000000fecc183060c6fe00000000", "00000e18181870181818180e00000000",
    "00001818181818181818181800000000", "0000701818180e181818187000000000",
    "0076dc00000000000000000000000000",
)


# ---- the frame ------------------------------------------------------------
# ST7567 RAM layout: 8 pages of 8 pixel rows; one byte per column per page,
# bit 0 the top row of the page. Row 0 is the top of the screen with the
# COM direction lcd_init() sets (Terasic's hps_lcd demo uses the same).

def render(lines):
    """the 1024-byte frame of up to 4 text lines (16 characters each)"""
    frame = bytearray(WIDTH * HEIGHT // 8)
    for row, text in enumerate(lines[:HEIGHT // 16]):
        for col, ch in enumerate(text[:WIDTH // 8]):
            code = ord(ch)
            glyph = bytes.fromhex(FONT[code - 0x20 if 0x20 <= code <= 0x7e else ord("?") - 0x20])
            for gy, bits in enumerate(glyph):
                y = row * 16 + gy
                for gx in range(8):
                    if bits & (0x80 >> gx):
                        frame[(y // 8) * WIDTH + col * 8 + gx] |= 1 << (y % 8)
    return bytes(frame)


def flipped(frame):
    """the frame turned 180 degrees: x -> 127 - x, y -> 63 - y. Reversing
    the bytes reverses the pages and the columns, reversing each byte's bits
    the rows within a page."""
    return bytes(int(format(b, "08b")[::-1], 2) for b in reversed(frame))


def flip_setting():
    for line in read(SETTINGS).splitlines():
        k, _, v = line.partition("=")
        if k.strip() == "flip":
            return v.strip() in ("1", "on", "yes", "true")
    return False


def set_flip(on):
    lines = [l for l in read(SETTINGS).splitlines() if l.partition("=")[0].strip() != "flip"]
    lines.append("flip=%d" % on)
    tmp = SETTINGS + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(lines) + "\n")
        f.flush()
        os.fsync(f.fileno())
    os.rename(tmp, SETTINGS)


def screen(lines):
    frame = render(lines)
    return flipped(frame) if flip_setting() else frame


def dump(frame):
    for y in range(HEIGHT):
        print("".join("#" if frame[(y // 8) * WIDTH + x] & (1 << (y % 8)) else "."
                      for x in range(WIDTH)))


# ---- what it shows --------------------------------------------------------

def ipv4(iface):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        ifreq = fcntl.ioctl(s.fileno(), 0x8915,                 # SIOCGIFADDR
                            struct.pack("16s16x", iface.encode()))
        return socket.inet_ntoa(ifreq[20:24])
    except OSError:
        return None
    finally:
        s.close()


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def status_lines():
    ip = ipv4(IFACE)
    state = read(f"/sys/class/net/{IFACE}/operstate", "?")
    speed = read(f"/sys/class/net/{IFACE}/speed") if state == "up" else ""
    link = f"{IFACE} {state}" + (f" {speed}M" if speed.isdigit() else "")
    up = int(float(read("/proc/uptime", "0").split()[0]))
    return [
        socket.gethostname()[:16],
        ip or "no address",
        link,
        "up %dd %02d:%02d" % (up // 86400, up // 3600 % 24, up // 60 % 60),
    ]


# ---- the hardware ---------------------------------------------------------

def spi_device():
    """/dev/spidevB.C of the LCD's DT node, binding spidev to it first"""
    for dev in glob.glob("/sys/bus/spi/devices/*"):
        if SPI_COMPAT not in read(dev + "/of_node/compatible").replace("\0", " "):
            continue
        name = os.path.basename(dev)
        if not glob.glob(dev + "/spidev/*"):
            with open(dev + "/driver_override", "w") as f:
                f.write("spidev")
            if os.path.exists(dev + "/driver"):
                with open(dev + "/driver/unbind", "w") as f:
                    f.write(name)
            with open("/sys/bus/spi/drivers/spidev/bind", "w") as f:
                f.write(name)
        nodes = glob.glob(dev + "/spidev/*")
        if nodes:
            return "/dev/" + os.path.basename(nodes[0])
    return None


def gpio_chip():
    for chip in glob.glob("/sys/bus/gpio/devices/gpiochip*"):
        if GPIO_CTRL in os.path.realpath(chip):
            return "/dev/" + os.path.basename(chip)
    return None


def _iowr(nr, size):
    return (3 << 30) | (size << 16) | (0xB4 << 8) | nr


REQ_FMT = "<64I I 64B 32s I i"        # struct gpiohandle_request (GPIO v1 ABI)
GPIO_GET_LINEHANDLE = _iowr(0x03, struct.calcsize(REQ_FMT))
GPIOHANDLE_SET_LINE_VALUES = _iowr(0x09, 64)
GPIOHANDLE_REQUEST_OUTPUT = 1 << 1


class Lcd:
    def __init__(self, spidev, chip):
        self.spi = os.open(spidev, os.O_WRONLY)
        lines = [LINE_RST, LINE_A0, LINE_BK]
        self.values = [0, 0, 0]       # RST_n low: in reset
        req = struct.pack(REQ_FMT, *(lines + [0] * 61), GPIOHANDLE_REQUEST_OUTPUT,
                          *(self.values + [0] * 61), b"lcd-status", len(lines), 0)
        cfd = os.open(chip, os.O_RDONLY)
        try:
            req = fcntl.ioctl(cfd, GPIO_GET_LINEHANDLE, req)
        finally:
            os.close(cfd)
        self.lines = struct.unpack(REQ_FMT, req)[-1]
        self.shown = None

    def _set(self, rst=None, a0=None, bk=None):
        for i, v in enumerate((rst, a0, bk)):
            if v is not None:
                self.values[i] = v
        fcntl.ioctl(self.lines, GPIOHANDLE_SET_LINE_VALUES,
                    bytes(self.values + [0] * 61))

    def _cmd(self, *b):
        self._set(a0=0)
        os.write(self.spi, bytes(b))

    def init(self):
        self._set(rst=0)
        time.sleep(0.05)
        self._set(rst=1)
        time.sleep(0.05)
        # Terasic's hps_lcd sequence: COM reverse (C8, matches the module's
        # mounting), power control all on (2F), start line 0 (40), display
        # on (AF); the rest stays at the reset defaults (ADC normal, bias
        # 1/9, normal display)
        self._cmd(0xC8, 0x2F, 0x40, 0xB0, 0x00, 0x10, 0xAF)
        self._set(bk=1)               # backlight (needs JP4 fitted)
        self.shown = None

    def show(self, frame):
        if frame == self.shown:
            return
        for page in range(HEIGHT // 8):
            self._cmd(0xB0 | page, 0x00, 0x10)
            self._set(a0=1)
            os.write(self.spi, frame[page * WIDTH:(page + 1) * WIDTH])
        self.shown = frame


def main():
    if "--flip" in sys.argv:
        i = sys.argv.index("--flip")
        arg = sys.argv[i + 1] if i + 1 < len(sys.argv) else ""
        if arg in ("on", "off"):
            set_flip(arg == "on")
        elif arg:
            sys.exit("lcd-status --flip on|off")
        print("flip", "on" if flip_setting() else "off")
        return
    if "--dump" in sys.argv:
        dump(screen(status_lines()))
        return
    spidev, chip = spi_device(), gpio_chip()
    if not spidev or not chip:
        print(f"lcd-status: no LCD (spi {spidev}, gpio {chip})", file=sys.stderr)
        time.sleep(600)               # init respawns: not in a tight loop
        sys.exit(1)
    lcd = Lcd(spidev, chip)
    lcd.init()

    def stop(*_):
        lcd.show(screen([socket.gethostname()[:16], "", "shutting down"]))
        sys.exit(0)
    signal.signal(signal.SIGTERM, stop)

    while True:
        lcd.show(screen(status_lines()))
        time.sleep(1)


if __name__ == "__main__":
    main()
