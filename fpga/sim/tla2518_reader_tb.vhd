------------------------------------------------------------------------
-- tla2518_reader_tb - the reader against a model of the TLA2518: SPI-00,
-- its registers (write, read, RST, CAL), auto-sequence with the channel ID
-- appended, FIX_PAT; with board delays on SCLK and SDO and the ADC's
-- worst-case SDO delay (16 ns). The model checks the reader's timing: SCLK
-- at most 60 MHz, CS high at least tCONV (600 ns), a cycle at least 1 us.
-- A conversion's result is its channel (bits 11:9) and the model's
-- conversion number (bits 8:0), so a lost, doubled or misplaced frame shows.
--
--   all_channels     the default mask: every channel in order, every
--                    conversion once, no ID errors, the values in place
--   mask_two         mask 0x24: AIN2 and AIN5 by turns
--   fixed_pattern    FIX_PAT: every frame 0xA5A5 with no channel ID (as the
--                    board's ADC does): 0xA5A everywhere, no errors
--   id_error         a frame with a wrong ID: counted, the next ones fine
--   register_access  stopped: write a register of the ADC, read it back
--   slow_sclk        SCLK half period 3 (8.3 MHz): still every conversion
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

    use work.fpga_interconnect_pkg.all;

entity tla2518_reader_tb is
    generic (runner_cfg : string);
end;

architecture vunit_simulation of tla2518_reader_tb is

    constant regs : natural := 320;
    constant board_delay : time := 5 ns;      -- each way, FPGA pin to ADC pin
    constant t_d_ckdo    : time := 16 ns;     -- the ADC: SCLK falling to SDO valid

    signal clock : std_logic := '0';
    signal reset : std_logic := '1';
    signal bus_in, bus_out : fpga_interconnect_record := init_fpga_interconnect;

    signal sclk, cs_n, sdi, sdo : std_logic;
    signal sclk_adc, cs_n_adc, sdi_adc, sdo_adc : std_logic := '0';

    signal values    : std_logic_vector(95 downto 0);
    signal converted : boolean;
    signal channel   : natural range 0 to 7;
    signal scanned   : boolean;

    -- the model
    type reg_array is array (0 to 31) of std_logic_vector(7 downto 0);
    signal timing_errors : natural := 0;
    signal corrupt_next  : boolean := false;    -- main: one frame's ID wrong, once
    signal model_regs    : reg_array;

    -- what the reader gave: checked as it comes
    signal got, got_bad : natural := 0;
    signal last_number  : integer := -1;
    signal seen         : std_logic_vector(7 downto 0) := (others => '0');
    signal fixed_mode   : boolean := false;
    signal order_mask   : std_logic_vector(7 downto 0) := x"FF";
    signal last_channel : integer := -1;
    signal order_free   : boolean := false;
    signal fresh_req    : boolean := false;    -- main: start the checks again    -- a frame dropped on purpose: no order checks

    signal bus_read_data : std_logic_vector(31 downto 0);
    signal bus_read_done : boolean := false;

    function next_in(mask : std_logic_vector(7 downto 0); c : natural) return natural is
    begin
        for i in 1 to 8 loop
            if mask((c + i) mod 8) = '1' then
                return (c + i) mod 8;
            end if;
        end loop;
        return c;
    end function;

begin

    clock <= not clock after 10 ns;

    dut : entity work.tla2518_reader
        generic map (g_base_address => regs, g_wait_clocks => 100)
        port map (clock => clock, reset => reset, bus_in => bus_in, bus_out => bus_out,
                  adc_sclk => sclk, adc_cs_n => cs_n, adc_sdi => sdi, adc_sdo => sdo,
                  values => values, converted => converted, channel => channel, scanned => scanned);

    sclk_adc <= transport sclk after board_delay;
    cs_n_adc <= transport cs_n after board_delay;
    sdi_adc  <= transport sdi after board_delay;
    sdo      <= transport sdo_adc after board_delay;

    ------------------------------------------------------------------------
    adc : process
        variable r : reg_array := (0 => x"81", others => x"00");
        variable rx : std_logic_vector(23 downto 0);
        variable tx : std_logic_vector(23 downto 0);
        variable bits : natural;
        variable mux : natural := 0;
        variable result : std_logic_vector(11 downto 0) := (others => '0');
        variable result_ch : natural := 0;
        variable number : natural := 0;
        variable read_pending : boolean := false;
        variable read_addr : natural;
        variable seq_on : boolean := false;
        variable t_rise, t_fall, t_last_rise, t_cs_rise, t_cs_rise_before : time := 0 ns;
        variable addr : natural;
        variable corrupted : boolean := false;

        procedure lowest(variable m : out natural) is
        begin
            m := 0;
            for k in 0 to 7 loop
                if r(16#12#)(k) = '1' then
                    m := k;
                    return;
                end if;
            end loop;
        end procedure;
    begin
        sdo_adc <= 'Z';
        wait until cs_n_adc = '0';
        loop
            -- a frame: CS low
            if t_cs_rise > 0 ns then
                if now - t_cs_rise < 600 ns then
                    timing_errors <= timing_errors + 1;
                    report "CS low " & time'image(now - t_cs_rise) & " after the conversion started"
                        severity warning;
                end if;
            end if;
            -- what goes out: a register read's answer, or the last conversion
            if read_pending then
                tx := r(read_addr) & x"0000";
                read_pending := false;
            else
                if r(2)(7) = '1' then
                    tx := x"A5A5A5";                -- FIX_PAT: the pattern only, no ID (as on the board)
                else
                    tx := result & std_logic_vector(to_unsigned(result_ch, 4)) & x"00";
                end if;
                if corrupt_next and not corrupted then
                    corrupted := true;
                    tx(11 downto 8) := std_logic_vector(to_unsigned((result_ch + 3) mod 8, 4));
                end if;
                if r(2)(5 downto 4) /= "01" and r(2)(7) = '0' then
                    tx(11 downto 8) := x"0";
                end if;
            end if;
            sdo_adc <= tx(23) after 15 ns;
            tx := tx(22 downto 0) & '0';
            bits := 0;
            rx := (others => '0');
            loop
                wait until sclk_adc'event or cs_n_adc = '1';
                exit when cs_n_adc = '1';
                if rising_edge(sclk_adc) then
                    if t_last_rise > 0 ns and now - t_last_rise < 16.6 ns then
                        timing_errors <= timing_errors + 1;
                        report "SCLK faster than 60 MHz" severity warning;
                    end if;
                    t_last_rise := now;
                    rx := rx(22 downto 0) & sdi_adc;
                    bits := bits + 1;
                elsif falling_edge(sclk_adc) then
                    sdo_adc <= 'X', tx(23) after t_d_ckdo;
                    tx := tx(22 downto 0) & '0';
                end if;
            end loop;
            sdo_adc <= 'Z' after 10 ns;
            t_last_rise := 0 ns;
            -- CS rising: the command, then a conversion
            if t_cs_rise > 0 ns and now - t_cs_rise < 1000 ns then
                timing_errors <= timing_errors + 1;
                report "cycle " & time'image(now - t_cs_rise) & ", under 1 us" severity warning;
            end if;
            t_cs_rise := now;
            result_ch := mux;
            result := std_logic_vector(to_unsigned(mux, 3)) & std_logic_vector(to_unsigned(number mod 512, 9));
            number := number + 1;
            if seq_on then
                mux := next_in(r(16#12#), mux);
            end if;
            if bits >= 24 then
                addr := to_integer(unsigned(rx(15 downto 8))) mod 32;
                if rx(23 downto 16) = x"08" then
                    r(addr) := rx(7 downto 0);
                    if addr = 1 and rx(0) = '1' then           -- RST
                        r := (0 => x"81", others => x"00");
                        seq_on := false;
                    elsif addr = 1 then
                        r(1)(1) := '0';                        -- CAL done
                    elsif addr = 16#10# then
                        seq_on := rx(4) = '1' and rx(1 downto 0) = "01";
                        if seq_on then
                            lowest(mux);
                        end if;
                    end if;
                elsif rx(23 downto 16) = x"10" then
                    read_pending := true;
                    read_addr := addr;
                end if;
            end if;
            model_regs <= r;
            wait until cs_n_adc = '0';
        end loop;
    end process;

    ------------------------------------------------------------------------
    check_results : process (clock)
        variable v : std_logic_vector(11 downto 0);
        variable n : integer;
    begin
        if rising_edge(clock) and converted then
            got <= got + 1;
            v := values(12*channel + 11 downto 12*channel);
            seen(channel) <= '1';
            if fixed_mode then
                if v /= x"A5A" then
                    got_bad <= got_bad + 1;
                end if;
            else
                n := to_integer(unsigned(v(8 downto 0)));
                if to_integer(unsigned(v(11 downto 9))) /= channel then
                    got_bad <= got_bad + 1;
                    report "channel " & integer'image(channel) & " holds a result of "
                        & integer'image(to_integer(unsigned(v(11 downto 9)))) severity warning;
                end if;
                if last_number >= 0 and n /= (last_number + 1) mod 512 and not order_free then
                    got_bad <= got_bad + 1;
                    report "conversion " & integer'image(n) & " after " & integer'image(last_number)
                        severity warning;
                end if;
                last_number <= n;
            end if;
            if last_channel >= 0 and channel /= next_in(order_mask, last_channel) and not order_free then
                got_bad <= got_bad + 1;
                report "channel " & integer'image(channel) & " after " & integer'image(last_channel)
                    severity warning;
            end if;
            last_channel <= channel;
        end if;
        if rising_edge(clock) and fresh_req then
            last_number  <= -1;
            last_channel <= -1;
            seen         <= (others => '0');
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
        variable word : std_logic_vector(31 downto 0);

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

        procedure wait_conversions(n : natural) is
            variable start : natural;
        begin
            start := got;
            for i in 0 to 200 * n + 2000 loop
                wait until rising_edge(clock);
                exit when got >= start + n;
            end loop;
            check(got >= start + n, "conversions: " & integer'image(got - start) & " of " & integer'image(n));
        end procedure;

        procedure fresh is
        begin
            fresh_req <= true;
            wait until rising_edge(clock);
            fresh_req <= false;
        end procedure;
    begin
        test_runner_setup(runner, runner_cfg);
        for i in 0 to 4 loop
            wait until rising_edge(clock);
        end loop;
        reset <= '0';

        while test_suite loop
            if run("all_channels") then
                wait_conversions(100);
                check_equal(seen, std_logic_vector'(x"FF"), "every channel");
                bus_read(regs + 2, word);
                check(unsigned(word) >= 100, "conversions counted");
                bus_read(regs + 3, word);
                check_equal(unsigned(word), 0, "ID errors");
                bus_read(regs + 1, word);
                check_equal(word(2 downto 0), std_logic_vector'("011"), "state converting");
                bus_read(regs + 5 + 6, word);
                check_equal(unsigned(word(11 downto 9)), 6, "register of AIN6");
                bus_read(regs + 13, word);
                check(unsigned(word) >= 12, "scans");
                -- the rate: 66 clocks a conversion
                fresh;
                wait for 100 us;
                info(integer'image(got) & " conversions so far");

            elsif run("mask_two") then
                order_mask <= x"24";
                bus_write(regs + 0, x"20012405");
                fresh;
                wait_conversions(40);
                check_equal(seen, std_logic_vector'(x"24"), "AIN2 and AIN5 only");
                bus_read(regs + 3, word);
                check_equal(unsigned(word), 0, "ID errors");

            elsif run("fixed_pattern") then
                fixed_mode <= true;
                bus_write(regs + 0, x"2001FF07");
                fresh;
                wait_conversions(50);
                check_equal(seen, std_logic_vector'(x"FF"), "every channel");
                bus_read(regs + 3, word);
                check_equal(unsigned(word), 0, "frames not A5A5");

            elsif run("id_error") then
                wait_conversions(20);
                wait until rising_edge(clock) and converted;
                order_free   <= true;
                corrupt_next <= true;
                wait_conversions(4);
                order_free   <= false;
                wait_conversions(30);
                bus_read(regs + 3, word);
                check(unsigned(word) >= 1, "the bad frame counted");
                info(integer'image(to_integer(unsigned(word))) & " ID errors");

            elsif run("register_access") then
                bus_write(regs + 0, x"2001FF00");          -- stopped
                wait for 3 us;
                bus_write(regs + 4, x"00000B5A");          -- GPO_VALUE (0x0B) := 0x5A
                wait for 3 us;
                check_equal(model_regs(16#0B#), std_logic_vector'(x"5A"), "written");
                bus_write(regs + 4, x"00010B00");          -- read 0x0B
                wait for 5 us;
                bus_read(regs + 1, word);
                check_equal(word(15 downto 8), std_logic_vector'(x"5A"), "read back");
                check_equal(word(2 downto 0), std_logic_vector'("000"), "stopped");

            elsif run("slow_sclk") then
                bus_write(regs + 0, x"2003FF05");
                fresh;
                wait_conversions(30);
                bus_read(regs + 3, word);
                check_equal(unsigned(word), 0, "ID errors");
            end if;

            check_equal(timing_errors, 0, "the ADC's timing");
            check_equal(got_bad, 0, "results");
        end loop;

        test_runner_cleanup(runner);
    end process;

end architecture vunit_simulation;
