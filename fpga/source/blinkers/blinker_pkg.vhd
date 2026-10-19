------------------------------------------------------------------------
-- blinker_pkg - what the LED blinker modules have in common.
--
-- Ported from the DE25-Nano (~/dev/de25_nano_testproject, from
-- ~/dev/pr_testing hw/blinkers/); the LED count is BLINKER_LEDS (10 on the
-- DE25-Standard, LEDR[9:0]) instead of a fixed eight. Every blinker
-- (blinker_counter, blinker_scanner, blinker_breathing, blinker_sparkle)
-- has the same ports, so each can later become one persona of a single
-- partial reconfiguration region (docs/partial_reconfiguration_plan.md):
--
--   clock   in   the system clock (core_clock, 50 MHz)
--   reset   in   high: back to the start of the pattern (also after the
--                module has been loaded into the region)
--   frame   in   one clock high every 20 ms (50 Hz): the pattern's time
--                base, made in the static design (led_blinkers.vhd)
--   levels  out  LED n's brightness 0..255 in bits 8n+7..8n (8 *
--                BLINKER_LEDS bits), registered
--   id      out  the module's name, four ASCII characters (BLINKER_ID_*):
--                which module is shown
--
-- A module keeps all of its state (counters, random generator) to itself.
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

package blinker_pkg is

    constant BLINKER_LEDS : natural := 10;

    subtype level_t is unsigned(7 downto 0);
    type level_array_t is array (0 to BLINKER_LEDS - 1) of level_t;

    constant BLINKER_ID_COUNTER   : std_logic_vector(31 downto 0) := x"42434E54";  -- "BCNT"
    constant BLINKER_ID_SCANNER   : std_logic_vector(31 downto 0) := x"4253434E";  -- "BSCN"
    constant BLINKER_ID_BREATHING : std_logic_vector(31 downto 0) := x"42425254";  -- "BBRT"
    constant BLINKER_ID_SPARKLE   : std_logic_vector(31 downto 0) := x"4253504B";  -- "BSPK"

    -- l * (1 - 2^-shift), down to 0 (below 2^shift the subtraction alone
    -- would stop changing it: 3 stays 3 for 3/4)
    function fade(l : level_t; shift : natural) return level_t;

    -- the levels as the levels port carries them
    function pack(l : level_array_t) return std_logic_vector;

end package blinker_pkg;

package body blinker_pkg is

    function fade(l : level_t; shift : natural) return level_t is
    begin
        if l < 2 ** shift then
            return (others => '0');
        end if;
        return l - shift_right(l, shift);
    end function;

    function pack(l : level_array_t) return std_logic_vector is
        variable v : std_logic_vector(8 * BLINKER_LEDS - 1 downto 0);
    begin
        for i in 0 to BLINKER_LEDS - 1 loop
            v(8 * i + 7 downto 8 * i) := std_logic_vector(l(i));
        end loop;
        return v;
    end function;

end package body blinker_pkg;
