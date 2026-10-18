#!/usr/bin/env bash
# Combine the FPGA bitstream, the U-Boot SPL and U-Boot proper into a QSPI
# flash image (.jic) for the DE25-Standard. Run ./build.sh fpga and
# ./build.sh linux first (or just ./build.sh all).
#
#   ./build.sh jic      (or linux/make_jic.sh)
#
# QSPI layout (16 MB MT25QU128):
#   0x000000  boot info
#   0x200000  P1: phase 1 (FPGA-first: the whole bitstream, ~3 MB;
#             HPS-first: HPS I/O, DDR I/O) + SPL
#   0xA00000  u-boot.itb (QSPI_UBOOT_OFFS, the SPL's CONFIG_SYS_SPI_U_BOOT_OFFS)
#   0xC00000  HPS-first only: 4 KB "core_size=0x..." header + the FPGA core
#             (QSPI_CORE_OFFS, U-Boot's preboot loads it when the card has none)
# The SPL loads u-boot.itb from the SD card's FAT partition if it can, else
# this QSPI copy, so a blank or broken card still reaches a U-Boot prompt
# (linux/tools/sd_recover.py rewrites the card from there). Kernel, dtb and
# rootfs always come from the SD card.
#
# The .sof comes from fpga/build_de25_soc.tcl: QSPI_OWNERSHIP HPS, and
# "AFTER INIT_DONE" unless HPS_FIRST=1 ("HPS FIRST").
#
# Env overrides: BUILD_DIR=, SOF=, SPL=, UBOOT_ITB=, JIC=, CORE_RBF=,
# QSPI_UBOOT_OFFS=, QSPI_CORE_OFFS= (both must match the U-Boot build).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(cd "${HERE}/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${TOP}/build}"
SOF="${SOF:-${BUILD_DIR}/fpga/output_files/de25_soc.sof}"
SPL="${SPL:-${BUILD_DIR}/linux/out/spl/u-boot-spl-dtb.hex}"
UBOOT_ITB="${UBOOT_ITB:-${BUILD_DIR}/linux/out/u-boot.itb}"
JIC="${JIC:-${BUILD_DIR}/images/de25_std.jic}"
CORE_RBF="${CORE_RBF:-${BUILD_DIR}/images/de25_std.core.rbf}"
MANIFEST="${CORE_RBF%.rbf}.json"
QSPI_UBOOT_OFFS="${QSPI_UBOOT_OFFS:-0x00A00000}"
QSPI_CORE_OFFS="${QSPI_CORE_OFFS:-0x00C00000}"

# DE25-Standard: Micron MT25QU128 (16 MB, confirmed by quartus_pgm's JTAG
# autodetect); flash loader = the full device string (the DE25-Nano found an
# abbreviated one resolves a different JTAG IDCODE)
DEVICE="${DEVICE:-MT25QU128}"
FLASH_LOADER="${FLASH_LOADER:-A5ED013BB32AE4SCS}"

[[ -f "${SOF}" ]]       || { echo "missing ${SOF} - ./build.sh fpga first"; exit 1; }
[[ -f "${SPL}" ]]       || { echo "missing ${SPL} - ./build.sh linux first"; exit 1; }
[[ -f "${UBOOT_ITB}" ]] || { echo "missing ${UBOOT_ITB} - ./build.sh linux first"; exit 1; }
mkdir -p "$(dirname "${JIC}")" "$(dirname "${CORE_RBF}")"

