------------------------------------------------------------------------
-- hex_display - the DE25-Standard's six 7-segment displays HEX0..HEX5.
--
-- Registers (register_block.vhd):
--   21 value     24 bits, a hex digit per display, HEX0 = bits 3:0
--   22 control   bit 0 raw mode, bit 1 flip, bits 13:8 blank mask (bit 8 + n
--                blanks HEXn)
--   23/24 raw    segments when raw mode is set: HEXn in byte n (23: HEX3..0,
--                24: HEX5..4), bits 6:0 = segments g..a, 1 = lit
--   25/26        the segments driven now, same layout (read only) - what the
--                web GUI draws
--
-- Flip: the six displays read from the other side of the board, turned by
-- 180 degrees - what would be on HEXn goes to HEX(5-n), each digit upside
-- down (segments a<->d, b<->e, c<->f, g stays). Blank and raw are applied
-- first, so they name the digit as read; 25/26 show the segments driven.
--
-- Segment n of a display is HEXk[n]: 0 a (top), 1 b, 2 c, 3 d, 4 e, 5 f,
-- 6 g (middle). The displays are common anode: a pin driven low lights its
-- segment (Terasic DE25-Standard user manual), so the pins carry `not lit`.
-- Reset value: all digits 0, nothing blanked, so a configured fabric shows
-- "000000".
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity hex_display is
    port(
        clock : in std_logic;
        reset : in std_logic;

        value    : in  std_logic_vector(23 downto 0);
        raw_mode : in  std_logic;
        flip     : in  std_logic := '0';
        blank    : in  std_logic_vector(5 downto 0);
        raw      : in  std_logic_vector(47 downto 0);   -- HEXn in bits 8n+6..8n

        lit  : out std_logic_vector(47 downto 0);       -- same layout, 1 = lit
        HEX0 : out std_logic_vector(6 downto 0);
        HEX1 : out std_logic_vector(6 downto 0);
        HEX2 : out std_logic_vector(6 downto 0);
        HEX3 : out std_logic_vector(6 downto 0);
        HEX4 : out std_logic_vector(6 downto 0);
        HEX5 : out std_logic_vector(6 downto 0)
    );
end entity hex_display;

architecture rtl of hex_display is

    -- segments g..a, 1 = lit
    type decode_t is array (0 to 15) of std_logic_vector(6 downto 0);
    constant c_decode : decode_t := (
        "0111111", "0000110", "1011011", "1001111",   -- 0 1 2 3
        "1100110", "1101101", "1111101", "0000111",   -- 4 5 6 7
        "1111111", "1101111", "1110111", "1111100",   -- 8 9 A b
        "0111001", "1011110", "1111001", "1110001");  -- C d E F

    signal segments : std_logic_vector(47 downto 0) := (others => '0');

    -- a digit turned by 180 degrees: g f e d c b a -> g c b a f e d
    function rotated(s : std_logic_vector(6 downto 0)) return std_logic_vector is
    begin
        return s(6) & s(2) & s(1) & s(0) & s(5) & s(4) & s(3);
    end function;

begin

    drive : process(clock)
        variable s : std_logic_vector(6 downto 0);
    begin
        if rising_edge(clock) then
            for n in 0 to 5 loop
                if blank(n) = '1' then
                    s := (others => '0');
                elsif raw_mode = '1' then
                    s := raw(8 * n + 6 downto 8 * n);
                else
                    s := c_decode(to_integer(unsigned(value(4 * n + 3 downto 4 * n))));
                end if;
                if flip = '1' then
                    segments(8 * (5 - n) + 7 downto 8 * (5 - n)) <= '0' & rotated(s);
                else
                    segments(8 * n + 7 downto 8 * n) <= '0' & s;
                end if;
            end loop;
            if reset = '1' then
                for n in 0 to 5 loop
                    segments(8 * n + 7 downto 8 * n) <= '0' & c_decode(0);
                end loop;
            end if;
        end if;
    end process;

    lit  <= segments;
    HEX0 <= not segments(6 downto 0);
    HEX1 <= not segments(14 downto 8);
    HEX2 <= not segments(22 downto 16);
    HEX3 <= not segments(30 downto 24);
    HEX4 <= not segments(38 downto 32);
    HEX5 <= not segments(46 downto 40);

end architecture rtl;
