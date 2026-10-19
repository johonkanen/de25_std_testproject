#!/usr/bin/env bash
# Combine the FPGA bitstream, the U-Boot SPL and U-Boot proper into a QSPI
# flash image (.jic) for the DE25-Standard. Run ./build.sh fpga and
# ./build.sh linux first (or just ./build.sh all).
#
#   ./build.sh jic      (or linux/make_jic.sh)
#
# QSPI layout (16 MB MT25QU128), RSU=1 (the default for HPS-first; plan
# Phase F, after the DE25-Nano's docs/remote_system_update_plan.md):
#   0x000000  boot info + decision firmware (to 0x20FFFF)
#   0x220000  FACTORY_IMAGE: phase 1 (HPS I/O, DDR I/O) + SPL, 1 MB
#   0x320000  SPT0, SPT1, CPB0, CPB1 (32 KB each): slot and priority tables
#   0x400000  P1: application image, 1 MB (the same build at first)
#   0x500000  SSBL.FACTORY_IM, 0x600000 SSBL.P1: each image's u-boot.itb
#             (the SPL's RSU multiboot loads the one of the image running)
#   0xA00000  u-boot.itb (UBOOT: for SPLs without RSU multiboot)
#   0xC00000  CORE.FACTORY_IM, 0xD10000 CORE.P1: each image's FPGA core
#             behind a 4 KB "core_size=0x..." header (U-Boot's preboot, via
#             `rsu running_slot`, loads it when the card has none)
# RSU=0 (the default for FPGA-first, whose ~3 MB bitstream does not fit a
# 1 MB slot): the plain layout -
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
# "HPS FIRST" unless FPGA_FIRST=1 ("AFTER INIT_DONE").
#
# Env overrides: BUILD_DIR=, SOF=, SPL=, UBOOT_ITB=, JIC=, CORE_RBF=,
# QSPI_UBOOT_OFFS=, QSPI_CORE_OFFS= (both must match the U-Boot build),
# RSU=0/1, FACTORY_SOF= (another build in the factory slot; default the
# same .sof as P1).
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
RSU="${RSU:-${HPS_FIRST}}"
if (( RSU )) && ! (( HPS_FIRST )); then
    echo "RSU=1 needs an HPS-first .sof (an FPGA-first bitstream does not fit a 1 MB slot)"; exit 1
fi
if (( RSU )); then
    # remote system update layout (plan F1): the SDM boots the
    # highest-priority application slot that loads (P1), else the factory
    # image; the SPT/CPB tables say where they are. The decision firmware
    # makes BOOT_INFO 0x210000 long. Fixed addresses throughout - with
    # "auto" quartus_pfg 26.1.1 fails (internal error, DE25-Nano). P1 holds
    # the same build as the factory image until an update writes it.
    BITSTREAMS="        <bitstream id=\"Factory\">
            <path hps_path=\"${SPL}\">${FACTORY_SOF:-${SOF}}</path>
        </bitstream>
        <bitstream id=\"App1\">
            <path hps_path=\"${SPL}\">${SOF}</path>
        </bitstream>"
    part() { printf '            <partition reserved="%s" fixed_s_addr="1" s_addr="%#010x" e_addr="%#010x" fixed_e_addr="1" id="%s" size="0"/>\n' "$4" "$2" "$3" "$1"; }
    (( uboot_size <= 0x100000 )) || { echo "u-boot.itb (${uboot_size} bytes) does not fit a 1 MB SSBL slot"; exit 1; }
    (( 0x1000 + core_size <= 0x110000 )) || { echo "the core (${core_size} bytes) does not fit a CORE slot"; exit 1; }
    PARTS="$(part BOOT_INFO 0x000000 0x20FFFF 1
             part FACTORY_IMAGE 0x220000 0x31FFFF 0
             part SPT0 0x320000 0x327FFF 1
             part SPT1 0x328000 0x32FFFF 1
             part CPB0 0x330000 0x337FFF 1
             part CPB1 0x338000 0x33FFFF 1
             part P1 0x400000 0x4FFFFF 0
             part SSBL.FACTORY_IM 0x500000 0x5FFFFF 0
             part SSBL.P1 0x600000 0x6FFFFF 0
             part UBOOT $(( QSPI_UBOOT_OFFS )) $(( QSPI_UBOOT_OFFS + 0xFFFFF )) 0
             part CORE.FACTORY_IM $(( QSPI_CORE_OFFS )) $(( QSPI_CORE_OFFS + 0x10FFFF )) 0
             part CORE.P1 $(( QSPI_CORE_OFFS + 0x110000 )) $(( QSPI_CORE_OFFS + 0x21FFFF )) 0)"
    # a core per image (F3b): U-Boot's preboot loads CORE.<image>; the
    # factory image's sits where U-Boots without `rsu running_slot` look
    # (QSPI_CORE_OFFS). Both hold this build's.
    CORE_PART=""
    CORE_ASSIGN="        <assignment page=\"0\" partition_id=\"CORE.FACTORY_IM\">
            <raw_file_id>Raw_File_2</raw_file_id>
        </assignment>
        <assignment page=\"0\" partition_id=\"CORE.P1\">
            <raw_file_id>Raw_File_2</raw_file_id>
        </assignment>"
    IMAGE_ASSIGN="        <assignment page=\"0\" partition_id=\"FACTORY_IMAGE\">
            <bitstream_id>Factory</bitstream_id>
        </assignment>
        <assignment page=\"1\" partition_id=\"P1\">
            <bitstream_id>App1</bitstream_id>
        </assignment>
        <assignment page=\"0\" partition_id=\"SSBL.FACTORY_IM\">
            <raw_file_id>Raw_File_1</raw_file_id>
        </assignment>
        <assignment page=\"0\" partition_id=\"SSBL.P1\">
            <raw_file_id>Raw_File_1</raw_file_id>
        </assignment>"
    echo ">> RSU layout: factory image 0x220000, P1 0x400000, SPT/CPB 0x320000,"
    echo "   their U-Boots SSBL.FACTORY_IM 0x500000, SSBL.P1 0x600000,"
    echo "   their cores CORE.FACTORY_IM ${QSPI_CORE_OFFS}, CORE.P1 $(printf '%#x' $(( QSPI_CORE_OFFS + 0x110000 )))"
