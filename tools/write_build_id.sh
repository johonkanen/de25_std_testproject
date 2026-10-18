#!/usr/bin/env bash
# Write build_id_pkg.vhd with a new build id, the Unix time now, into
# OUT_DIR (the Quartus build directory). The design shows it on register
# 19, so a running core says which build it is; build.sh runs this before
# every quartus_syn. linux/make_jic.sh copies the same number into the
# core's manifest (de25_std.core.json).
#   tools/write_build_id.sh OUT_DIR
set -euo pipefail
out="${1:?usage: $0 OUT_DIR}"

id=$(date +%s)

mkdir -p "$out"
cat > "$out/build_id_pkg.vhd" <<VHDL
library ieee;
    use ieee.std_logic_1164.all;

package build_id_pkg is

    -- $(date -u -d "@${id}" +%FT%TZ)
    constant build_id : std_logic_vector(31 downto 0) := x"$(printf %08x "${id}")";
end package;
VHDL

echo "build_id_pkg.vhd -> build id ${id} ($(printf %#010x "${id}"))"
