------------------------------------------------------------------------
-- h2f_user0_clk_heartbeat - proves the HPS's dedicated free-running H2F
-- User0 clock (hps_subsystem's h2f_user0_clock, 50 MHz - see
-- hps/README.md's "H2F User0 clock" section) is actually toggling, by
-- dividing it down to a slow, human-visible blink on its own pin.
--
-- Deliberately isolated from uart_register_block.vhd / the LWH2F path:
-- runs entirely in this one clock domain, touches nothing else in the
-- design, and needs no CDC (there's nothing to cross to). Probe
-- GPIO_D[2] with a logic probe, LED+resistor, or scope to confirm - it
-- should toggle at ~50MHz / 2**26 =~ 0.75 Hz, the same divider ratio
-- uart_register_block.vhd's own CLOCK0_50 heartbeat uses, so a working
-- H2F User0 clock blinks at very close to the same rate as LEDR(9).
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity h2f_user0_clk_heartbeat is
    port (
        h2f_user0_clock : in  std_logic;   -- free-running, no associated reset
        heartbeat_out    : out std_logic
    );
end entity h2f_user0_clk_heartbeat;

architecture rtl of h2f_user0_clk_heartbeat is
    signal count     : unsigned(25 downto 0) := (others => '0');
    signal heartbeat : std_logic := '0';
begin
    process (h2f_user0_clock) is
    begin
        if rising_edge(h2f_user0_clock) then
            count <= count + 1;
            if count = 0 then
                heartbeat <= not heartbeat;
            end if;
        end if;
    end process;

    heartbeat_out <= heartbeat;
end architecture rtl;
