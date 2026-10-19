------------------------------------------------------------------------
-- hex_display_tb - the 7-segment driver: "000000" after reset, hex digit
-- decode for all 16 values, the blank mask, raw mode, the flip (read from
-- the other side) and the common-anode pins (low = lit). Run it with
--   ./build.sh sim     (or python3 fpga/vunit_run_de25_std_test.py de25_std_lib.hex_display_tb.all -v)
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library vunit_lib;
    context vunit_lib.vunit_context;

entity hex_display_tb is
    generic (runner_cfg : string);
end entity hex_display_tb;

architecture sim of hex_display_tb is
    signal clock    : std_logic := '0';
    signal reset    : std_logic := '1';
    signal value    : std_logic_vector(23 downto 0) := (others => '0');
    signal raw_mode : std_logic := '0';
    signal flip     : std_logic := '0';
    signal blank    : std_logic_vector(5 downto 0) := (others => '0');
    signal raw      : std_logic_vector(47 downto 0) := (others => '0');
    signal lit      : std_logic_vector(47 downto 0);
    signal HEX0, HEX1, HEX2, HEX3, HEX4, HEX5 : std_logic_vector(6 downto 0);

    -- segments g..a of each hex digit, 1 = lit (written out independently
    -- of the driver's table)
    type digits_t is array (0 to 15) of std_logic_vector(6 downto 0);
    constant expected : digits_t := (
        "0111111", "0000110", "1011011", "1001111", "1100110", "1101101", "1111101", "0000111",
        "1111111", "1101111", "1110111", "1111100", "0111001", "1011110", "1111001", "1110001");

    function digit(l : std_logic_vector(47 downto 0); n : natural) return std_logic_vector is
    begin
        return l(8 * n + 6 downto 8 * n);
    end function;
begin
    test_runner_watchdog(runner, 1 ms);
    clock <= not clock after 5 ns;

    dut : entity work.hex_display
        port map(clock => clock, reset => reset, value => value, raw_mode => raw_mode, flip => flip,
                 blank => blank, raw => raw, lit => lit,
                 HEX0 => HEX0, HEX1 => HEX1, HEX2 => HEX2, HEX3 => HEX3, HEX4 => HEX4, HEX5 => HEX5);

    test : process
        procedure settle is
        begin
            wait until rising_edge(clock); wait until rising_edge(clock); wait for 1 ns;
        end procedure;
    begin
        test_runner_setup(runner, runner_cfg);
        settle;
        -- in reset: "000000"
        for n in 0 to 5 loop
            assert digit(lit, n) = expected(0) report "reset: HEX" & integer'image(n) severity failure;
        end loop;
        reset <= '0';

        -- every digit value on every display
        for v in 0 to 15 loop
            value <= std_logic_vector(to_unsigned(v * 16#111111#, 24));
            settle;
            for n in 0 to 5 loop
                assert digit(lit, n) = expected(v)
                    report "value " & integer'image(v) & " HEX" & integer'image(n) & ": " & to_string(digit(lit, n))
                    severity failure;
            end loop;
        end loop;

        -- positions: HEX0 is the low nibble
        value <= x"123456";
        settle;
        assert digit(lit, 0) = expected(6) and digit(lit, 5) = expected(1) report "digit order" severity failure;
        -- the pins are the inverse (common anode)
        assert HEX0 = not expected(6) and HEX5 = not expected(1) and HEX3 = not expected(3)
            report "pins not inverted" severity failure;

        -- blank HEX5 and HEX1
        blank <= "100010";
        settle;
        assert digit(lit, 5) = "0000000" and digit(lit, 1) = "0000000" and HEX5 = "1111111"
            report "blank" severity failure;
        assert digit(lit, 0) = expected(6) report "blank touched HEX0" severity failure;
        blank <= (others => '0');

        -- raw mode: the bytes as given (bit 7 ignored), blank still wins
        raw_mode <= '1';
        -- HEX5..HEX0; HEX5 has bit 7 set, HEX2 is all on but blanked
        raw <= x"C0" & x"01" & x"7F" & x"7F" & x"55" & x"2A";
        blank <= "000100";
        settle;
        assert digit(lit, 0) = "0101010" and digit(lit, 1) = "1010101" and digit(lit, 2) = "0000000"
            and digit(lit, 3) = "1111111" and digit(lit, 4) = "0000001" and digit(lit, 5) = "1000000"
            report "raw: " & to_hstring(lit) severity failure;
        assert lit(7) = '0' and lit(47) = '0' report "bit 7 must stay 0" severity failure;

        -- back to digits
        raw_mode <= '0'; blank <= (others => '0');
        settle;
        assert digit(lit, 4) = expected(2) report "back to digits" severity failure;

        -- flip: "123456" read from the other side - HEX0 shows the "1" turned
        -- (b, c lit -> e, f), HEX5 the "6" turned, the "2" (a b d e g) on HEX1
        -- becomes d e a b g: a "2" again
        value <= x"123456";
        flip <= '1';
        settle;
        assert digit(lit, 0) = "0110000" report "flip HEX0: " & to_string(digit(lit, 0)) severity failure;
        assert digit(lit, 1) = expected(2) report "flip HEX1" severity failure;
        -- a "6" turned is a "9"
        assert digit(lit, 5) = expected(9) report "flip HEX5: " & to_string(digit(lit, 5)) severity failure;
        -- blank names the digit as read: blank(0) clears the "6", now on HEX5
        blank <= "000001";
        settle;
        assert digit(lit, 5) = "0000000" and digit(lit, 0) = "0110000" report "flip + blank" severity failure;
        blank <= (others => '0'); flip <= '0';
        settle;
        assert digit(lit, 0) = expected(6) report "unflipped again" severity failure;

        -- reset again: "000000"
        reset <= '1';
        settle;
        assert digit(lit, 3) = expected(0) report "reset again" severity failure;
        report "PASS";
        test_runner_cleanup(runner);
    end process;
end architecture sim;
