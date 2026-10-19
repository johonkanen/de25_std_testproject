------------------------------------------------------------------------
-- blinker_slot - where the blinker modules plug into the static design.
--
-- Now: all four modules side by side, the one for the mode selected
-- (2 counter, 3 scanner, 4 breathing, 5 sparkle; levels and id 0 for any
-- other mode). Later this boundary becomes one partial reconfiguration
-- region holding one module at a time - the same ports less sel; Linux
-- chooses a blinker by loading its persona and reads back which module is
-- there from id (docs/partial_reconfiguration_plan.md).
--
-- Ported from ~/dev/pr_testing (hw/blinkers/blinker_slot.vhd).
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

    use work.blinker_pkg.all;

entity blinker_slot is
    port(
        clock  : in  std_logic;
        reset  : in  std_logic;
        frame  : in  std_logic;
        sel    : in  unsigned(2 downto 0);
        levels : out std_logic_vector(8 * BLINKER_LEDS - 1 downto 0);
        id     : out std_logic_vector(31 downto 0)
    );
end entity blinker_slot;

architecture all_modules of blinker_slot is

    type levels_array_t is array (2 to 5) of std_logic_vector(8 * BLINKER_LEDS - 1 downto 0);
    type id_array_t is array (2 to 5) of std_logic_vector(31 downto 0);

    signal module_levels : levels_array_t;
    signal module_id     : id_array_t;

begin

    u_counter : entity work.blinker_counter
        port map(clock => clock, reset => reset, frame => frame,
                 levels => module_levels(2), id => module_id(2));

    u_scanner : entity work.blinker_scanner
        port map(clock => clock, reset => reset, frame => frame,
                 levels => module_levels(3), id => module_id(3));

    u_breathing : entity work.blinker_breathing
        port map(clock => clock, reset => reset, frame => frame,
                 levels => module_levels(4), id => module_id(4));

    u_sparkle : entity work.blinker_sparkle
        port map(clock => clock, reset => reset, frame => frame,
                 levels => module_levels(5), id => module_id(5));

    select_module : process(clock)
    begin
        if rising_edge(clock) then
            case to_integer(sel) is
                when 2 to 5 =>
                    levels <= module_levels(to_integer(sel));
                    id     <= module_id(to_integer(sel));
                when others =>
                    levels <= (others => '0');
                    id     <= (others => '0');
            end case;
        end if;
    end process;

end architecture all_modules;
