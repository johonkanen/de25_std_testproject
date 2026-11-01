------------------------------------------------------------------------
-- scope_block_tb - a capture read back through scope_block's register
-- window, the way Linux reads it over LWH2F: every word one bus read.
--
--   window_reads_counter  the test generator's counter on channel 7 steps
--                         by one from sample to sample over the whole
--                         capture (the window's latency and word order)
--   probe_in_channel      a probe routed to channel 0 arrives there
--   reply_within_timeout  a window read answers within the LWH2F bridge's
--                         read timeout (axi_lwh2f_bridge.vhd)
------------------------------------------------------------------------
LIBRARY ieee;
    USE ieee.NUMERIC_STD.all;
    USE ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.vunit_context;

    use work.scope_pkg.all;
    use work.fpga_interconnect_pkg.all;

entity scope_block_tb is
    generic (runner_cfg : string);
end;

architecture vunit_simulation of scope_block_tb is

    constant base    : natural := 256;
    constant window  : natural := 16#8000#;
    constant depth   : natural := 256;
    constant probe_value : std_logic_vector(15 downto 0) := x"1234";
    -- the bridge's read timeout, in clocks from its request (it answers 0
    -- after that); the bridge itself and register_block add 2 clocks
    constant bridge_timeout : natural := 15;

    signal clock : std_logic := '0';
    signal bus_in, bus_out : fpga_interconnect_record := init_fpga_interconnect;
    constant probe_table : probe_table_array(0 to 1) := (
        0 => probe_entry("fixed", unsigned_probe),
        1 => probe_entry("lanes", digital_probe));
    signal probes : scope_sample_array(0 to 1) := (0 => probe_value, 1 => x"0003");

    signal bus_read_data : std_logic_vector(31 downto 0);
    signal bus_read_done : boolean := false;

begin

    clock <= not clock after 10 ns;     -- 50 MHz, as on the board

    dut : entity work.scope_block
        generic map (g_base_address => base, g_window => window, g_depth => depth,
                     g_probes => 2, g_probe_table => probe_table)
        port map (clock => clock, bus_in => bus_in, bus_out => bus_out, probes => probes);

    capture_bus_reads : process (clock)
    begin
        if rising_edge(clock) then
            bus_read_done <= false;
            if write_to_address_is_requested(bus_out, 0) then
                bus_read_data <= get_slv_data(bus_out);
                bus_read_done <= true;
            end if;
        end if;
    end process;

    main : process
        variable word    : std_logic_vector(31 downto 0);
        variable clocks  : natural;
        variable previous, now : integer;

        procedure bus_write(address : natural; data : natural) is
        begin
            wait until rising_edge(clock);
            write_data_to_address(bus_in, address, data);
            wait until rising_edge(clock);
            init_bus(bus_in);
        end procedure;

        -- clocks counts from the request to the reply
        procedure bus_read(address : natural; data : out std_logic_vector(31 downto 0);
                           clocks : out natural) is
            variable n : natural := 0;
        begin
            wait until rising_edge(clock);
            request_data_from_address(bus_in, address);
            wait until rising_edge(clock);
            init_bus(bus_in);
            n := 1;
            while not bus_read_done loop
                wait until rising_edge(clock);
                n := n + 1;
                exit when n > 100;
            end loop;
            check(bus_read_done, "no reply from " & integer'image(address));
            data := bus_read_data;
            clocks := n;
        end procedure;

        procedure capture is
            variable status : std_logic_vector(31 downto 0);
            variable n : natural;
        begin
            bus_write(base, 1);                                -- arm
            for i in 0 to 1000 loop
                bus_read(base, status, n);
                exit when status(2 downto 0) = "100";
                wait for 1 us;
            end loop;
            check_equal(status(2 downto 0), std_logic_vector'("100"), "capture done");
        end procedure;

    begin
        test_runner_setup(runner, runner_cfg);
        -- the test generator's pipeline fills first (on the board it has
        -- run for seconds before anything arms the scope)
        wait for 1 us;

        while test_suite loop
            if run("window_reads_counter") then
                capture;
                for s in 0 to depth-1 loop
                    bus_read(window + 4*s + 3, word, clocks);  -- channels 6, 7
                    now := to_integer(unsigned(word(15 downto 0)));
                    if s > 0 and (now - previous) mod 65536 /= 1 then
                        check(false, "counter jumps at sample " & integer'image(s)
                              & ": " & integer'image(previous) & " -> " & integer'image(now));
                        exit;
                    end if;
                    previous := now;
                end loop;

            elsif run("probe_in_channel") then
                -- channel 0 from source 8, the first probe; 1..3 as they were
                bus_write(base + 6, 16#03020108#);
                capture;
                for s in 0 to depth-1 loop
                    bus_read(window + 4*s, word, clocks);
                    check_equal(word(31 downto 16), probe_value, "channel 0, sample " & integer'image(s));
                end loop;

            elsif run("reply_within_timeout") then
                capture;
                bus_read(window + 5, word, clocks);
                info("window read: reply " & integer'image(clocks) & " clocks after the request");
                check(clocks + 2 < bridge_timeout, "reply after " & integer'image(clocks) & " clocks");
            end if;
        end loop;

        test_runner_cleanup(runner);
    end process;

end architecture vunit_simulation;