else
    BITSTREAMS="        <bitstream id=\"Bitstream_1\">
            <path hps_path=\"${SPL}\">${SOF}</path>
        </bitstream>"
    PARTS="            <partition reserved=\"1\" fixed_s_addr=\"1\" s_addr=\"0x00000000\" e_addr=\"0x001FFFFF\" fixed_e_addr=\"1\" id=\"BOOT_INFO\" size=\"0\"/>
            <partition reserved=\"0\" fixed_s_addr=\"0\" s_addr=\"auto\" e_addr=\"auto\" fixed_e_addr=\"0\" id=\"P1\" size=\"0\"/>
            <partition reserved=\"0\" fixed_s_addr=\"0\" s_addr=\"${QSPI_UBOOT_OFFS}\" e_addr=\"auto\" fixed_e_addr=\"0\" id=\"UBOOT\" size=\"0\"/>"
    IMAGE_ASSIGN="        <assignment page=\"0\" partition_id=\"P1\">
            <bitstream_id>Bitstream_1</bitstream_id>
        </assignment>"
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
${BITSTREAMS}
    </bitstreams>
    <raw_files>
        <raw_file bitswap="1" type="RBF" id="Raw_File_1">${UBOOT_BIN}</raw_file>
${CORE_RAW}
    </raw_files>
    <flash_devices>
        <flash_loader>${FLASH_LOADER}</flash_loader>
        <flash_device type="${DEVICE}" id="Flash_Device_1">
${PARTS}
${CORE_PART}
        </flash_device>
    </flash_devices>
    <assignments>
${IMAGE_ASSIGN}
        <assignment page="0" partition_id="UBOOT">
            <raw_file_id>Raw_File_1</raw_file_id>
        </assignment>
${CORE_ASSIGN}
    </assignments>
</pfg>
PFGEOF
quartus_pfg -c "${PFG}"
if (( RSU )); then
    # the same image as an RSU application image for an update over the
    # network (F3): start address 0, bitswapped - librsu relocates it into
    # the slot (it differs from the P1 copy in the .jic by two pointers and
    # a block CRC). linux/tools/make_rsu_bundle.py packs it with its U-Boot
    # and core.
    APP_RPD="${JIC%.jic}_app.rpd"
    quartus_pfg -c "${SOF}" "${APP_RPD}" -o hps_path="${SPL}" -o mode=ASX4 \
        -o start_address=0x00 -o bitswap=ON > "${JIC%.jic}_app.log" 2>&1 || {
        echo "quartus_pfg failed on the application image, see ${JIC%.jic}_app.log"; exit 1; }
    echo ">> RSU application image ${APP_RPD} ($(stat -c %s "${APP_RPD}") bytes)"
fi

echo
echo "wrote ${JIC} (flash map: ${JIC%.jic}.map)"
echo
echo "program it (board on JTAG; on WSL2 attach the USB-Blaster first, see"
echo "tools/program.sh; name the cable as jtagconfig lists it):"
echo "    quartus_pgm -c \"<cable>\" -m jtag -o \"pvi;${JIC}\""
echo "then power-cycle (MSEL SW10 = 001, AS fast / QSPI)."
