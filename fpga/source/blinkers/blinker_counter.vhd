------------------------------------------------------------------------
-- blinker_counter - a binary count on the LEDs, 4 a second (two counts in
-- every 25 frames). Ports: blinker_pkg.
-- Ported from the DE25-Nano (~/dev/pr_testing hw/blinkers/), BLINKER_LEDS wide.
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

    use work.blinker_pkg.all;

entity blinker_counter is
    port(
        clock  : in  std_logic;
        reset  : in  std_logic;
        frame  : in  std_logic;
        levels : out std_logic_vector(8 * BLINKER_LEDS - 1 downto 0);
        id     : out std_logic_vector(31 downto 0)
    );
end entity blinker_counter;

architecture rtl of blinker_counter is
    signal count  : unsigned(BLINKER_LEDS - 1 downto 0) := (others => '0');
    signal frames : natural range 0 to 24 := 0;
    signal level  : level_array_t := (others => (others => '0'));
begin
    id     <= BLINKER_ID_COUNTER;
    levels <= pack(level);

    process(clock)
    begin
        if rising_edge(clock) then
            if frame = '1' then
                if frames = 24 then
                    frames <= 0;
                else
                    frames <= frames + 1;
                end if;
                if frames = 0 or frames = 12 then
                    count <= count + 1;
                end if;
                for i in 0 to BLINKER_LEDS - 1 loop
                    level(i) <= (others => count(i));
                end loop;
            end if;
            if reset = '1' then
                count  <= (others => '0');
                frames <= 0;
                level  <= (others => (others => '0'));
            end if;
        end if;
    end process;
end architecture rtl;
