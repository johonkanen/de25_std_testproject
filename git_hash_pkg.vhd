library ieee;
    use ieee.std_logic_1164.all;

package git_hash_pkg is

    -- placeholder - run ./write_githash.sh to stamp the real commit hash
    constant git_hash : std_logic_vector(31 downto 0) := x"00000000";
end package;
