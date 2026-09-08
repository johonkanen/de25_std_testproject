# Refresh git_hash_pkg.vhd with the current short commit hash (8 hex digits).
if (-not (git rev-parse --is-inside-work-tree -q)) {
    Write-Host "This directory is not a Git repository."
    exit
}

$gitHash = git rev-parse --short HEAD
$gitHashPadded = $gitHash.PadLeft(8, '0')

$outputFile = "git_hash_pkg.vhd"

$vhdlContent = @"
library ieee;
    use ieee.std_logic_1164.all;

package git_hash_pkg is

    constant git_hash : std_logic_vector(31 downto 0) := x"$gitHashPadded";
end package;
"@

$vhdlContent | Out-File -FilePath $outputFile -Encoding utf8

Write-Host "The Git hash has been written to $outputFile"
