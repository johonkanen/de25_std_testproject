------------------------------------------------------------------------
-- blinker_scanner - a light sweeping 0..BLINKER_LEDS-1..0 (0..9..0), a step every 3 frames (60 ms);
-- the other LEDs fade to 3/4 each frame, a trail. Ports: blinker_pkg.
-- Ported from the DE25-Nano (~/dev/pr_testing hw/blinkers/).
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

    use work.blinker_pkg.all;

entity blinker_scanner is
    port(
        clock  : in  std_logic;
        reset  : in  std_logic;
        frame  : in  std_logic;
        levels : out std_logic_vector(8 * BLINKER_LEDS - 1 downto 0);
        id     : out std_logic_vector(31 downto 0)
    );
end entity blinker_scanner;

architecture rtl of blinker_scanner is
    signal head  : natural range 0 to BLINKER_LEDS - 1 := 0;
    signal down  : std_logic := '0';
    signal step  : natural range 0 to 2 := 0;
    signal level : level_array_t := (others => (others => '0'));
begin
    id     <= BLINKER_ID_SCANNER;
    levels <= pack(level);

    process(clock)
    begin
        if rising_edge(clock) then
            if frame = '1' then
                for i in 0 to BLINKER_LEDS - 1 loop
                    level(i) <= fade(level(i), 2);
                end loop;
                level(head) <= (others => '1');
                if step = 2 then
                    step <= 0;
                    if down = '0' then
                        if head = BLINKER_LEDS - 1 then
                            down <= '1';
                            head <= head - 1;
                        else
                            head <= head + 1;
                        end if;
                    else
                        if head = 0 then
                            down <= '0';
                            head <= 1;
                        else
                            head <= head - 1;
                        end if;
                    end if;
                else
                    step <= step + 1;
                end if;
            end if;
            if reset = '1' then
                head  <= 0;
                down  <= '0';
                step  <= 0;
                level <= (others => (others => '0'));
            end if;
        end if;
    end process;
end architecture rtl;
