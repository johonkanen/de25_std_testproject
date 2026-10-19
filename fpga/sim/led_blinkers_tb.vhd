------------------------------------------------------------------------
-- led_blinkers_tb - the patterns at a small clock frequency (a frame is
-- 1000 clocks): software pass-through, the scanner's sweep, the counter,
-- PWM duty following the brightness, sparkle flashing, off.
--
-- Ported from the DE25-Nano (from ~/dev/pr_testing hw/sim/), for the ten
-- LEDs of the DE25-Standard (BLINKER_LEDS). Run it with
--   ./build.sh sim     (or python3 fpga/vunit_run_de25_std_test.py de25_std_lib.led_blinkers_tb.all -v)
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library vunit_lib;
    context vunit_lib.vunit_context;

    use work.blinker_pkg.all;

entity led_blinkers_tb is
    generic (runner_cfg : string);
end entity led_blinkers_tb;

architecture sim of led_blinkers_tb is
    constant clock_hz : positive := 50000;   -- frame 1000 clocks, PWM step 1 clock
    signal clock : std_logic := '0';
    signal reset : std_logic := '1';
    signal mode : unsigned(2 downto 0) := "000";
    constant n : natural := BLINKER_LEDS;
    signal sw_leds, leds : std_logic_vector(n - 1 downto 0);
    signal levels : std_logic_vector(8 * n - 1 downto 0);
    signal id : std_logic_vector(31 downto 0);

    function level(l : std_logic_vector(8 * n - 1 downto 0); i : natural) return natural is
    begin
        return to_integer(unsigned(l(8 * i + 7 downto 8 * i)));
    end function;

    -- the LED with the highest brightness
    function brightest(l : std_logic_vector(8 * n - 1 downto 0)) return natural is
        variable best : natural := 0;
    begin
        for i in 1 to n - 1 loop
            if level(l, i) > level(l, best) then
                best := i;
            end if;
        end loop;
        return best;
    end function;
begin
    test_runner_watchdog(runner, 100 ms);

    clock <= not clock after 5 ns;

    dut : entity work.led_blinkers
        generic map(g_clock_hz => clock_hz)
        port map(clock => clock, reset => reset, mode => mode, sw_leds => sw_leds,
                 leds => leds, levels => levels, id => id);

    test : process
        procedure frames(n : natural) is
        begin
            for i in 1 to n * 1000 loop
                wait until rising_edge(clock);
            end loop;
        end procedure;
        variable heads : string(1 to 30);
        variable on_count : natural;
        variable c0, c1 : natural;
        variable flashes : natural;
    begin
        test_runner_setup(runner, runner_cfg);
        sw_leds <= "1010100101";
        wait for 100 ns; wait until rising_edge(clock); reset <= '0';

        -- software: straight through
        wait until rising_edge(clock); wait until rising_edge(clock);
        assert leds = "1010100101" report "software mode: leds " & to_hstring(leds) severity failure;

        -- scanner: the brightest LED steps every 3 frames 0..9..0
        mode <= to_unsigned(3, 3);
        frames(2);
        for k in 1 to 30 loop
            frames(3);
            heads(k) := character'val(character'pos('0') + brightest(levels));
        end loop;
        report "scanner heads: " & heads;
        assert id = x"4253434E" report "scanner id " & to_hstring(id) severity failure;
        assert heads(1 to 18) = "123456789876543210" or heads(1 to 18) = "234567898765432101"
            or heads(1 to 18) = "345678987654321012"
            report "scanner sweep wrong" severity failure;

        -- counter: 4 a second = 2 every 25 frames
        -- (two frames: the first counter frame may land in the last clock)
        mode <= to_unsigned(2, 3);
        frames(2);
        c0 := 0;
        for i in 0 to n - 1 loop
            if level(levels, i) = 255 then c0 := c0 + 2 ** i; end if;
        end loop;
        frames(25);
        c1 := 0;
        for i in 0 to n - 1 loop
            if level(levels, i) = 255 then c1 := c1 + 2 ** i; end if;
        end loop;
        report "counter " & integer'image(c0) & " -> " & integer'image(c1) & " in 25 frames";
        assert (c1 - c0) mod 2 ** n = 2 severity failure;

        -- breathing: a breath (150 frames) reaches 255 and 0; PWM duty of
        -- LED 0 matches a mid brightness (256 steps)
        mode <= to_unsigned(4, 3);
        c0 := 255; c1 := 0;
        for k in 1 to 160 loop
            frames(1);
            c0 := minimum(c0, level(levels, 0));
            c1 := maximum(c1, level(levels, 0));
        end loop;
        report "breathing: brightness " & integer'image(c0) & " .. " & integer'image(c1);
        assert c0 = 0 and c1 >= 250 report "breathing range" severity failure;
        for k in 1 to 160 loop
            frames(1);
            exit when level(levels, 0) >= 100 and level(levels, 0) <= 200;
        end loop;
        wait until rising_edge(clock); wait until rising_edge(clock);
        c0 := level(levels, 0);
        on_count := 0;
        for i in 1 to 256 loop
            wait until rising_edge(clock);
            if leds(0) = '1' then on_count := on_count + 1; end if;
        end loop;
        report "breathing: level " & integer'image(c0) & ", on " & integer'image(on_count) & "/256";
        assert abs (on_count - c0) <= 8 severity failure;

        -- sparkle: some flashes in 40 frames
        mode <= to_unsigned(5, 3);
        flashes := 0;
        for k in 1 to 40 loop
            frames(1);
            for i in 0 to n - 1 loop
                if level(levels, i) = 255 then flashes := flashes + 1; end if;
            end loop;
        end loop;
        report "sparkle: " & integer'image(flashes) & " flashes in 40 frames";
        assert flashes >= 3 and flashes <= 30 severity failure;

        -- sparkle's fades reach 0: some LED is fully dark within 40 frames
        flashes := 0;
        for i in 0 to n - 1 loop
            if level(levels, i) = 0 then flashes := flashes + 1; end if;
        end loop;
        report "sparkle: " & integer'image(flashes) & " LEDs dark";
        assert flashes > 0 report "fades do not reach 0" severity failure;

        -- off
        mode <= to_unsigned(1, 3);
        frames(2);
        assert levels = (levels'range => '0') and leds = (leds'range => '0') severity failure;
        assert id = x"00000000" report "off: id " & to_hstring(id) severity failure;
        -- software again: id back to 0
        mode <= to_unsigned(0, 3);
        frames(1);
        assert leds = "1010100101" and id = x"00000000" report "back to software" severity failure;
        report "PASS";
        test_runner_cleanup(runner);
    end process;
end architecture sim;