# HPS-first .sof: the .jic gets only phase 1; the FPGA core is a separate
# .core.rbf that U-Boot loads from the SD card or from its QSPI copy.
# quartus_pfg refuses hps_core_only on an AFTER INIT_DONE .sof - that is
# the test.
HPS_FIRST=0
rm -f "${CORE_RBF}" "${MANIFEST}"
if quartus_pfg -c "${SOF}" "${CORE_RBF}" -o hps_core_only=ON > "${JIC%.jic}_core.log" 2>&1 && [[ -s "${CORE_RBF}" ]]; then
    HPS_FIRST=1
    echo ">> HPS-first .sof: core in ${CORE_RBF} ($(stat -c %s "${CORE_RBF}") bytes) - copy it to the SD card's FAT partition"
    # the core's manifest (checked before a load over the network):
    #   build_id          register 19 of this build (build_id_pkg.vhd)
    #   board             "de25-std"; register 18 says the same
    #   periphery_sha256  what phase 1 fixes and a core must match: the
    #                     fitter's pin table (every pin's location, direction
    #                     and I/O standard; it names the Quartus version and
    #                     the device) and the HPS and EMIF IP. The phase-1
    #                     bitstream itself is no key: two builds of one
    #                     periphery differ in it (per-build hashes), and the
    #                     SDM loads either's core (DE25-Nano, 2026-10-17).
    python3 - "${CORE_RBF}" "${MANIFEST}" "${TOP}" "${SOF}" << 'PYMAN'
import hashlib, json, os, re, subprocess, sys, time
core_path, out, top, sof = sys.argv[1:]
core = open(core_path, "rb").read()
fpga_dir = os.path.dirname(os.path.dirname(sof))
pkg = os.path.join(fpga_dir, "build_id_pkg.vhd")
m = re.search(r'build_id\s*:.*x"([0-9a-fA-F]{8})"', open(pkg).read())
if not m:
    sys.exit(f"no build id in {pkg}")
if os.path.getmtime(pkg) > os.path.getmtime(sof):
    sys.exit(f"{pkg} is newer than {sof} - rebuild (./build.sh fpga) first")
h = hashlib.sha256()
pins = sof[:-len(".sof")] + ".pin"
for line in open(pins):
    if line.strip() and not line.lstrip().startswith("--"):
        h.update(line.rstrip().encode() + b"\n")
for ip in ("fpga/hps/ip/hps_subsystem/hps_subsystem_intel_agilex_5_soc_0.ip",
           "fpga/hps/ip/hps_subsystem/hps_subsystem_emif_io96b_hps_0.ip"):
    h.update(hashlib.sha256(open(os.path.join(top, ip), "rb").read()).digest())
try:
    git = subprocess.check_output(["git", "describe", "--always", "--dirty"], cwd=top,
                                  text=True, stderr=subprocess.DEVNULL).strip()
except (OSError, subprocess.CalledProcessError):
    git = ""
build_id = int(m.group(1), 16)
manifest = {"format": 1, "board": "de25-std", "core_size": len(core),
            "core_sha256": hashlib.sha256(core).hexdigest(),
            "build_id": build_id, "built": time.strftime("%FT%TZ", time.gmtime(build_id)),
            "periphery_sha256": h.hexdigest(), "git": git}
with open(out, "w") as f:
    json.dump(manifest, f, indent=1)
    f.write("\n")
print(f">> manifest {out}: build {build_id}, periphery {h.hexdigest()[:12]}, git {git}")
PYMAN
else
    rm -f "${CORE_RBF}"
    echo ">> FPGA-first .sof (AFTER INIT_DONE): the core is in the .jic"
fi

# clear of the bitstream (~3 MB from 0x200000) and inside the 16 MB
uboot_size=$(stat -c %s "${UBOOT_ITB}")
(( QSPI_UBOOT_OFFS >= 0x600000 && QSPI_UBOOT_OFFS + uboot_size <= 0x1000000 )) || {
    echo "QSPI_UBOOT_OFFS ${QSPI_UBOOT_OFFS} does not fit u-boot.itb after the bitstream"; exit 1; }
