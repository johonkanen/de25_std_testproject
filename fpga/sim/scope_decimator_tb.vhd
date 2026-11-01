------------------------------------------------------------------------
-- scope_decimator_tb - points against a reference computed here
--
--   points_match      random samples, a sample every clock (50 MS/s), n = 100:
--                     each point's minimum, maximum and mean (rounded to
--                     nearest, halves away from zero) for signed and unsigned
--                     channels, AND / OR / last sample for digital ones; the
--                     fourth record: the point's number, none lost, n
--   rounding          means of -1.5, -0.5, 0.5, 2.5 round away from zero
--   smallest_n        n = 64 at a sample every clock: nothing lost
--   lost_whole        the writer out of room: points lost and counted, the
--                     records still in fours, each point's number and lost
--                     count saying which
--   passthrough       disabled: records straight through
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

    use work.fpga_interconnect_pkg.all;

entity scope_decimator_tb is
    generic (runner_cfg : string);
end;

architecture vunit_simulation of scope_decimator_tb is

    constant regs : natural := 304;

    signal clock : std_logic := '0';
    signal bus_in, bus_out : fpga_interconnect_record := init_fpga_interconnect;

    signal in_reset, in_write, in_flush : boolean := false;
    signal in_data : std_logic_vector(127 downto 0) := (others => '0');
    signal in_is_full : boolean;
    signal out_reset, out_write, out_flush : boolean;
    signal out_data : std_logic_vector(127 downto 0);
    signal almost_full : boolean := false;

    -- what came out: up to 4096 records
    type rec_array is array (0 to 4095) of std_logic_vector(127 downto 0);
    signal got : rec_array;
    signal got_n : natural := 0;

    signal bus_read_data : std_logic_vector(31 downto 0);
    signal bus_read_done : boolean := false;

    -- formats: ch0 signed, ch1 unsigned, ch2 digital, ch3..7 signed
    constant formats : std_logic_vector(31 downto 0) := x"00000024";

    function ch(r : std_logic_vector(127 downto 0); c : natural) return std_logic_vector is
    begin
        return r(127 - 16*c downto 112 - 16*c);
    end function;

