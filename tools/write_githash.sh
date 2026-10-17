#!/usr/bin/env bash
# Write git_hash_pkg.vhd with the current short commit hash (8 hex digits)
# into OUT_DIR (the Quartus build directory). Outside a git checkout the
# hash is 0.
#   tools/write_githash.sh OUT_DIR
set -euo pipefail
out="${1:?usage: $0 OUT_DIR}"
repo="$(dirname "$0")/.."

if hash=$(git -C "$repo" rev-parse --short=8 HEAD 2>/dev/null); then
    :
else
    echo "not a git repository - git hash 0" >&2
    hash=00000000
fi

mkdir -p "$out"
cat > "$out/git_hash_pkg.vhd" <<EOT
library ieee;
    use ieee.std_logic_1164.all;

package git_hash_pkg is

    constant git_hash : std_logic_vector(31 downto 0) := x"${hash}";
end package;
EOT

echo "git_hash_pkg.vhd -> x\"${hash}\""
