#!/usr/bin/env python3
"""
fpga_access.py - the one process that touches the FPGA's register file.

It maps the LWH2F bridge (/dev/mem at 0x2000_0000, register n at n*0x10;
fpga/register_block.vhd's header has the map) and serves register reads and
writes to the other processes of the web stack over a Unix socket, under one
lock - so a bitstream load (partial or full reconfiguration) can pause all
register traffic here, in one place (op "pause"/"resume").

    python3 fpga_access.py [--run /run/de25web]          # on the board, as root
    python3 fpga_access.py --sim [--run DIR]             # anywhere: simulated board
    python3 fpga_access.py --client read 9               # one request, for a shell
    python3 fpga_access.py --client write 9 29           # fan KTACH 29 = ~4000 rpm

Protocol: <run>/fpga.sock, one JSON object per line each way.
    {"op": "read", "reg": 9}                    -> {"ok": true, "value": 78}
    {"op": "read_many", "regs": [1, 9, 10]}     -> {"ok": true, "values": [...]}
    {"op": "write", "reg": 9, "value": 29, "lease": 10}
                                                -> {"ok": true, "value": 29}
    {"op": "release", "reg": 9}                 drop a lease (below)
    {"op": "pause", "seconds": 30, "reason": "..."}, {"op": "resume"}
    {"op": "status"}, {"op": "ping"}
    {"op": "core"}                              the FPGA core: running build, installed, previous
    {"op": "reload"}                            load the installed core again (below)
    {"op": "install_core", "bundle": PATH, "force": false}
                                                check, install and load a new core (below)
    {"op": "rsu"}                               remote system update: images, status, confirmation
    {"op": "install_rsu", "bundle": PATH, "reboot": true}
                                                write an RSU bundle to P1, then reboot into it
    {"op": "sim", "ambient": 15.0, "load": 1.0} the simulated plant (--sim only);
                                                "fan_stuck": 1 the MAX6650 out of closed loop
Errors: {"ok": false, "error": "..."}; while paused every read/write answers
{"ok": false, "error": "paused: <reason>", "paused": true}, and so does every
read/write while the fabric is not configured (below).

Fabric guard (HPS-first boards): with no FPGA core loaded - the card's and
the QSPI copy both failed - the LWH2F bridge stays in reset and an access
through it would hang or fault the CPU. Before any register access this
reads the reset manager's BRGMODRST (0x10d1102c, read only - never written
from Linux: a raw bridge-enable write panicked this board) and refuses
register traffic ("fabric not configured") while the LWH2F bit is set,
checking again every few seconds.

FPGA core (HPS-first images, plan Phase B/E): the fabric is reloaded here,
because this is the process that must keep LWH2F quiet while it happens - an
access while the fabric reconfigures can hang the CPU. A load pauses register
traffic, applies the device-tree overlay that makes the kernel's FPGA manager
load <firmware>/de25_std.core.rbf (~2 s), checks the board id (register 1),
the board variant (register 18, "STD\0") and the build id (register 19,
against de25_std.core.json beside the core), writes back the writable
registers the load reset (LEDs, fan target, blinker mode, HEX, loopback) and
resumes. install_core takes a bundle (.tar.gz: de25_std.core.rbf +
de25_std.core.json, linux/tools/deploy_fpga.py makes it) and refuses it
unless the manifest's size and SHA-256 match, it is for this board
(board "de25-std") and its periphery hash equals the installed core's - a
core only fits the first
stage (QSPI) of a build with the same pins, HPS and DDR (make_jic.sh). The installed core is kept as .prev and
loaded back if the new one fails; a core that loads is also copied to the
SD card's FAT partition (<boot>), from where U-Boot loads it at power-on.

With an RSU flash layout every image (slot: P1, FACTORY_IMAGE) has its own
core (the DE25-Nano's docs/remote_system_update_plan.md, R3b; plan Phase F
here - this board has no RSU layout yet, so none of it is active): this
keeps them in <firmware>/rsu/<slot>/ and points
<firmware>/de25_std.core.rbf (what the reload overlay loads) at the running
slot's; the card copy is de25_std_<slot>.core.rbf, the one U-Boot's preboot
loads for that image.

install_rsu writes a whole new image (linux/tools/make_rsu_bundle.py: the
application image, its U-Boot and its core) to slot P1 with rsu_client, and
reboots into it; rsu-confirm (the DE25-Nano's linux/board/rsu-confirm.sh)
confirms it or the watchdog falls back to the factory image (its
docs/remote_system_update_plan.md, R5/R6). The order keeps a power cut harmless: P1 erased first (the factory
image boots meanwhile), then its U-Boot and core (QSPI SSBL.P1 / CORE.P1,
the card, /lib/firmware/rsu/P1), the image itself last.

Fan (MAX6650, register 9): the register holds the MAX6650's KTACH target, a
speed - rpm_to_ktach()/ktach_to_rpm() below are the one conversion every
process uses. A smaller KTACH is a faster fan.

Fan lease (the temperature controller's dead-man switch): a write with
"lease": N promises another write to that register within N seconds. If none
comes - the controller crashed, hung or was killed - this process raises the
fan to SAFE_FAN_RPM (never lowers it) and logs it. The MAX6650 has no
thermal fail-safe of its own (plan §5.17): this lease is the only net when
the loop dies.

--sim also models the board's heat: a first-order thermal plant (die
temperature from ambient, heat and the fan's airflow, tau 30 s, a little
noise) written as a fake soc64hwmon directory under <run>/sim-hwmon/, which
temp_control.py and fpga_web.py read exactly like /sys/class/hwmon.

Stdlib only.
"""
import argparse
import hashlib
import json
import math
import mmap
import os
import random
import re
import shutil
import socket
import socketserver
import struct
import subprocess
import sys
import tarfile
import threading
import time

LWH2F_BASE = 0x20000000
REG_STRIDE = 0x10          # each register is 16 bytes apart: LWH2F_BASE + (n << 4)
MAP_SIZE = 0x1000          # 4 KB window: registers 0..255
PAGE_SIZE = mmap.PAGESIZE

# register numbers - fpga/register_block.vhd's header has the full map
REG_ID, REG_GIT, REG_LOOPBACK, REG_READ_COUNT, REG_LEDS = 1, 2, 3, 4, 5
REG_SW, REG_KEY, REG_UPTIME = 6, 7, 8
REG_FAN_KTACH, REG_FAN_TACH, REG_FAN_STATUS = 9, 10, 11
REG_BLINKER, REG_LEVELS0, REG_LEVELS1, REG_FEATURES, REG_BLINKER_ID = 13, 14, 15, 16, 17
REG_VARIANT, REG_BUILD_ID, REG_LEVELS2 = 18, 19, 20
REG_HEX_VALUE, REG_HEX_CONTROL, REG_HEX_RAW0, REG_HEX_RAW1 = 21, 22, 23, 24
REG_HEX_LIT0, REG_HEX_LIT1 = 25, 26

BOARD_ID = 0x0000DE25
BOARD_VARIANT = 0x53544400         # "STD\0"; the DE25-Nano reads 0
BOARD_NAME = "de25-std"            # in a core manifest
FEATURE_HW_BLINKERS = 1 << 0
FEATURE_HEX = 1 << 1
LEDS = 10                          # LEDR[9:0]
KEY_RESET_BIT = 4                  # register 7: CPU_RESET_n pressed
WRITABLE = {REG_LOOPBACK, REG_LEDS, REG_FAN_KTACH, REG_BLINKER,
            REG_HEX_VALUE, REG_HEX_CONTROL, REG_HEX_RAW0, REG_HEX_RAW1}

# MAX6650 KTACH <-> rpm: rpm = 119040 / (KTACH + 1) (KSCALE 2, the fabric's
# g_fan_kscale; register_block.vhd computes the reset value the same way)
KTACH_RPM = 119040
FAN_MIN_RPM = 1500         # the fabric's reset speed (g_fan_min_rpm), walked down on the board
FAN_MAX_RPM = 6000         # Terasic's auto_fan.v top; confirm on the board (plan C7)
SAFE_FAN_RPM = 4000        # what an expired fan lease raises the fan to


def rpm_to_ktach(rpm):
    """the KTACH target for rpm, 0..255 (255 = the slowest, ~465 rpm)"""
    if rpm <= 0:
        return 255
    return max(0, min(255, int(round(KTACH_RPM / rpm)) - 1))


def ktach_to_rpm(ktach):
    """the speed a KTACH target asks for"""
    return KTACH_RPM / ((int(ktach) & 0xFF) + 1)