begin

    clock <= not clock after 10 ns;

    dut : entity work.scope_decimator
        generic map (g_base_address => regs)
        port map (clock => clock, bus_in => bus_in, bus_out => bus_out,
                  in_reset => in_reset, in_write => in_write, in_data => in_data,
                  in_flush => in_flush, in_is_full => in_is_full,
                  out_reset => out_reset, out_write => out_write, out_data => out_data,
                  out_flush => out_flush, out_is_full => false, out_almost_full => almost_full);

    collect : process (clock)
    begin
        if rising_edge(clock) then
            if out_write and got_n < 4096 then
                got(got_n) <= out_data;
                got_n <= got_n + 1;
            end if;
            if in_reset then
                got_n <= 0;
            end if;
        end if;
    end process;

    capture_bus_reads : process (clock)
    begin
        if rising_edge(clock) then
            bus_read_done <= false;
            if write_to_address_is_requested(bus_out, 0) then
                bus_read_data <= bus_out.data;
                bus_read_done <= true;
            end if;
        end if;
    end process;

    main : process
        variable lfsr : unsigned(31 downto 0) := x"ACE11234";
        variable word : std_logic_vector(31 downto 0);
        type int_array is array (0 to 7) of integer;
        type slv_array is array (0 to 7) of std_logic_vector(15 downto 0);
        variable mn, mx, sm : int_array;
        variable an, orr, last : slv_array;
        variable v : integer;
        variable rec : std_logic_vector(127 downto 0);

        procedure bus_write(address : natural; data : std_logic_vector(31 downto 0)) is
        begin
            wait until rising_edge(clock);
            write_data_to_address(bus_in, address, data);
            wait until rising_edge(clock);
            init_bus(bus_in);
        end procedure;

        procedure bus_read(address : natural; data : out std_logic_vector(31 downto 0)) is
        begin
            wait until rising_edge(clock);
            request_data_from_address(bus_in, address);
            wait until rising_edge(clock);
            init_bus(bus_in);
            while not bus_read_done loop
                wait until rising_edge(clock);
            end loop;
            data := bus_read_data;
        end procedure;

        procedure restart is
        begin
            wait until rising_edge(clock);
            in_reset <= true;
            wait until rising_edge(clock);
            in_reset <= false;
        end procedure;

        impure function random16 return std_logic_vector is
        begin
            for i in 0 to 15 loop
                lfsr := lfsr(30 downto 0) & (lfsr(31) xor lfsr(21) xor lfsr(1) xor lfsr(0));
            end loop;
            return std_logic_vector(lfsr(15 downto 0));
        end function;

        function value(x : std_logic_vector(15 downto 0); c : natural) return integer is
        begin
            if c = 1 or c = 2 then
                return to_integer(unsigned(x));
            end if;
            return to_integer(signed(x));
        end function;

        -- rounded to nearest, halves away from zero
        function rounded(sum : integer; n : positive) return integer is
        begin
            if sum < 0 then
                return -((-sum + n / 2) / n);
            end if;
            return (sum + n / 2) / n;
        end function;

        -- one sample; fixed: from the test's table instead of random
        procedure sample(r : std_logic_vector(127 downto 0)) is
        begin
            wait until rising_edge(clock);
            in_write <= true;
            in_data  <= r;
        end procedure;

        procedure idle is
        begin
            wait until rising_edge(clock);
            in_write <= false;
        end procedure;

        -- record r's 32-bit field f (0: channels 0, 1 ... 3: channels 6, 7)
        impure function field(r : natural; f : natural) return natural is
        begin
            return to_integer(unsigned(got(r)(127 - 32*f downto 96 - 32*f)));
        end function;

        -- points points of n random samples, a sample every clock; checked
        procedure run_points(points : natural; n : positive) is
            variable base : natural;
        begin
            base := got_n;
            for p in 0 to points - 1 loop
                for s in 0 to n - 1 loop
                    for c in 0 to 7 loop
                        rec(127 - 16*c downto 112 - 16*c) := random16;
                        v := value(ch(rec, c), c);
                        if s = 0 or v < mn(c) then mn(c) := v; end if;
                        if s = 0 or v > mx(c) then mx(c) := v; end if;
                        if s = 0 then
                            sm(c) := v; an(c) := ch(rec, c); orr(c) := ch(rec, c);
                        else
                            sm(c) := sm(c) + v; an(c) := an(c) and ch(rec, c); orr(c) := orr(c) or ch(rec, c);
                        end if;
                        last(c) := ch(rec, c);
                    end loop;
                    sample(rec);
                end loop;
                idle;
                -- its three records
                for i in 0 to 100 loop
                    wait until rising_edge(clock);
                    exit when got_n >= base + 4 * (p + 1);
                end loop;
                check_equal(got_n, base + 4 * (p + 1), "records after point " & integer'image(p));
                check_equal(field(base + 4*p + 3, 0), base / 4 + p, "point " & integer'image(p) & " number");
                check_equal(field(base + 4*p + 3, 1), 0, "point " & integer'image(p) & " lost before");
                check_equal(field(base + 4*p + 3, 2), n, "point " & integer'image(p) & " n");
                check_equal(field(base + 4*p + 3, 3), 0, "point " & integer'image(p) & " zero");
                for c in 0 to 7 loop
                    if c = 2 then
                        check_equal(ch(got(base + 4*p), c), an(c), "point " & integer'image(p) & " AND");
                        check_equal(ch(got(base + 4*p + 1), c), orr(c), "point " & integer'image(p) & " OR");
                        check_equal(ch(got(base + 4*p + 2), c), last(c), "point " & integer'image(p) & " last");
                    else
                        check_equal(value(ch(got(base + 4*p), c), c), mn(c), "point " & integer'image(p) & " min, ch " & integer'image(c));
                        check_equal(value(ch(got(base + 4*p + 1), c), c), mx(c), "point " & integer'image(p) & " max, ch " & integer'image(c));
                        check_equal(value(ch(got(base + 4*p + 2), c), c), rounded(sm(c), n),
                                    "point " & integer'image(p) & " mean, ch " & integer'image(c));
                    end if;
                end loop;
            end loop;
        end procedure;

    begin
        test_runner_setup(runner, runner_cfg);
        wait until rising_edge(clock);

        while test_suite loop
            bus_write(regs + 2, formats);
            bus_write(regs + 0, x"00000001");
            restart;

            if run("points_match") then
                bus_write(regs + 1, std_logic_vector(to_unsigned(100, 32)));
                run_points(5, 100);
                bus_read(regs + 3, word);
                check_equal(unsigned(word), 5, "points counted");

            elsif run("rounding") then
                -- channel 0 (signed), n = 64: sums -96, -32, 32, 160
                bus_write(regs + 1, std_logic_vector(to_unsigned(64, 32)));
                for k in 0 to 3 loop
                    for s in 0 to 63 loop
                        rec := (others => '0');
                        CASE k is
                            WHEN 0 => v := -1 - (s mod 2);           -- mean -1.5
                            WHEN 1 => v := -(s mod 2);               -- -0.5
                            WHEN 2 => v := s mod 2;                  -- 0.5
                            WHEN others => v := 2 + (s mod 2);       -- 2.5
                        end CASE;
                        rec(127 downto 112) := std_logic_vector(to_signed(v, 16));
                        sample(rec);
                    end loop;
                end loop;
                idle;
                for i in 0 to 200 loop
                    wait until rising_edge(clock);
                end loop;
                check_equal(got_n, 16, "four points");
                check_equal(to_integer(signed(ch(got(2), 0))), -2, "-1.5 -> -2");
                check_equal(to_integer(signed(ch(got(6), 0))), -1, "-0.5 -> -1");
                check_equal(to_integer(signed(ch(got(10), 0))), 1, "0.5 -> 1");
                check_equal(to_integer(signed(ch(got(14), 0))), 3, "2.5 -> 3");

            elsif run("smallest_n") then
                bus_write(regs + 1, std_logic_vector(to_unsigned(10, 32)));     -- limited to 64
                bus_read(regs + 1, word);
                check_equal(unsigned(word), 64, "n limited");
                for s in 0 to 64 * 20 - 1 loop
                    sample(random16 & random16 & random16 & random16 & random16 & random16 & random16 & random16);
                end loop;
                idle;
                for i in 0 to 100 loop
                    wait until rising_edge(clock);
                end loop;
                check_equal(got_n, 80, "20 points");
                bus_read(regs + 4, word);
                check_equal(unsigned(word), 0, "none lost");

            elsif run("lost_whole") then
                bus_write(regs + 1, std_logic_vector(to_unsigned(64, 32)));
                for s in 0 to 64 * 10 - 1 loop
                    almost_full <= (s / 64) mod 3 = 1;               -- every third point no room
                    sample(random16 & random16 & random16 & random16 & random16 & random16 & random16 & random16);
                end loop;
                idle;
                almost_full <= false;
                for i in 0 to 100 loop
                    wait until rising_edge(clock);
                end loop;
                bus_read(regs + 4, word);
                info("lost " & integer'image(to_integer(unsigned(word))) & " of 10");
                check(unsigned(word) >= 1, "points lost");
                check_equal(got_n mod 4, 0, "records in fours");
                bus_read(regs + 3, word);
                check_equal(got_n, 4 * to_integer(unsigned(word)), "records = 4 x points sent");
                -- each point: its number = its place + the points lost before it
                for p in 0 to got_n / 4 - 1 loop
                    check_equal(field(4*p + 3, 0), p + field(4*p + 3, 1), "point " & integer'image(p) & " number");
                end loop;
                bus_read(regs + 4, word);
                check(field(got_n - 1, 1) <= to_integer(unsigned(word)), "lost before the last point");

            elsif run("passthrough") then
                bus_write(regs + 0, x"00000000");
                for s in 0 to 9 loop
                    sample(std_logic_vector(to_unsigned(s, 128)));
                end loop;
                idle;
                wait until rising_edge(clock);
                wait until rising_edge(clock);
                check_equal(got_n, 10, "every record");
                check_equal(to_integer(unsigned(got(7))), 7, "record 7");
            end if;
        end loop;

        test_runner_cleanup(runner);
    end process;

end architecture vunit_simulation;
