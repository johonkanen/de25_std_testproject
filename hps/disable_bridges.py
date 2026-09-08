#!/usr/bin/env python3
"""Disable every FPGA<->HPS bridge in ip/hps_subsys/agilex_hps.ip.

agilex_hps.ip is vendored verbatim from the DE25 GHRD
(Demonstration/SoC_FPGA/GHRD/hps_subsys/ip/hps_subsys/agilex_hps.ip), where
all four bridges are enabled.  This flips five parameters so the HPS is a
standalone Linux host with no fabric AXI ports:

    H2F_Width          128 -> 0   (HPS-to-FPGA)
    LWH2F_Width         32 -> 0   (lightweight HPS-to-FPGA)
    f2s_data_width     256 -> 0   (FPGA-to-HPS, ACE5-Lite)
    f2sdram_data_width 256 -> 0   (FPGA-to-SDRAM)
    F2H_IRQ_Enable    true -> false

Idempotent.  Run once after re-vendoring agilex_hps.ip, then re-run
qsys-generate and gen_hps_min.py.
"""
import os
import re

IP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ip/hps_subsys/agilex_hps.ip")
WANT = {
    "H2F_Width": "0",
    "LWH2F_Width": "0",
    "f2s_data_width": "0",
    "f2sdram_data_width": "0",
    "F2H_IRQ_Enable": "false",
}


def main():
    x = open(IP, encoding="latin1").read()
    for pid, new in WANT.items():
        pat = re.compile(
            r'(<ipxact:parameter parameterId="%s"[^>]*>\s*'
            r"<ipxact:name>%s</ipxact:name>\s*"
            r"<ipxact:displayName>[^<]*</ipxact:displayName>\s*"
            r"<ipxact:value>)([^<]*)(</ipxact:value>)" % (re.escape(pid), re.escape(pid))
        )
        m = pat.search(x)
        if not m:
            raise SystemExit("parameter %s not found in %s" % (pid, IP))
        if m.group(2).strip() != new:
            x = pat.sub(lambda mm: mm.group(1) + new + mm.group(3), x, count=1)
            print("%-20s %s -> %s" % (pid, m.group(2).strip(), new))
        else:
            print("%-20s already %s" % (pid, new))
    open(IP, "w", encoding="latin1").write(x)


if __name__ == "__main__":
    main()