# Register 11 (max6650_fan_control.vhd): bits 7:0 the MAX6650's Config as
# last read, bit 8 setup done, bit 9 I2C error, bit 10 Config as written,
# 15:12 times the fabric found Config wrong and set the chip up again,
# 23:16 Alarm Status, 31:24 GPIO Status (the last three: cores from Phase E
# on; older ones read 0 there).
FAN_CONFIG_CLOSED_LOOP = 0x29


def fan_status(value):
    """register 11, decoded. closed_loop is None until the setup has run:
    False means the MAX6650 does not regulate - it stuck in full-on once
    (plan §5.17b), the fan then ignores its target"""
    init_done = bool(value >> 8 & 1)
    return {"config_readback": value & 0xFF, "init_done": init_done,
            "i2c_error": bool(value >> 9 & 1),
            "closed_loop": (value & 0xFF) == FAN_CONFIG_CLOSED_LOOP if init_done else None,
            "reconfigs": value >> 12 & 0xF, "alarm_status": value >> 16 & 0xFF,
            "gpio_status": value >> 24 & 0xFF}


RESET_VALUES = {REG_LOOPBACK: 0, REG_LEDS: 0, REG_FAN_KTACH: rpm_to_ktach(FAN_MIN_RPM),
                REG_BLINKER: 0, REG_HEX_VALUE: 0, REG_HEX_CONTROL: 0, REG_HEX_RAW0: 0,
                REG_HEX_RAW1: 0}

# the fabric guard (above): the reset manager's bridge resets, read only
RSTMGR_BRGMODRST = 0x10D1102C
BRGMODRST_LWH2F = 1 << 1
GUARD_RECHECK_S = 3.0
# after a core load the fabric's own power-on reset (register_block.vhd,
# g_por_cycles, ~100 ms) still holds the HPS side of the LWH2F bridge in
# reset: an access then stalls the CPU for good (hung the board, 2026-10-19,
# reading register 1 at once). BRGMODRST does not show it - wait it out.
POST_LOAD_SETTLE_S = 0.5

# HEX displays: segments g..a of each hex digit, 1 = lit (hex_display.vhd);
# register 22: bit 0 raw mode, bit 1 flip (read from the other side)
HEX_RAW_MODE, HEX_FLIP = 1 << 0, 1 << 1
HEX_DECODE = (0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07,
              0x7F, 0x6F, 0x77, 0x7C, 0x39, 0x5E, 0x79, 0x71)

# the FPGA core (above): the files, and the overlay that loads them
FIRMWARE = "/lib/firmware"
BOOT = "/boot"                     # the card's FAT partition (U-Boot's preboot)
CORE_NAME = "de25_std.core.rbf"
MANIFEST_NAME = "de25_std.core.json"
PENDING_NAME = "de25_std.core.pending"
OVERLAY_DTBO = "de25_std_core_reload.dtbo"
CONFIGFS = "/sys/kernel/config"
OVERLAY_DIR = CONFIGFS + "/device-tree/overlays/de25_core"
FPGA_MANAGER = "/sys/class/fpga_manager/fpga0"
CORE_MAX = 32 << 20
PENDING_SUFFIXES = ("", ".prev")

# RSU (plan Phase F; the DE25-Nano's docs/remote_system_update_plan.md): the
# running image and the flash's
# sub-partition table (SPT) - which slot runs, and where its CORE.<slot> is.
# Flash addresses are absolute; read_flash() finds the MTD partition.
RSU_SYSFS = "/sys/devices/platform/stratix10-rsu.0"
MTD_SYSFS = "/sys/class/mtd"
SPT_MAGIC = 0x57713427
SPT_ENTRY = struct.Struct("<16sIIII")      # name, offset lo/hi, length, flags
CORE_HEADER = 0x1000                        # "core_size=0x...\n", the core after it
RSU_SLOT = "P1"                             # the one application slot an update writes
RSU_KIND = "de25_std_rsu"
RSU_FILES = ("app.rpd", "u-boot.itb", CORE_NAME, MANIFEST_NAME)
RSU_MANIFEST = "rsu.json"

DEFAULT_RUN = os.environ.get("DE25WEB_RUN", "/run/de25web")
SIM_RUN = os.environ.get("DE25WEB_RUN", "/tmp/de25web-sim")
SOCKET_NAME = "fpga.sock"


def run_dir(arg, sim):
    return arg or (SIM_RUN if sim else DEFAULT_RUN)


def hwmon_root(run, sim):
    """Where the SoC sensors are: the kernel's, or the simulated plant's."""
    return os.path.join(run, "sim-hwmon") if sim else "/sys/class/hwmon"


def log(*a):
    print(time.strftime("%F %T"), "fpga_access:", *a, flush=True)


# --------------------------------------------------------------------------
# the register file: real (/dev/mem) or simulated
# --------------------------------------------------------------------------
class Bridge:
    """mmap-backed access to the LWH2F register window (/dev/mem, root)."""

    def __init__(self):
        self._fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        aligned_base = LWH2F_BASE & ~(PAGE_SIZE - 1)
        self._offset_in_page = LWH2F_BASE - aligned_base
        self._mm = mmap.mmap(
            self._fd, MAP_SIZE + self._offset_in_page,
            mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE,
            offset=aligned_base,
        )

    def read(self, reg_num: int) -> int:
        off = self._offset_in_page + reg_num * REG_STRIDE
        return struct.unpack_from("<I", self._mm, off)[0]

    def write(self, reg_num: int, value: int) -> None:
        off = self._offset_in_page + reg_num * REG_STRIDE
        struct.pack_into("<I", self._mm, off, value & 0xFFFFFFFF)

    def fabric_ready(self):
        """the LWH2F bridge is out of reset (a core is loaded) - BRGMODRST,
        read through its own read-only mapping"""
        if not hasattr(self, "_rst"):
            base = RSTMGR_BRGMODRST & ~(PAGE_SIZE - 1)
            self._rst_off = RSTMGR_BRGMODRST - base
            self._rst = mmap.mmap(self._fd, PAGE_SIZE, mmap.MAP_SHARED, mmap.PROT_READ,
                                  offset=base)
        return not struct.unpack_from("<I", self._rst, self._rst_off)[0] & BRGMODRST_LWH2F


