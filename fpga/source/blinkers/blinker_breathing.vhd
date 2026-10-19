------------------------------------------------------------------------
-- blinker_breathing - all LEDs fading in and out, 3 s a breath (150 frames):
-- a triangle 0..255..0, squared for an even-looking fade. Ports: blinker_pkg.
-- Ported from the DE25-Nano (~/dev/pr_testing hw/blinkers/).
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

    use work.blinker_pkg.all;

entity blinker_breathing is
    port(
        clock  : in  std_logic;
        reset  : in  std_logic;
        frame  : in  std_logic;
        levels : out std_logic_vector(8 * BLINKER_LEDS - 1 downto 0);
        id     : out std_logic_vector(31 downto 0)
    );
end entity blinker_breathing;

architecture rtl of blinker_breathing is
    constant half : natural := 75;                     -- frames up, then down
    signal phase  : natural range 0 to 2 * half - 1 := 0;
    signal t      : unsigned(7 downto 0) := (others => '0');  -- the triangle
    signal square : std_logic := '0';                  -- t is new: square it
    signal level  : level_t := (others => '0');
begin
    id     <= BLINKER_ID_BREATHING;
    levels <= pack((others => level));

    -- two steps, a clock apart (a frame is 20 ms): the triangle, then its square
    process(clock)
        variable tri     : natural range 0 to half;
        variable scaled  : unsigned(19 downto 0);      -- tri * 255/75, Q10
        variable squared : unsigned(15 downto 0);
    begin
        if rising_edge(clock) then
            square <= '0';
            if frame = '1' then
                if phase = 2 * half - 1 then
                    phase <= 0;
                else
                    phase <= phase + 1;
                end if;
                if phase < half then
                    tri := phase;
                else
                    tri := 2 * half - phase;
                end if;
                -- 255/75 = 3.4 = 3482/1024
                scaled := shift_right(to_unsigned(tri, 8) * to_unsigned(3482, 12), 10);
                if scaled > 255 then
                    t <= to_unsigned(255, 8);
                else
                    t <= scaled(7 downto 0);
                end if;
                square <= '1';
            end if;
            if square = '1' then
                squared := t * t;
                level   <= squared(15 downto 8);
            end if;
            if reset = '1' then
                phase  <= 0;
                t      <= (others => '0');
                square <= '0';
                level  <= (others => '0');
            end if;
        end if;
    end process;
end architecture rtl;