echo ">> bitstream + SPL, u-boot.itb at ${QSPI_UBOOT_OFFS}"
PFG="${JIC%.jic}.pfg"
NAME="$(basename "${JIC%.jic}")"
# quartus_pfg takes raw files by extension (.bin/.rbf/.hex): the FIT image
# goes in under a .bin name, as Intel's GSRD does
UBOOT_BIN="${JIC%.jic}_u-boot.bin"
cp "${UBOOT_ITB}" "${UBOOT_BIN}"
CORE_RAW="" CORE_PART="" CORE_ASSIGN=""
if (( HPS_FIRST )); then
    CORE_BIN="${JIC%.jic}_core.bin"
    core_size=$(stat -c %s "${CORE_RBF}")
    (( QSPI_CORE_OFFS >= QSPI_UBOOT_OFFS + uboot_size && \
       QSPI_CORE_OFFS + 0x1000 + core_size <= 0x1000000 )) || {
        echo "QSPI_CORE_OFFS ${QSPI_CORE_OFFS} does not fit the core (${core_size} bytes) after U-Boot"; exit 1; }
    python3 - "${CORE_RBF}" "${CORE_BIN}" << 'PYCORE'
import sys
core = open(sys.argv[1], "rb").read()
head = ("core_size=%#x\n" % len(core)).encode().ljust(0x1000, b"\0")
open(sys.argv[2], "wb").write(head + core)
PYCORE
    CORE_RAW="        <raw_file bitswap=\"1\" type=\"RBF\" id=\"Raw_File_2\">${CORE_BIN}</raw_file>"
    CORE_PART="            <partition reserved=\"0\" fixed_s_addr=\"0\" s_addr=\"${QSPI_CORE_OFFS}\" e_addr=\"auto\" fixed_e_addr=\"0\" id=\"CORE\" size=\"0\"/>"
    CORE_ASSIGN="        <assignment page=\"0\" partition_id=\"CORE\">
            <raw_file_id>Raw_File_2</raw_file_id>
        </assignment>"
    echo ">> QSPI core copy at ${QSPI_CORE_OFFS} (header + ${core_size} bytes)"
fi
# after Intel's Agilex 5 GSRD (software/yocto_linux/scripts/uboot_only.pfg)
cat > "${PFG}" << PFGEOF
<pfg version="1">
    <settings custom_db_dir="./" mode="ASX4"/>
    <output_files>
        <output_file name="${NAME}" directory="$(dirname "${JIC}")" type="JIC">
            <file_options/>
            <secondary_file type="MAP" name="${NAME}">
                <file_options/>
            </secondary_file>
            <flash_device_id>Flash_Device_1</flash_device_id>
        </output_file>
    </output_files>
    <bitstreams>
        <bitstream id="Bitstream_1">
            <path hps_path="${SPL}">${SOF}</path>
        </bitstream>
    </bitstreams>
    <raw_files>
        <raw_file bitswap="1" type="RBF" id="Raw_File_1">${UBOOT_BIN}</raw_file>
${CORE_RAW}
    </raw_files>
    <flash_devices>
        <flash_loader>${FLASH_LOADER}</flash_loader>
        <flash_device type="${DEVICE}" id="Flash_Device_1">
            <partition reserved="1" fixed_s_addr="1" s_addr="0x00000000" e_addr="0x001FFFFF" fixed_e_addr="1" id="BOOT_INFO" size="0"/>
            <partition reserved="0" fixed_s_addr="0" s_addr="auto" e_addr="auto" fixed_e_addr="0" id="P1" size="0"/>
            <partition reserved="0" fixed_s_addr="0" s_addr="${QSPI_UBOOT_OFFS}" e_addr="auto" fixed_e_addr="0" id="UBOOT" size="0"/>
${CORE_PART}
        </flash_device>
    </flash_devices>
    <assignments>
        <assignment page="0" partition_id="P1">
            <bitstream_id>Bitstream_1</bitstream_id>
        </assignment>
        <assignment page="0" partition_id="UBOOT">
            <raw_file_id>Raw_File_1</raw_file_id>
        </assignment>
${CORE_ASSIGN}
    </assignments>
</pfg>
PFGEOF
quartus_pfg -c "${PFG}"

echo
echo "wrote ${JIC} (flash map: ${JIC%.jic}.map)"
echo
echo "program it (board on JTAG; on WSL2 attach the USB-Blaster first, see"
echo "tools/program.sh; name the cable as jtagconfig lists it):"
echo "    quartus_pgm -c \"<cable>\" -m jtag -o \"pvi;${JIC}\""
echo "then power-cycle (MSEL SW10 = 001, AS fast / QSPI)."
