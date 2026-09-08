#!/usr/bin/env bash
# Refresh git_hash_pkg.vhd with the current short commit hash (8 hex digits).
set -euo pipefail
cd "$(dirname "$0")"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "not a git repository - leaving git_hash_pkg.vhd unchanged" >&2
    exit 0
fi

hash=$(git rev-parse --short=8 HEAD)

cat > git_hash_pkg.vhd <<EOF
library ieee;
    use ieee.std_logic_1164.all;

package git_hash_pkg is

    constant git_hash : std_logic_vector(31 downto 0) := x"${hash}";
end package;
EOF

echo "git_hash_pkg.vhd -> x\"${hash}\""
