------------------------------------------------------------------------
-- blinker_sparkle - random flashes: each frame a 1 in 4 chance, times
-- BLINKER_LEDS/16 for the 4-bit pick, of a random LED going to full
-- brightness; all fade to 7/8 each frame. A 16-bit LFSR
-- (x^16 + x^14 + x^13 + x^11 + 1) stepping every clock. Ports: blinker_pkg.
-- Ported from the DE25-Nano (~/dev/pr_testing hw/blinkers/); picks among
-- BLINKER_LEDS LEDs.
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

    use work.blinker_pkg.all;

entity blinker_sparkle is
    port(
        clock  : in  std_logic;
        reset  : in  std_logic;
        frame  : in  std_logic;
        levels : out std_logic_vector(8 * BLINKER_LEDS - 1 downto 0);
        id     : out std_logic_vector(31 downto 0)
    );
end entity blinker_sparkle;

architecture rtl of blinker_sparkle is
    signal lfsr  : std_logic_vector(15 downto 0) := x"ACE1";
    signal level : level_array_t := (others => (others => '0'));
begin
    id     <= BLINKER_ID_SPARKLE;
    levels <= pack(level);

    process(clock)
        variable pick : natural range 0 to BLINKER_LEDS - 1;
    begin
        if rising_edge(clock) then
            lfsr <= lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
            if frame = '1' then
                for i in 0 to BLINKER_LEDS - 1 loop
                    level(i) <= fade(level(i), 3);
                end loop;
                if lfsr(1 downto 0) = "00" and to_integer(unsigned(lfsr(7 downto 4))) < BLINKER_LEDS then
                    pick := to_integer(unsigned(lfsr(7 downto 4)));
                    level(pick) <= (others => '1');
                end if;
            end if;
            if reset = '1' then
                lfsr  <= x"ACE1";
                level <= (others => (others => '0'));
            end if;
        end if;
    end process;
end architecture rtl;