class SimBridge:
    """The register file without hardware: the same registers, the blinker
    patterns roughly as the FPGA modules draw them, the HEX displays,
    switches and keys changing now and then, and a fan whose rpm follows
    the KTACH target with a lag.
    The writable registers are kept in <run>/sim-regs.json, so they survive
    a restart of this process - as the real FPGA's do."""

    IDS = {2: b"BCNT", 3: b"BSCN", 4: b"BBRT", 5: b"BSPK"}
    FAN_TOP_RPM = 6500                      # the simulated fan's own limit

    def __init__(self, state_file=None):
        self._regs = {REG_ID: BOARD_ID, REG_GIT: 0x5151D00D, REG_VARIANT: BOARD_VARIANT,
                      REG_FEATURES: FEATURE_HW_BLINKERS | FEATURE_HEX,
                      REG_FAN_STATUS: 0x1F000529, REG_BUILD_ID: 0, **RESET_VALUES}
        self._state_file = state_file
        if state_file:
            try:
                with open(state_file) as f:
                    for k, v in json.load(f).items():
                        if int(k) in WRITABLE:
                            self._regs[int(k)] = int(v)
            except (OSError, ValueError):
                pass
        self._t0 = time.monotonic()
        self._levels = [0] * LEDS
        self._last_frame = 0
        self._rpm = self.rpm_for(self._regs[REG_FAN_KTACH])
        self._rpm_t = self._t0
        self._lock = threading.Lock()
        self.fan_stuck = False

    def set_fan_stuck(self, stuck):
        """the MAX6650 stuck in full-on (plan §5.17b): Config 0x09, full speed"""
        with self._lock:
            self.fan_stuck = bool(stuck)
            self._regs[REG_FAN_STATUS] = 0x1F000109 if stuck else 0x1F000529

    @classmethod
    def rpm_for(cls, ktach):
        """the MAX6650 closes the loop on KTACH: the fan runs at the target,
        up to what it can do"""
        return min(ktach_to_rpm(ktach), cls.FAN_TOP_RPM)

    def fan_rpm(self):
        """the simulated fan's speed: first-order lag (tau 1.5 s) on the target"""
        with self._lock:
            now = time.monotonic()
            dt, self._rpm_t = now - self._rpm_t, now
            target = self.FAN_TOP_RPM if self.fan_stuck else self.rpm_for(self._regs.get(REG_FAN_KTACH, 255))
            self._rpm += (target - self._rpm) * (1 - math.exp(-dt / 1.5))
            return self._rpm

    def _frames(self):
        return int((time.monotonic() - self._t0) * 50)       # 50 Hz, as led_blinkers

    def _step(self):
        now = self._frames()
        mode = self._regs.get(REG_BLINKER, 0) & 7
        for f in range(max(self._last_frame + 1, now - 100), now + 1):
            if mode == 2:
                count = (f // 25 * 2 + (1 if f % 25 >= 12 else 0)) & ((1 << LEDS) - 1)
                self._levels = [255 if count >> i & 1 else 0 for i in range(LEDS)]
            elif mode == 3:
                self._levels = [lv - (lv >> 2) if lv >= 4 else 0 for lv in self._levels]
                pos = (f // 3) % (2 * LEDS - 2)
                self._levels[pos if pos < LEDS else 2 * LEDS - 2 - pos] = 255
            elif mode == 4:
                p = f % 150
                tri = p if p < 75 else 150 - p
                t = min(255, tri * 3482 >> 10)
                self._levels = [t * t >> 8] * LEDS
            elif mode == 5:
                self._levels = [lv - (lv >> 3) if lv >= 8 else 0 for lv in self._levels]
                if random.random() < 0.25 * LEDS / 16:
                    self._levels[random.randrange(LEDS)] = 255
            else:
                self._levels = [0] * LEDS
        self._last_frame = now

    def hex_lit(self):
        """the segments hex_display.vhd drives: HEXn's g..a in byte n"""
        value, ctrl = self._regs.get(REG_HEX_VALUE, 0), self._regs.get(REG_HEX_CONTROL, 0)
        raw = self._regs.get(REG_HEX_RAW0, 0) | (self._regs.get(REG_HEX_RAW1, 0) & 0xFFFF) << 32
        lit = 0
        for n in range(6):
            if ctrl >> (8 + n) & 1:
                seg = 0
            elif ctrl & HEX_RAW_MODE:
                seg = raw >> (8 * n) & 0x7F
            else:
                seg = HEX_DECODE[value >> (4 * n) & 0xF]
            if ctrl & HEX_FLIP:         # turned by 180 degrees: a<->d, b<->e, c<->f
                seg = seg & 0x40 | (seg & 7) << 3 | seg >> 3 & 7
                lit |= seg << (8 * (5 - n))
            else:
                lit |= seg << (8 * n)
        return lit

    def read(self, reg_num: int) -> int:
        if reg_num == REG_FAN_TACH:
            t = time.monotonic() - self._t0
            rpm = max(int(self.fan_rpm() + 10 * math.sin(t)), 0)
            tach0 = min(255, int(round(rpm / 60)))    # Tach0Count: pulses in 0.5 s, 2 a turn
            return (rpm & 0xFFFF) << 8 | tach0
        with self._lock:
            t = time.monotonic() - self._t0
            mode = self._regs.get(REG_BLINKER, 0) & 7
            if reg_num in (REG_LEVELS0, REG_LEVELS1, REG_LEVELS2, REG_BLINKER_ID):
                self._step()
            if reg_num in (REG_LEVELS0, REG_LEVELS1, REG_LEVELS2):
                if mode == 0:
                    leds = (self._regs.get(REG_LEDS, 0) & 0x1FF) | ((int(t / 1.34) & 1) << 9)
                    lv = [255 if leds >> i & 1 else 0 for i in range(LEDS)]
                else:
                    lv = self._levels
                base = {REG_LEVELS0: 0, REG_LEVELS1: 4, REG_LEVELS2: 8}[reg_num]
                return sum(lv[base + i] << (8 * i) for i in range(min(4, LEDS - base)))
            if reg_num == REG_BLINKER_ID:
                return int.from_bytes(self.IDS[mode], "big") if mode in self.IDS else 0
            if reg_num in (REG_HEX_LIT0, REG_HEX_LIT1):
                lit = self.hex_lit()
                return lit & 0xFFFFFFFF if reg_num == REG_HEX_LIT0 else lit >> 32
            if reg_num == REG_UPTIME:
                return int(t * 50_000_000) & 0xFFFFFFFF
            if reg_num == REG_SW:
                return int(t / 7) % 1024
            if reg_num == REG_KEY:
                return 1 if int(t * 2) % 11 == 0 else 0
            if reg_num == REG_READ_COUNT:
                self._regs[REG_READ_COUNT] = self._regs.get(REG_READ_COUNT, 0) + 1
            return self._regs.get(reg_num, 0) & 0xFFFFFFFF

    def configure(self, build_id):
        """what a core load does to the registers: back to reset, the new build id"""
        with self._lock:
            self._regs.update(RESET_VALUES)
            self._regs[REG_BUILD_ID] = build_id
            self._levels = [0] * LEDS
        self.write(REG_LOOPBACK, 0)                  # persist the reset values

    def write(self, reg_num: int, value: int) -> None:
        with self._lock:
            if reg_num not in WRITABLE:
                return
            if reg_num == REG_FAN_KTACH:
                value &= 0xFF
            self._regs[reg_num] = value & 0xFFFFFFFF
            if self._state_file:
                tmp = self._state_file + ".tmp"
                with open(tmp, "w") as f:
                    json.dump({str(k): self._regs[k] for k in WRITABLE if k in self._regs}, f)
                os.replace(tmp, self._state_file)


# --------------------------------------------------------------------------
# the simulated heat: what the temperature controller is tuned against
# --------------------------------------------------------------------------
class ThermalPlant:
    """The die's hottest spot as a first-order system:

        T_ss = ambient + load * P / G(rpm),   G(rpm) = g0 + g1 * sqrt(rpm)
        dT/dt = (T_ss - T) / tau

    A first guess for the DE25-Standard (the DE25-Nano's form; re-fit from
    a step response on the board, plan C7): 25 C ambient gives ~45 C at the
    fan's 1500 rpm floor, ~42 C at ~2500 rpm, ~37.5 C at 6000 rpm and ~75 C
    with the fan stopped. The four sensors sit at fixed offsets below the
    hottest one (bottom right)."""

    G0, G1 = 0.01975, 0.000781      # 1/(K per unit heat)
    HEAT = 1.0
    TAU = 30.0
    SENSORS = (("Main Die SDM", -1.3), ("Main Die corner bottom left max", -3.1),
               ("Main Die corner bottom right max", 0.0), ("Main Die corner top right max", -4.4))
    VOLTS = (("0.8V VCC", 0.842), ("1.8V VCCIO_SDM", 1.818), ("1.8V VCCPT", 1.815),
             ("1.2V VCCCRCORE", 1.212), ("0.9V VCCH", 0.846), ("0.8V VCCL", 0.841))

    def __init__(self, ambient=25.0, load=1.0, noise=0.08, t0=None):
        self.ambient = ambient
        self.load = load
        self.noise = noise
        self.temp = t0 if t0 is not None else self.steady(FAN_MIN_RPM)

    def steady(self, rpm):
        g = self.G0 + self.G1 * math.sqrt(max(rpm, 0.0))
        return self.ambient + self.load * self.HEAT / g

    def step(self, dt, rpm, t=None):
        # the load wanders a little (+-3 %, 5 min period), like a busy CPU
        wobble = 1 + 0.03 * math.sin((t or 0) * 2 * math.pi / 300)
        target = self.ambient + (self.steady(rpm) - self.ambient) * wobble
        self.temp += (target - self.temp) * (1 - math.exp(-dt / self.TAU))
        return self.temp

    def readings(self):
        return [(label, self.temp + off + random.gauss(0, self.noise)) for label, off in self.SENSORS]


class SimHwmon(threading.Thread):
    """Runs the plant against the simulated fan and writes it out as a
    soc64hwmon directory (millidegrees, millivolts, labels)."""

    def __init__(self, root, bridge, ambient, load):
        super().__init__(daemon=True)
        self.dir = os.path.join(root, "hwmon0")
        os.makedirs(self.dir, exist_ok=True)
        self.bridge = bridge
        t0 = None
        try:                                # carry on from where the last run left
            with open(os.path.join(self.dir, "plant.json")) as f:
                saved = json.load(f)
            t0 = float(saved["temp"])
            ambient = saved.get("ambient", ambient) if ambient is None else ambient
            load = saved.get("load", load) if load is None else load
        except (OSError, ValueError, KeyError):
            pass
        self.plant = ThermalPlant(ambient=25.0 if ambient is None else ambient,
                                  load=1.0 if load is None else load, t0=t0)
        self._write("name", "soc64hwmon")
        for i, (label, v) in enumerate(ThermalPlant.VOLTS):
            self._write(f"in{i}_label", label)
            self._write(f"in{i}_input", str(int(v * 1000)))
        for i, (label, _) in enumerate(ThermalPlant.SENSORS):
            self._write(f"temp{i + 1}_label", label)
        self._publish()

    def _write(self, name, text):
        tmp = os.path.join(self.dir, "." + name + ".tmp")
        with open(tmp, "w") as f:
            f.write(text + "\n")
        os.replace(tmp, os.path.join(self.dir, name))

    def _publish(self):
        for i, (_, c) in enumerate(self.plant.readings()):
            self._write(f"temp{i + 1}_input", str(int(round(c * 1000))))
        self._write("plant.json", json.dumps({"temp": round(self.plant.temp, 4),
                                              "ambient": self.plant.ambient, "load": self.plant.load}))

    def run(self):
        last = time.monotonic()
        n = 0
        while True:
            time.sleep(0.2)
            now = time.monotonic()
            self.plant.step(now - last, self.bridge.fan_rpm(), now)
            last = now
            n += 1
            if n % 5 == 0:                  # the SDM updates about once a second
                try:
                    self._publish()
                except OSError as e:
                    log("sim hwmon:", e)


# --------------------------------------------------------------------------
# loading the FPGA core: the kernel's FPGA manager, or the simulated board's
# --------------------------------------------------------------------------
class CoreError(Exception):
    pass


class KernelLoader:
    """A fresh configfs overlay each time (fpga_reload/core_reload.dts): applying
    it is what makes the FPGA manager load firmware-name from /lib/firmware."""

    def __init__(self, firmware):
        self.dtbo = os.path.join(firmware, OVERLAY_DTBO)

    def check(self):
        if not os.path.isfile(self.dtbo):
            raise CoreError("no " + self.dtbo)
        if not os.path.isdir(FPGA_MANAGER):
            raise CoreError("no FPGA manager (kernel needs CONFIG_FPGA_MGR_STRATIX10_SOC=y)")

    def load(self):
        self.check()
        if not os.path.isdir(os.path.dirname(OVERLAY_DIR)):
            subprocess.run(["mount", "-t", "configfs", "none", CONFIGFS], check=False)
        if os.path.isdir(OVERLAY_DIR):
            os.rmdir(OVERLAY_DIR)
        os.mkdir(OVERLAY_DIR)
        with open(self.dtbo, "rb") as f:
            dtbo = f.read()
        try:
            with open(os.path.join(OVERLAY_DIR, "dtbo"), "wb") as f:
                f.write(dtbo)
        except OSError as e:                # the load failed: the write says so
            raise CoreError("overlay: %s" % e) from None
        status = open(os.path.join(OVERLAY_DIR, "status")).read().strip()
        state = open(os.path.join(FPGA_MANAGER, "state")).read().strip()
        if status != "applied" or state != "operating":
            raise CoreError(f"overlay {status}, FPGA manager {state}")


class SimLoader:
    """The simulated board's load: ~2 s, then the registers reset and register
    19 shows the manifest's build id. A core starting with b"BAD" fails."""

    def __init__(self, firmware, bridge):
        self.firmware = firmware
        self.bridge = bridge

    def check(self):
        pass

    def load(self):
        time.sleep(2.0)
        with open(os.path.join(self.firmware, CORE_NAME), "rb") as f:
            head = f.read(3)
        if head == b"BAD":
            self.bridge.configure(0)
            raise CoreError("overlay error, FPGA manager write error (simulated)")
        try:
            manifest = read_manifest(os.path.join(self.firmware, MANIFEST_NAME))
            build_id = int(manifest["build_id"]) if manifest else 0
        except (KeyError, ValueError, TypeError):
            build_id = 0
        self.bridge.configure(build_id)


def read_flash(address, length):
    """length bytes of the QSPI flash from address - through the MTD partition
    that holds it (the DT splits the flash: "u-boot" below SPT0, "root" from
    it); None if none does"""
    try:
        names = sorted(n for n in os.listdir(MTD_SYSFS) if n.startswith("mtd") and n[3:].isdigit())
    except OSError:
        return None
    for name in names:
        try:
            with open(os.path.join(MTD_SYSFS, name, "offset")) as f:
                start = int(f.read().strip(), 0)
            with open(os.path.join(MTD_SYSFS, name, "size")) as f:
                size = int(f.read().strip(), 0)
        except (OSError, ValueError):
            continue
        if start <= address and address + length <= start + size:
            try:
                with open("/dev/" + name, "rb") as f:
                    f.seek(address - start)
                    return f.read(length)
            except OSError:
                return None
    return None


def read_spt(sysfs=RSU_SYSFS):
    """the RSU sub-partition table as {name: (offset, length)}, or None (no
    RSU driver, no flash, no valid table - SPT1 is the backup of SPT0)"""
    for which in ("spt0_address", "spt1_address"):
        try:
            with open(os.path.join(sysfs, which)) as f:
                off = int(f.read().strip(), 0)
        except (OSError, ValueError):
            return None
        raw = read_flash(off, 32 + 127 * SPT_ENTRY.size)
        if raw is None:
            continue
        magic, _version, entries = struct.unpack_from("<III", raw, 0)
        if magic != SPT_MAGIC:
            continue
        parts = {}
        for i in range(min(entries, 127)):
            name, lo, hi, length, _flags = SPT_ENTRY.unpack_from(raw, 32 + i * SPT_ENTRY.size)
            parts[name.split(b"\0")[0].decode("ascii", "replace")] = (lo | hi << 32, length)
        return parts
    return None


def running_slot(spt, sysfs=RSU_SYSFS):
    """the SPT name of the image the SDM booted (P1, FACTORY_IMAGE), or None"""
    try:
        with open(os.path.join(sysfs, "current_image")) as f:
            current = int(f.read().strip(), 0)
    except (OSError, ValueError):
        return None
    for name, (off, _) in spt.items():
        if off == current and not name.startswith(("SSBL.", "CORE.")):
            return name
    return None


def core_partition(slot):
    """CORE.<slot>; the factory image's is CORE.FACTORY_IM (16-character names)"""
    return "CORE." + ("FACTORY_IM" if slot.startswith("FACTORY_IM") else slot)


def read_qspi_core(spt, slot):
    """the core in the slot's CORE.<slot> partition (make_jic.sh's 4 KB header
    "core_size=0x..." then the core), or None"""
    part = spt.get(core_partition(slot))
    head = read_flash(part[0], CORE_HEADER) if part else None
    if not head:
        return None
    try:
        size = int(head.split(b"\0")[0].decode("ascii", "replace").strip().split("=")[1], 16)
    except (ValueError, IndexError):
        return None
    if not 0 < size <= part[1] - CORE_HEADER:
        return None
    return read_flash(part[0] + CORE_HEADER, size)


def setup_slot_firmware(firmware, boot):
    """RSU: the running slot, and its core directory <firmware>/rsu/<slot>,
    with <firmware>/de25_std.core.rbf pointing into it. The first time on
    this board the flat files there move in (they are the running core);
    the first boot of a slot without a core takes the one U-Boot loaded:
    the card's de25_std_<slot>.core.rbf, else QSPI CORE.<slot>. Without
    RSU: (None, firmware) - the flat layout."""
    spt = read_spt()
    slot = running_slot(spt) if spt else None
    if not slot:
        return None, firmware
    slot_dir = os.path.join(firmware, "rsu", slot)
    os.makedirs(slot_dir, exist_ok=True)
    link = os.path.join(firmware, CORE_NAME)
    if os.path.isfile(link) and not os.path.islink(link):
        for name in (CORE_NAME, MANIFEST_NAME, PENDING_NAME):
            for suffix in PENDING_SUFFIXES:
                src = os.path.join(firmware, name + suffix)
                if os.path.exists(src) and not os.path.exists(os.path.join(slot_dir, name + suffix)):
                    os.replace(src, os.path.join(slot_dir, name + suffix))
                elif os.path.exists(src):
                    os.remove(src)
        log(f"FPGA core: the flat /lib/firmware files moved to rsu/{slot}/")
    target = os.path.join(slot_dir, CORE_NAME)
    if not os.path.exists(target):
        core, source = None, None
        card = os.path.join(boot, f"de25_std_{slot}.core.rbf") if boot else None
        mounted = False
        try:
            if card and not os.path.ismount(boot):
                mounted = subprocess.run(["mount", "-o", "ro", boot], capture_output=True,
                                         timeout=20).returncode == 0
            if card and os.path.isfile(card):
                with open(card, "rb") as f:
                    core, source = f.read(), card
        except (OSError, subprocess.SubprocessError):
            pass
        finally:
            if mounted:
                subprocess.run(["umount", boot], check=False, timeout=20)
        if core is None:
            core, source = read_qspi_core(spt, slot), "QSPI " + core_partition(slot)
        if core:
            write_file(target, core)
            log(f"FPGA core: {slot} had none here - took the one U-Boot loads ({source}), "
                "no manifest")
    rel = os.path.join("rsu", slot, CORE_NAME)
    if not (os.path.islink(link) and os.readlink(link) == rel):
        tmp = link + ".new"
        if os.path.lexists(tmp):
            os.remove(tmp)
        os.symlink(rel, tmp)
        os.replace(tmp, link)
    log(f"FPGA core: running image {slot}, its core in {slot_dir}")
    return slot, slot_dir


def rsu_client(*args, timeout=300):
    """run rsu_client; (ok, output) - it reports errors as lines "ERROR: ..."
    (its status log has the fields "ERROR LOC" / "ERROR DETAILS" too)"""
    try:
        r = subprocess.run(["rsu_client", *map(str, args)], capture_output=True, text=True,
                           timeout=timeout)
    except (OSError, subprocess.SubprocessError) as e:
        return False, str(e)
    out = (r.stdout + r.stderr).strip()
    return r.returncode == 0 and not re.search(r"^ERROR:", out, re.M), out


def rsu_slots():
    """librsu's slots: {name: (number, offset, size)} - every non-reserved
    partition counts (P1, SSBL.*, CORE.*, UBOOT)"""
    ok, out = rsu_client("--count")
    m = ok and re.search(r"number of slots is (\d+)", out)
    if not m:
        raise CoreError("rsu_client --count: " + out[-200:])
    slots = {}
    for i in range(int(m.group(1))):
        ok, out = rsu_client("--list", i)
        fields = dict(l.strip().split(": ", 1) for l in out.splitlines() if ": " in l)
        if ok and "NAME" in fields:
            slots[fields["NAME"].strip()] = (i, int(fields.get("OFFSET", "0"), 16),
                                             int(fields.get("SIZE", "0"), 16))
    return slots


def rsu_status():
    """rsu_client --log as a dict (CURRENT IMAGE, FAIL IMAGE, STATE, ...), or {}"""
    ok, out = rsu_client("--log", timeout=30)
    if not ok:
        return {}
    return {k.strip().lower().replace(" ", "_"): v.strip()
            for k, v in (l.split(":", 1) for l in out.splitlines() if ":" in l)}


def check_rsu_bundle(path):
    """the files of a make_rsu_bundle.py bundle and its manifest, checked"""
    try:
        with tarfile.open(path, "r:*") as tar:
            files = {os.path.normpath(m.name): tar.extractfile(m).read()
                     for m in tar.getmembers() if m.isfile() and m.size <= CORE_MAX}
    except (OSError, tarfile.TarError, EOFError) as e:
        raise CoreError(f"not an RSU bundle: {e}") from None
    if RSU_MANIFEST not in files:
        raise CoreError(f"not an RSU bundle: no {RSU_MANIFEST} (a core bundle goes to /api/fpga)")
    try:
        manifest = json.loads(files[RSU_MANIFEST])
        if manifest.get("kind") != RSU_KIND:
            raise CoreError(f"not an RSU bundle for this board: kind {manifest.get('kind')!r}")
        if manifest.get("board") != BOARD_NAME:
            raise CoreError(f"an RSU bundle for {manifest.get('board')!r}, this board is {BOARD_NAME!r}")
        for name in RSU_FILES:
            want = manifest["files"][name]
            got = files.get(name)
            if got is None or len(got) != want["size"] or sha256(got) != want["sha256"]:
                raise CoreError(f"{name} does not match the manifest (missing, truncated or corrupt)")
        int(manifest["build_id"])
    except (KeyError, ValueError, TypeError) as e:
        raise CoreError(f"bad RSU manifest: {e}") from None
    return files, manifest


def read_manifest(path):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return None
    except ValueError as e:
        raise CoreError(f"{path}: {e}") from None


def write_file(path, data):
    """data to path through path.new: never a half-written path, even on FAT"""
    tmp = path + ".new"
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def check_bundle(path):
    """the core and manifest out of a deploy_fpga.py bundle, checked"""
    try:
        with tarfile.open(path, "r:*") as tar:
            files = {}
            for m in tar.getmembers():
                name = os.path.normpath(m.name)
                if name in (CORE_NAME, MANIFEST_NAME) and m.isfile() and m.size <= CORE_MAX:
                    files[name] = tar.extractfile(m).read()
    except (OSError, tarfile.TarError) as e:
        raise CoreError(f"not a core bundle: {e}") from None
    missing = [n for n in (CORE_NAME, MANIFEST_NAME) if n not in files]
    if missing:
        raise CoreError("not a core bundle, missing " + ", ".join(missing))
    core = files[CORE_NAME]
    try:
        manifest = json.loads(files[MANIFEST_NAME])
        size, digest = int(manifest["core_size"]), str(manifest["core_sha256"]).lower()
        int(manifest["build_id"])
        str(manifest["periphery_sha256"])
        board = manifest["board"]
    except (ValueError, KeyError, TypeError) as e:
        raise CoreError(f"bad manifest: {e}") from None
    if board != BOARD_NAME:
        raise CoreError(f"a core for {board!r}, this board is {BOARD_NAME!r}")
    if len(core) != size:
        raise CoreError(f"core is {len(core)} bytes, the manifest says {size} (truncated?)")
    if sha256(core) != digest:
        raise CoreError("core SHA-256 does not match the manifest (corrupt)")
    return core, files[MANIFEST_NAME], manifest


# --------------------------------------------------------------------------
# the server
# --------------------------------------------------------------------------
class Access:
    """Every register access, under one lock; pause/resume; the fan lease;
    loading the FPGA core."""

    def __init__(self, bridge, sim_hwmon=None, loader=None, firmware=FIRMWARE, boot=BOOT, slot=None):
        self.slot = slot                     # RSU: the running image's name, else None
        self.bridge = bridge
        self.sim = sim_hwmon
        self.loader = loader
        self.firmware = firmware
        self.boot = boot
        self.core_lock = threading.Lock()    # one load at a time
        self.loading = False
        self.last_load = None
        self.last_rsu = None
        self._p1_slot = None                 # librsu's slot number of P1, looked up once
        self._recover_install()
        self.lock = threading.Lock()
        self.paused_until = 0.0
        self.pause_reason = ""
        self.leases = {}                    # reg -> monotonic deadline
        self.counts = {"read": 0, "write": 0, "lease_expired": 0, "guard_refused": 0}
        self._fabric_ok = None              # the fabric guard (above): last answer
        self._fabric_checked = 0.0
        threading.Thread(target=self._watchdog, daemon=True).start()

    def paused(self):
        return time.monotonic() < self.paused_until

    def fabric_ready(self, recheck=False):
        """the fabric guard: is the LWH2F bridge out of reset? Cached for
        GUARD_RECHECK_S once it is; a simulated board always is."""
        check = getattr(self.bridge, "fabric_ready", None)
        if check is None:
            return True
        now = time.monotonic()
        if recheck or not self._fabric_ok or now - self._fabric_checked > GUARD_RECHECK_S:
            ok = bool(check())
            if ok != self._fabric_ok:
                log("fabric " + ("configured: register traffic allowed" if ok else
                                 "not configured (LWH2F bridge in reset): register traffic refused"))
            self._fabric_ok, self._fabric_checked = ok, now
        return self._fabric_ok

    def handle(self, req):
        op = req.get("op")
        if op == "ping":
            return {"ok": True, "pid": os.getpid()}
        if op == "status":
            now = time.monotonic()
            return {"ok": True, "pid": os.getpid(), "sim": self.sim is not None,
                    "paused": self.paused(), "pause_reason": self.pause_reason if self.paused() else "",
                    "fabric_ready": self._fabric_ok,
                    "leases": {str(r): round(d - now, 1) for r, d in self.leases.items()},
                    "counts": self.counts,
                    "plant": ({"ambient": self.sim.plant.ambient, "load": self.sim.plant.load,
                               "temp": round(self.sim.plant.temp, 3)} if self.sim else None)}
        if op in ("pause", "resume") and self.loading:
            return {"ok": False, "error": "an FPGA core load is running"}
        if op == "pause":
            secs = min(float(req.get("seconds", 60)), 600.0)
            with self.lock:                  # waits for the access in flight
                self.paused_until = time.monotonic() + secs
                self.pause_reason = str(req.get("reason", "paused"))
            log(f"register traffic paused for {secs:.0f} s: {self.pause_reason}")
            return {"ok": True, "seconds": secs}
        if op == "resume":
            with self.lock:
                self.paused_until = 0.0
            log("register traffic resumed")
            return {"ok": True}
        if op == "sim":
            if not self.sim:
                return {"ok": False, "error": "not simulated"}
            if "ambient" in req:
                self.sim.plant.ambient = float(req["ambient"])
            if "load" in req:
                self.sim.plant.load = float(req["load"])
            if "temp" in req:
                self.sim.plant.temp = float(req["temp"])
            if "fan_stuck" in req:
                self.bridge.set_fan_stuck(req["fan_stuck"])
            log(f"sim plant: ambient {self.sim.plant.ambient} C, load {self.sim.plant.load}")
            return {"ok": True, "ambient": self.sim.plant.ambient, "load": self.sim.plant.load}
        if op == "release":
            self.leases.pop(int(req["reg"]), None)
            return {"ok": True}
        if op == "core":
            return self.core_info()
        if op == "rsu":
            return self.rsu_info()
        if op == "install_rsu":
            if not self.slot:
                return {"ok": False, "error": "no RSU flash layout (or no rsu_client) here"}
            if not self.core_lock.acquire(blocking=False):
                return {"ok": False, "error": "a core load or RSU update is already running"}
            try:
                return self.install_rsu(str(req["bundle"]), bool(req.get("reboot", True)))
            finally:
                self.core_lock.release()
        if op in ("reload", "install_core"):
            if not self.loader:
                return {"ok": False, "error": "no FPGA core loader"}
            if not self.core_lock.acquire(blocking=False):
                return {"ok": False, "error": "a core load is already running"}
            try:
                if op == "reload":
                    return self.reload()
                return self.install_core(str(req["bundle"]), bool(req.get("force")))
            finally:
                self.core_lock.release()
        if op not in ("read", "read_many", "write"):
            return {"ok": False, "error": f"unknown op {op!r}"}
        with self.lock:
            if self.paused():
                return {"ok": False, "paused": True, "error": "paused: " + self.pause_reason}
            if not self.fabric_ready():
                self.counts["guard_refused"] += 1
                return {"ok": False, "paused": True,
                        "error": "fabric not configured (LWH2F bridge in reset - no FPGA core loaded)"}
            if op == "read":
                reg = self._reg(req["reg"])
                self.counts["read"] += 1
                return {"ok": True, "value": self.bridge.read(reg)}
            if op == "read_many":
                regs = [self._reg(r) for r in req["regs"]]
                self.counts["read"] += len(regs)
                return {"ok": True, "values": [self.bridge.read(r) for r in regs]}
            reg = self._reg(req["reg"])
            self.bridge.write(reg, int(req["value"]))
            self.counts["write"] += 1
            if "lease" in req:
                self.leases[reg] = time.monotonic() + max(1.0, float(req["lease"]))
            return {"ok": True, "value": self.bridge.read(reg)}

    # ---- the FPGA core ----------------------------------------------------
    def _core_path(self, name, suffix=""):
        return os.path.join(self.firmware, name + suffix)

    def core_info(self):
        out = {"ok": True, "running_build_id": None, "last_load": self.last_load,
               "loading": self.core_lock.locked(), "slot": self.slot}
        with self.lock:
            if not self.paused() and self.fabric_ready():
                out["running_build_id"] = self.bridge.read(REG_BUILD_ID)
        for key, suffix in (("installed", ""), ("previous", ".prev")):
            try:
                out[key] = read_manifest(self._core_path(MANIFEST_NAME, suffix))
            except CoreError as e:
                out[key] = {"error": str(e)}
        return out

    def _load(self, expect_build_id, saved=None):
        """load the installed core; registers paused around it, restored after.
        saved: the registers to restore - a rollback passes the ones read before
        the failed load, since the fabric may not be there to read them from."""
        with self.lock:
            if saved is None:
                saved = ({r: self.bridge.read(r) for r in RESET_VALUES} if self.fabric_ready(True)
                         else dict(RESET_VALUES))
            self._saved = saved
            # no time limit while the load runs: an LWH2F access to a fabric
            # half-way through configuration hangs the CPU. A load that never
            # returns (the SDM stuck on a damaged core, seen on the DE25-Nano
            # 2026-10-17) keeps the registers paused; the fan keeps its last
            # speed (the MAX6650 has no thermal fail-safe, plan §5.17).
            self.paused_until = math.inf
            self.loading = True
            self.pause_reason = "FPGA core load"
        log("FPGA core load: register traffic paused")
        t0 = time.monotonic()
        try:
            self.loader.load()
            secs = time.monotonic() - t0
            time.sleep(POST_LOAD_SETTLE_S)
            if not self.fabric_ready(recheck=True):
                raise CoreError("the LWH2F bridge is still in reset after the load")
            board_id = self.bridge.read(REG_ID)
            variant = self.bridge.read(REG_VARIANT)
            build_id = self.bridge.read(REG_BUILD_ID)
            if board_id != BOARD_ID:
                raise CoreError(f"board id {board_id:#x} after the load, expected {BOARD_ID:#x}")
            if variant != BOARD_VARIANT:
                raise CoreError(f"board variant {variant:#x} after the load, expected "
                                f"{BOARD_VARIANT:#x} (a core for another board?)")
            if expect_build_id is not None and build_id != expect_build_id:
                raise CoreError(f"build id {build_id} after the load, the manifest says "
                                f"{expect_build_id}")
            for r, v in saved.items():       # the load reset them
                self.bridge.write(r, v)
            return {"seconds": round(secs, 2), "build_id": build_id}
        finally:
            with self.lock:
                held = time.monotonic() - t0
                for r in self.leases:        # a pause must not expire a lease
                    self.leases[r] += held
                self.paused_until = 0.0
                self.loading = False
            log(f"FPGA core load: done after {time.monotonic() - t0:.2f} s, traffic resumed")

    def _installed_build_id(self):
        m = read_manifest(self._core_path(MANIFEST_NAME))
        return int(m["build_id"]) if m and "build_id" in m else None

    def reload(self):
        if not os.path.isfile(self._core_path(CORE_NAME)):
            return {"ok": False, "error": "no " + self._core_path(CORE_NAME)}
        try:
            self.loader.check()
            res = self._load(self._installed_build_id())
        except (CoreError, OSError) as e:
            self.last_load = {"op": "reload", "ok": False, "error": str(e), "at": time.time()}
            log("FPGA core reload failed:", e)
            return {"ok": False, "error": str(e)}
        self.last_load = {"op": "reload", "ok": True, "at": time.time(), **res}
        log(f"FPGA core reloaded: build {res['build_id']}, {res['seconds']} s")
        return {"ok": True, **res}

    def install_core(self, bundle, force=False):
        core_path, man_path = self._core_path(CORE_NAME), self._core_path(MANIFEST_NAME)
        try:
            core, man_raw, manifest = check_bundle(bundle)
            installed = read_manifest(man_path)
            if installed is None and not force:
                raise CoreError("the installed core has no manifest - the periphery it fits "
                                "is unknown (force to install anyway)")
            if installed is not None and not force and \
                    manifest["periphery_sha256"] != installed.get("periphery_sha256"):
                raise CoreError("the core does not fit the first stage in QSPI: periphery "
                                "(pins, HPS, DDR) %s, the board's %s - program the .jic first"
                                % (manifest["periphery_sha256"][:12],
                                   str(installed.get("periphery_sha256"))[:12]))
            self.loader.check()
        except (CoreError, OSError) as e:
            self.last_load = {"op": "install", "ok": False, "error": str(e), "at": time.time()}
            log("FPGA core refused:", e)
            return {"ok": False, "error": str(e), "refused": True}
        # keep the running core as .prev, then the new one in its place
        if os.path.exists(core_path):
            shutil.copyfile(core_path, core_path + ".prev")
            if os.path.exists(man_path):
                shutil.copyfile(man_path, man_path + ".prev")
            elif os.path.exists(man_path + ".prev"):
                os.remove(man_path + ".prev")
        # pending: the install is under way. Found at startup, it never
        # finished (the board hung or lost power) - _recover_install
        write_file(self._core_path(PENDING_NAME), b"%d\n" % int(manifest["build_id"]))
        write_file(man_path, man_raw)
        write_file(core_path, core)
        try:
            res = self._load(int(manifest["build_id"]))
        except (CoreError, OSError) as e:
            log("FPGA core install failed:", e, "- loading the previous core")
            out = {"ok": False, "error": str(e), "rolled_back": False}
            if os.path.exists(core_path + ".prev"):
                os.replace(core_path + ".prev", core_path)
                if os.path.exists(man_path + ".prev"):
                    os.replace(man_path + ".prev", man_path)
                else:
                    os.remove(man_path)
                try:
                    out["previous"] = self._load(self._installed_build_id(), self._saved)
                    out["rolled_back"] = True
                except (CoreError, OSError) as e2:
                    out["rollback_error"] = str(e2)
                    log("FPGA core rollback failed too:", e2)
            self._clear_pending()
            self.last_load = {"op": "install", "at": time.time(), **out}
            return out
        self._clear_pending()
        # it runs: the card's copy too, so the next power-on loads it
        boot = self._write_boot_copy(core)
        self.last_load = {"op": "install", "ok": True, "at": time.time(), "boot": boot, **res}
        log(f"FPGA core installed: build {res['build_id']}, {res['seconds']} s, "
            f"card copy {'written' if boot['written'] else 'NOT written'}")
        return {"ok": True, "boot": boot, **res}

    # ---- remote system update ---------------------------------------------
    def rsu_info(self):
        out = {"ok": True, "slot": self.slot, "rsu": bool(self.slot), "last_update": self.last_rsu}
        if not self.slot:
            return out
        out["status"] = rsu_status()
        try:
            with open("/run/rsu-confirm") as f:
                out["confirm"] = f.read().strip()
        except OSError:
            out["confirm"] = None
        try:
            with open(os.path.join(os.path.dirname(self.firmware), RSU_SLOT, RSU_MANIFEST)) as f:
                out["installed"] = json.load(f)
        except (OSError, ValueError):
            out["installed"] = None
        # whether P1 holds a bootable image now: rsu.json says what was last
        # written, but an update cut short leaves P1 erased ("[disabled]")
        try:
            if self._p1_slot is None:
                self._p1_slot = rsu_slots()[RSU_SLOT][0]
            ok, listing = rsu_client("--list", self._p1_slot, timeout=30)
            prio = re.search(r"PRIORITY:\s*(\S+)", listing) if ok else None
            out["p1_priority"] = prio.group(1) if prio else None
        except (CoreError, KeyError):
            out["p1_priority"] = None
        return out

    def install_rsu(self, bundle, reboot=True):
        """the bundle into slot P1 - see the module docstring for the order"""
        t0 = time.time()
        try:
            files, manifest = check_rsu_bundle(bundle)
            slots = rsu_slots()
            parts = {n: slots.get(n) for n in (RSU_SLOT, "SSBL." + RSU_SLOT, "CORE." + RSU_SLOT)}
            missing = [n for n, v in parts.items() if v is None]
            if missing:
                raise CoreError("the flash has no " + ", ".join(missing) + " (make_jic.sh RSU layout)")
            core = files[CORE_NAME]
            core_raw = ("core_size=%#x\n" % len(core)).encode().ljust(CORE_HEADER, b"\0") + core
            for name, data in ((RSU_SLOT, files["app.rpd"]), ("SSBL." + RSU_SLOT, files["u-boot.itb"]),
                               ("CORE." + RSU_SLOT, core_raw)):
                if len(data) > parts[name][2]:
                    raise CoreError(f"{name} is {parts[name][2]:#x} bytes, the update needs {len(data):#x}")
        except CoreError as e:
            self.last_rsu = {"ok": False, "refused": True, "error": str(e), "at": time.time()}
            log("RSU update refused:", e)
            return {"ok": False, "refused": True, "error": str(e)}

        staging = os.path.join(os.path.dirname(self.firmware), ".rsu-staging")
        os.makedirs(staging, exist_ok=True)
        steps = []
        try:
            def run(what, *args):
                ok, out = rsu_client(*args)
                steps.append(what)
                if not ok:
                    raise CoreError(f"{what}: {out[-300:]}")
            for name, data in (("app.rpd", files["app.rpd"]), ("u-boot.itb", files["u-boot.itb"]),
                               ("core.bin", core_raw)):
                write_file(os.path.join(staging, name), data)
            p1, ssbl, corep = (parts[n][0] for n in (RSU_SLOT, "SSBL." + RSU_SLOT, "CORE." + RSU_SLOT))
            log(f"RSU update to build {manifest['build_id']}: {RSU_SLOT} erased first - "
                "a power cut from here on boots the factory image")
            run("erase P1", "--erase", p1)
            run("erase SSBL.P1", "--erase", ssbl)
            run("write SSBL.P1", "--add-raw", os.path.join(staging, "u-boot.itb"), "--slot", ssbl)
            run("erase CORE.P1", "--erase", corep)
            run("write CORE.P1", "--add-raw", os.path.join(staging, "core.bin"), "--slot", corep)
            boot = self._write_boot_files({f"u-boot_{RSU_SLOT}.itb": files["u-boot.itb"],
                                           f"de25_std_{RSU_SLOT}.core.rbf": core})
            steps.append("card")
            if not boot["written"]:
                raise CoreError("card: " + boot.get("error", "not written"))
            slot_dir = os.path.join(os.path.dirname(self.firmware), RSU_SLOT)
            os.makedirs(slot_dir, exist_ok=True)
            write_file(os.path.join(slot_dir, MANIFEST_NAME), files[MANIFEST_NAME])
            write_file(os.path.join(slot_dir, CORE_NAME), core)
            write_file(os.path.join(slot_dir, RSU_MANIFEST), files[RSU_MANIFEST])
            steps.append("/lib/firmware")
            run("write P1", "--add", os.path.join(staging, "app.rpd"), "--slot", p1)
            run("verify P1", "--verify", os.path.join(staging, "app.rpd"), "--slot", p1)
        except (CoreError, OSError) as e:
            self.last_rsu = {"ok": False, "error": str(e), "steps": steps, "at": time.time(),
                             "build_id": manifest["build_id"]}
            log("RSU update failed:", e, "- P1 is not bootable, the factory image boots next")
            return {"ok": False, "error": str(e), "steps": steps,
                    "note": "P1 is erased or incomplete: the next boot runs the factory image"}
        finally:
            shutil.rmtree(staging, ignore_errors=True)
        secs = round(time.time() - t0, 1)
        self.last_rsu = {"ok": True, "build_id": manifest["build_id"], "steps": steps,
                         "seconds": secs, "at": time.time(), "rebooting": reboot}
        log(f"RSU update written: build {manifest['build_id']} in P1, {secs} s"
            + (" - rebooting into it" if reboot else ""))
        if reboot:
            # load P1 from flash at the reboot (the running image's own address
            # works too - tested), after the reply is out
            with open(os.path.join(RSU_SYSFS, "reboot_image"), "w") as f:
                f.write(hex(parts[RSU_SLOT][1]))
            threading.Timer(2.0, lambda: subprocess.run(["reboot"], check=False)).start()
        return {"ok": True, "build_id": manifest["build_id"], "seconds": secs, "steps": steps,
                "rebooting": reboot}

    def _clear_pending(self):
        try:
            os.remove(self._core_path(PENDING_NAME))
        except FileNotFoundError:
            pass

    def _recover_install(self):
        """An install that never finished (the load hung the board, or the
        power went): the core in /lib/firmware is the untested one. The card
        still has the last good core (written only after a good load), so the
        board runs that - put the .prev files back to match it."""
        if not os.path.exists(self._core_path(PENDING_NAME)):
            return
        core_path, man_path = self._core_path(CORE_NAME), self._core_path(MANIFEST_NAME)
        if os.path.exists(core_path + ".prev"):
            os.replace(core_path + ".prev", core_path)
            if os.path.exists(man_path + ".prev"):
                os.replace(man_path + ".prev", man_path)
            elif os.path.exists(man_path):
                os.remove(man_path)
            log("FPGA core: an install did not finish - the previous core is the installed one again")
            self.last_load = {"op": "recover", "ok": True, "at": time.time(),
                              "note": "an install did not finish; the previous core is back"}
        self._clear_pending()

    def _write_boot_copy(self, core):
        """The core onto the card's FAT partition, under the running image's name"""
        name = f"de25_std_{self.slot}.core.rbf" if self.slot else CORE_NAME
        boot = self._write_boot_files({name: core})
        boot["file"] = name
        return boot

    def _write_boot_files(self, files):
        """{name: bytes} onto the card's FAT partition. The board keeps it
        unmounted (a power cut cannot catch FAT mid-write then): mounted only
        for this."""
        boot = {"written": False}
        if not self.boot or not os.path.isdir(self.boot):
            boot["error"] = "no " + (self.boot or "boot directory")
            return boot
        mounted = False
        try:
            if not os.path.ismount(self.boot) and not self.sim:
                subprocess.run(["mount", self.boot], check=True, capture_output=True, timeout=20)
                mounted = True
            for name, data in files.items():
                write_file(os.path.join(self.boot, name), data)
            os.sync()
            boot["written"] = True
        except (OSError, subprocess.SubprocessError) as e:
            boot["error"] = str(e)
            log("the card's copy was not written:", e)
        finally:
            if mounted:
                subprocess.run(["umount", self.boot], check=False, timeout=20)
        return boot

    @staticmethod
    def _reg(r):
        r = int(r)
        if not 0 <= r < MAP_SIZE // REG_STRIDE:
            raise ValueError(f"register {r} out of range")
        return r

    def _watchdog(self):
        while True:
            time.sleep(0.5)
            now = time.monotonic()
            for reg, deadline in list(self.leases.items()):
                if now < deadline or self.paused():
                    continue
                self.leases.pop(reg, None)
                if reg != REG_FAN_KTACH or not self.fabric_ready():
                    continue
                safe = rpm_to_ktach(SAFE_FAN_RPM)
                with self.lock:
                    ktach = self.bridge.read(REG_FAN_KTACH) & 0xFF
                    if ktach > safe:                # slower than safe: raise it
                        self.bridge.write(REG_FAN_KTACH, safe)
                self.counts["lease_expired"] += 1
                log(f"fan lease expired (the controller went silent): {ktach_to_rpm(ktach):.0f} -> "
                    f"{ktach_to_rpm(min(ktach, safe)):.0f} rpm")


def serve(access, path):
    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            for line in self.rfile:
                if not line.strip():
                    continue
                try:
                    resp = access.handle(json.loads(line))
                except (ValueError, KeyError, TypeError) as e:
                    resp = {"ok": False, "error": f"bad request: {e}"}
                except OSError as e:
                    resp = {"ok": False, "error": f"bridge: {e}"}
                try:
                    self.wfile.write(json.dumps(resp).encode() + b"\n")
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    return

    class Server(socketserver.ThreadingUnixStreamServer):
        daemon_threads = True

    # bind beside the old name and rename over it: clients never see a
    # missing socket file during a restart, only a refused connection
    tmp = path + ".new"
    if os.path.exists(tmp):
        os.remove(tmp)
    srv = Server(tmp, Handler)
    os.chmod(tmp, 0o660)
    os.replace(tmp, path)
    return srv


# --------------------------------------------------------------------------
# the client the other processes use
# --------------------------------------------------------------------------
class FpgaUnavailable(Exception):
    """The access process is not answering (or register traffic is paused)."""


class FpgaClient:
    """Thread-safe, reconnecting client of fpga.sock. Every failure is an
    FpgaUnavailable - callers report it rather than crash."""

    def __init__(self, run, timeout=2.0):
        self.path = os.path.join(run, SOCKET_NAME)
        self.timeout = timeout
        self._sock = None
        self._rfile = None
        self._lock = threading.Lock()

    def _close(self):
        try:
            if self._sock:
                self._sock.close()
        except OSError:
            pass
        self._sock = self._rfile = None

    def call(self, **req):
        resp = self.call_raw(**req)
        if not resp.get("ok"):
            if resp.get("paused"):
                raise FpgaUnavailable("FPGA access " + resp.get("error", "paused"))
            raise ValueError(resp.get("error", "request failed"))
        return resp

    def call_raw(self, **req):
        """the reply as it is, ok or not (a failed core install carries details)"""
        with self._lock:
            for attempt in (0, 1):          # one reconnect: the server may have restarted
                try:
                    if self._sock is None:
                        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                        s.settimeout(self.timeout)
                        s.connect(self.path)
                        self._sock, self._rfile = s, s.makefile("rb")
                    self._sock.sendall(json.dumps(req).encode() + b"\n")
                    line = self._rfile.readline()
                    if not line:
                        raise ConnectionResetError("closed")
                    resp = json.loads(line)
                    break
                except (OSError, ValueError) as e:
                    self._close()
                    # a reply that timed out is not resent: the request may be
                    # running (a core load) - only a dropped connection is
                    if attempt or isinstance(e, socket.timeout):
                        raise FpgaUnavailable("FPGA access unavailable (%s)" % e) from None
        return resp

    def read(self, reg):
        return self.call(op="read", reg=reg)["value"]

    def read_many(self, regs):
        return self.call(op="read_many", regs=list(regs))["values"]

    def write(self, reg, value, lease=None):
        req = {"op": "write", "reg": reg, "value": int(value)}
        if lease:
            req["lease"] = lease
        return self.call(**req)["value"]


def main():
    ap = argparse.ArgumentParser(description="DE25-Standard FPGA register access process")
    ap.add_argument("--run", default=None, help="socket directory (default /run/de25web, "
                    "or /tmp/de25web-sim with --sim; env DE25WEB_RUN)")
    ap.add_argument("--sim", action="store_true", help="simulated registers and thermal plant")
    ap.add_argument("--sim-ambient", type=float, default=None, help="plant ambient, C (default 25)")
    ap.add_argument("--sim-load", type=float, default=None, help="plant heat scale (default 1.0)")
    ap.add_argument("--firmware", default=None, help="the core's directory (default "
                    "/lib/firmware, or <run>/sim-firmware with --sim)")
    ap.add_argument("--boot", default=None, help="the card's FAT partition, where the core's "
                    "boot copy goes (default /boot, or <run>/sim-boot with --sim; '' for none)")
    ap.add_argument("--client", nargs=argparse.REMAINDER,
                    help="send one request: read N | write N V | status | pause S | resume | "
                         "sim ambient=V load=V | ping | core | reload | install_core BUNDLE [force]")
    args = ap.parse_args()
    run = run_dir(args.run, args.sim)

    if args.client is not None:
        c, a = FpgaClient(run, timeout=120.0), args.client
        try:
            if a[0] == "read":
                print(c.read(int(a[1], 0)))
            elif a[0] == "write":
                print(c.write(int(a[1], 0), int(a[2], 0)))
            elif a[0] == "pause":
                print(json.dumps(c.call(op="pause", seconds=float(a[1]) if len(a) > 1 else 60)))
            elif a[0] == "install_core":
                print(json.dumps(c.call(op="install_core", bundle=os.path.abspath(a[1]),
                                        force=a[2:3] == ["force"])))
            elif a[0] == "sim":
                print(json.dumps(c.call(op="sim", **{k: float(v) for k, v in
                                                     (x.split("=") for x in a[1:])})))
            else:
                print(json.dumps(c.call(op=a[0])))
        except (FpgaUnavailable, ValueError, IndexError) as e:
            sys.exit(str(e))
        return

    os.makedirs(run, exist_ok=True)
    if args.sim:
        bridge = SimBridge(os.path.join(run, "sim-regs.json"))
        sim = SimHwmon(hwmon_root(run, True), bridge, args.sim_ambient, args.sim_load)
        sim.start()
        firmware = args.firmware or os.path.join(run, "sim-firmware")
        boot = args.boot if args.boot is not None else os.path.join(run, "sim-boot")
        for d in (firmware, boot):
            os.makedirs(d, exist_ok=True)
        if not os.path.exists(os.path.join(firmware, CORE_NAME)):
            with open(os.path.join(firmware, CORE_NAME), "wb") as f:
                f.write(b"simulated core\n")
        loader = SimLoader(firmware, bridge)
        man = read_manifest(os.path.join(firmware, MANIFEST_NAME))
        bridge.configure(int(man.get("build_id", 0)) if man else 0)
    else:
        bridge, sim = Bridge(), None
        root = args.firmware or FIRMWARE
        boot = args.boot if args.boot is not None else BOOT
        loader = KernelLoader(root)              # the overlay loads <root>/de25_std.core.rbf
        try:
            slot, firmware = setup_slot_firmware(root, boot)
        except OSError as e:
            log("FPGA core: per-image layout not set up:", e)
            slot, firmware = None, root
    if args.sim:
        slot = None
    access = Access(bridge, sim, loader, firmware, boot, slot)
    srv = serve(access, os.path.join(run, SOCKET_NAME))
    log(f"serving {os.path.join(run, SOCKET_NAME)}" + (" [simulated board]" if sim else ""))
    srv.serve_forever()


if __name__ == "__main__":
    main()
