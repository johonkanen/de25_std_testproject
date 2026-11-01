------------------------------------------------------------------------
-- scope_ddr_writer_tb - the DDR writer against an AXI memory on each bus
-- that stalls AW, W and B at random.
--
--   pattern_fill     a fill writes seed + i into word i, exactly count beats
--   capture_records  an odd number of records from the capture port: each
--                    in its place, channel 0 first, nothing past the last;
--                    capture_written reaches the count
--   ring_wraps       more records than the ring: the ring holds the last ones
--   restart_cleans   a capture port restart starts at record 0 again
--   f2h_selected     bus bit 0 = 1: the writes go to F2H, F2SDRAM stays idle
--   full_when_stuck  the bus takes nothing: capture_is_full comes
--   full_rate        a record every clock (50 MS/s) over F2H, which stalls
--                    3/16 of the time: the FIFO never fills
--   slow_flush       a few records and no flush: after g_flush_clocks the
--                    whole beats are in memory, the lone record not; more
--                    from there on (bursts no longer aligned) all in place
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use work.hps_axi_pkg.all;

package axi_mem_model_pkg is
    type word_array is array (natural range <>) of std_logic_vector(31 downto 0);
end package;

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use work.hps_axi_pkg.all;
    use work.axi_mem_model_pkg.all;

-- an AXI4 write subordinate: g_words 32-bit words from g_base; stalls at
-- random with probability g_stall/16 on each channel; B g_b_delay clocks
-- after the last beat. stuck: takes nothing.
entity axi_mem_model is
    generic (
        g_base    : unsigned(31 downto 0);
        g_words   : positive;
        g_seed    : positive := 1;
        g_stall   : natural := 6;
        g_b_delay : positive := 5
    );
    port (
        clock  : in  std_logic;
        m2s    : in  t_axi256_m2s;
        s2m    : out t_axi256_s2m;
        stuck  : in  boolean := false;
        memory : out word_array(0 to g_words-1);
        errors : out natural := 0      -- writes outside the memory, bursts across 4 KB
    );
end entity;

architecture sim of axi_mem_model is
    signal lfsr : unsigned(15 downto 0) := to_unsigned(g_seed * 7919 mod 65536, 16);
    signal mem  : word_array(0 to g_words-1) := (others => x"DEADBEEF");
    type addr_queue is array (0 to 31) of unsigned(31 downto 0);
    signal aw_q : addr_queue;
    signal aw_len_q : addr_queue;
    signal aw_head, aw_tail : natural range 0 to 31 := 0;
    signal beat : natural := 0;
    type b_queue is array (0 to 31) of natural;
    signal b_due : b_queue;
    signal b_head, b_tail : natural range 0 to 31 := 0;
    signal now_clock : natural := 0;
    signal awready, wready : std_logic := '0';
    signal bvalid : std_logic := '0';
begin
    memory <= mem;
    s2m <= (awready => awready, wready => wready, bid => (others => '0'), bresp => "00",
            buser => (others => '0'), bvalid => bvalid, arready => '0', rid => (others => '0'),
            rdata => (others => '0'), rresp => "00", rlast => '0', ruser => (others => '0'),
            rvalid => '0');

    process (clock)
        variable addr : unsigned(31 downto 0);
        variable w    : integer;
        variable err  : natural;
        variable v_head, v_tail : natural range 0 to 31;
    begin
        if rising_edge(clock) then
            now_clock <= now_clock + 1;
            lfsr <= lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
            err := errors;

            if awready = '1' and m2s.awvalid = '1' then
                aw_q(aw_tail) <= unsigned(m2s.awaddr);
                aw_len_q(aw_tail) <= resize(unsigned(m2s.awlen), 32);
                aw_tail <= (aw_tail + 1) mod 32;
                addr := unsigned(m2s.awaddr);
                if (addr mod 4096) + (to_integer(unsigned(m2s.awlen)) + 1) * 32 > 4096 then
                    err := err + 1;
                end if;
                if m2s.awsize /= "101" or m2s.awburst /= "01" then
                    err := err + 1;
                end if;
            end if;

            if wready = '1' and m2s.wvalid = '1' then
                -- this model takes W only for an address already taken
                addr := aw_q(aw_head) + beat * 32;
                for j in 0 to 7 loop
                    w := to_integer(addr - g_base) / 4 + j;
                    if w < 0 or w >= g_words then
                        err := err + 1;
                    elsif m2s.wstrb(4*j) = '1' then
                        mem(w) <= m2s.wdata(32*j + 31 downto 32*j);
                    end if;
                end loop;
                if m2s.wlast = '1' then
                    if beat /= to_integer(aw_len_q(aw_head)) then
                        err := err + 1;
                    end if;
                    beat <= 0;
                    aw_head <= (aw_head + 1) mod 32;
                    b_due(b_tail) <= now_clock + g_b_delay;
                    b_tail <= (b_tail + 1) mod 32;
                else
                    beat <= beat + 1;
                end if;
            end if;

            if bvalid = '1' and m2s.bready = '1' then
                bvalid <= '0';
                b_head <= (b_head + 1) mod 32;
            elsif bvalid = '0' and b_head /= b_tail and b_due(b_head) <= now_clock
                  and to_integer(lfsr(3 downto 0)) >= g_stall and not stuck then
                bvalid <= '1';
            end if;

            -- W only for an address taken (the queue after this clock)
            v_head := aw_head;
            v_tail := aw_tail;
            if awready = '1' and m2s.awvalid = '1' then
                v_tail := (v_tail + 1) mod 32;
            end if;
            if wready = '1' and m2s.wvalid = '1' and m2s.wlast = '1' then
                v_head := (v_head + 1) mod 32;
            end if;
            awready <= '0';
            wready  <= '0';
            if not stuck then
                if to_integer(lfsr(7 downto 4)) >= g_stall then
                    awready <= '1';
                end if;
                if to_integer(lfsr(11 downto 8)) >= g_stall and v_head /= v_tail then
                    wready <= '1';
                end if;
            end if;
            errors <= err;
        end if;
    end process;
end architecture;

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

    use work.fpga_interconnect_pkg.all;
    use work.hps_axi_pkg.all;
    use work.axi_mem_model_pkg.all;

entity scope_ddr_writer_tb is
    generic (runner_cfg : string);
end;

architecture vunit_simulation of scope_ddr_writer_tb is

    constant regs    : natural := 288;
    constant ring    : natural := 256;                     -- records
    constant words   : natural := ring * 4;
    constant base    : unsigned(31 downto 0) := x"B0000000";

    signal clock : std_logic := '0';
    signal reset : std_logic := '1';
    signal bus_in, bus_out : fpga_interconnect_record := init_fpga_interconnect;

    signal capture_reset, capture_write, capture_flush : boolean := false;
    signal capture_data : std_logic_vector(127 downto 0) := (others => '0');
    signal capture_is_full, capture_is_ready : boolean;
    signal capture_written : unsigned(31 downto 0);

    signal f2sdram_m2s, f2h_m2s : t_axi256_m2s;
    signal f2sdram_s2m, f2h_s2m : t_axi256_s2m;
    signal mem_a, mem_b : word_array(0 to words-1);
    signal errors_a, errors_b : natural;
    signal stuck : boolean := false;
    signal f2sdram_seen : boolean := false;
    signal full_seen : boolean := false;

    signal bus_read_data : std_logic_vector(31 downto 0);
    signal bus_read_done : boolean := false;

    -- record r, channel c of the test stream
    function sample(r : natural; c : natural) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned((r * 8 + c) mod 65536, 16));
    end function;

    function halfword(mem : word_array; h : natural) return std_logic_vector is
        constant w : std_logic_vector(31 downto 0) := mem(h / 2);
    begin
        if h mod 2 = 0 then
            return w(15 downto 0);
        end if;
        return w(31 downto 16);
    end function;

begin

    clock <= not clock after 10 ns;

    dut : entity work.scope_ddr_writer
        generic map (g_base_address => regs, g_ring_records => ring, g_burst_beats => 16,
                     g_fifo_beats => 64, g_max_outstanding => 4, g_flush_clocks => 2000)
        port map (
            clock => clock, reset => reset, bus_in => bus_in, bus_out => bus_out,
            capture_reset => capture_reset, capture_write => capture_write,
            capture_data => capture_data, capture_flush => capture_flush,
            capture_is_full => capture_is_full, capture_is_ready => capture_is_ready,
            capture_written => capture_written,
            f2sdram_m2s => f2sdram_m2s, f2sdram_s2m => f2sdram_s2m,
            f2h_m2s => f2h_m2s, f2h_s2m => f2h_s2m);

    mem_f2sdram : entity work.axi_mem_model
        generic map (g_base => base, g_words => words, g_seed => 3)
        port map (clock => clock, m2s => f2sdram_m2s, s2m => f2sdram_s2m, stuck => stuck,
                  memory => mem_a, errors => errors_a);

    mem_f2h : entity work.axi_mem_model
        generic map (g_base => base, g_words => words, g_seed => 11, g_stall => 3, g_b_delay => 12)
        port map (clock => clock, m2s => f2h_m2s, s2m => f2h_s2m, stuck => stuck,
                  memory => mem_b, errors => errors_b);

    watch_f2sdram : process (clock)
    begin
        if rising_edge(clock) and (f2sdram_m2s.awvalid = '1' or f2sdram_m2s.wvalid = '1') then
            f2sdram_seen <= true;
        end if;
        if rising_edge(clock) and capture_write and capture_is_full then
            full_seen <= true;
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
        variable gap  : natural;

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

        procedure wait_idle is
        begin
            for i in 0 to 10000 loop
                bus_read(regs + 2, word);
                exit when word(3 downto 0) = "0000" and word(11 downto 8) = x"0";
            end loop;
            check_equal(word(3 downto 0), std_logic_vector'("0000"), "writer idle");
        end procedure;

        procedure restart is
        begin
            wait until rising_edge(clock);
            capture_reset <= true;
            wait until rising_edge(clock);
            capture_reset <= false;
            for i in 0 to 7 loop
                wait until rising_edge(clock);
            end loop;
            while not capture_is_ready loop
                wait until rising_edge(clock);
            end loop;
        end procedure;

        -- records first .. first+count-1, with gaps of 0..3 clocks, then the flush;
        -- without it, wait for the timeout's: written then first+count (rounded
        -- down to whole beats)
        procedure send(first : natural; count : natural; gaps : boolean := true;
                       flush : boolean := true) is
            variable expect : natural;
        begin
            for r in first to first + count - 1 loop
                wait until rising_edge(clock);
                capture_write <= true;
                for c in 0 to 7 loop
                    capture_data(127 - 16*c downto 112 - 16*c) <= sample(r, c);
                end loop;
                if gaps or r = first + count - 1 then
                    wait until rising_edge(clock);
                    capture_write <= false;
                end if;
                gap := (r * 7) mod 4;
                if not gaps then
                    gap := 0;
                end if;
                for g in 1 to gap loop
                    wait until rising_edge(clock);
                end loop;
            end loop;
            capture_flush <= flush;
            expect := count;
            if not flush then
                expect := (first + count) / 2 * 2;
            end if;
            for i in 0 to 20000 loop
                wait until rising_edge(clock);
                exit when capture_written >= expect;
            end loop;
            capture_flush <= false;
            if capture_written /= expect then
                bus_read(regs + 2, word);
                info("status " & to_hstring(word));
                bus_read(regs + 6, word);
                info("answers " & to_hstring(word));
            end if;
            check_equal(to_integer(capture_written), expect, "capture_written");
        end procedure;

        procedure check_record(mem : word_array; position : natural; r : natural) is
        begin
            for c in 0 to 7 loop
                check_equal(halfword(mem, 8 * position + c), sample(r, c),
                            "record " & integer'image(r) & " channel " & integer'image(c));
            end loop;
        end procedure;

    begin
        test_runner_setup(runner, runner_cfg);
        for i in 0 to 9 loop
            wait until rising_edge(clock);
        end loop;
        reset <= '0';
        bus_write(regs + 0, std_logic_vector(base));

        while test_suite loop
            if run("pattern_fill") then
                bus_write(regs + 3, std_logic_vector(to_unsigned(100, 32)));
                bus_write(regs + 4, x"00001000");
                bus_write(regs + 2, x"00000001");
                wait for 1 us;
                wait_idle;
                for i in 0 to words - 1 loop
                    if i < 800 then
                        check_equal(mem_a(i), std_logic_vector(to_unsigned(16#1000# + i, 32)),
                                    "word " & integer'image(i));
                    else
                        check_equal(mem_a(i), std_logic_vector'(x"DEADBEEF"), "word " & integer'image(i));
                    end if;
                end loop;
                bus_read(regs + 5, word);
                info("100 beats in " & integer'image(to_integer(unsigned(word))) & " clocks");
                check(unsigned(word) >= 100 and unsigned(word) < 600, "fill clocks");
                bus_read(regs + 6, word);
                check_equal(unsigned(word), 7, "bursts (16 x 6 + 4)");
                check_equal(errors_a, 0, "model errors");

            elsif run("capture_records") then
                restart;
                send(0, 37);
                for r in 0 to 36 loop
                    check_record(mem_a, r, r);
                end loop;
                for i in 37 * 4 to words - 1 loop
                    check_equal(mem_a(i), std_logic_vector'(x"DEADBEEF"), "past the capture, word " & integer'image(i));
                end loop;
                check_equal(errors_a, 0, "model errors");

            elsif run("ring_wraps") then
                restart;
                send(0, 300);
                for r in 300 - ring to 299 loop
                    check_record(mem_a, r mod ring, r);
                end loop;
                check_equal(errors_a, 0, "model errors");

            elsif run("restart_cleans") then
                restart;
                send(0, 21);
                wait_idle;
                restart;
                send(1000, 10);
                for r in 0 to 9 loop
                    check_record(mem_a, r, 1000 + r);
                end loop;
                -- the first capture's records 10..20 are still there
                check_record(mem_a, 15, 15);

            elsif run("f2h_selected") then
                bus_write(regs + 1, x"00E03021");
                restart;
                send(0, 64);
                for r in 0 to 63 loop
                    check_record(mem_b, r, r);
                end loop;
                check(not f2sdram_seen, "F2SDRAM idle");
                check_equal(errors_b, 0, "model errors");

            elsif run("full_rate") then
                bus_write(regs + 1, x"00E03021");
                restart;
                send(0, 3000, gaps => false);
                check(not full_seen, "capture_is_full was never raised");
                for r in 3000 - ring to 2999 loop
                    check_record(mem_b, r mod ring, r);
                end loop;
                bus_read(regs + 2, word);
                info("FIFO high water " & integer'image(to_integer(unsigned(word(31 downto 16)))) & " beats");

            elsif run("slow_flush") then
                restart;
                send(0, 7, flush => false);         -- 3 beats out, record 6 waits
                for r in 0 to 5 loop
                    check_record(mem_a, r, r);
                end loop;
                check_equal(mem_a(6 * 4), std_logic_vector'(x"DEADBEEF"), "the lone record not yet");
                send(7, 45, flush => false);        -- beats 3..25: a short burst, then aligned ones
                for r in 0 to 51 loop
                    check_record(mem_a, r, r);
                end loop;
                bus_read(regs + 6, word);
                info(integer'image(to_integer(unsigned(word))) & " bursts");
                check_equal(errors_a, 0, "model errors");

            elsif run("full_when_stuck") then
                restart;
                stuck <= true;
                for r in 0 to 300 loop
                    wait until rising_edge(clock);
                    capture_write <= true;
                    exit when capture_is_full;
                end loop;
                wait until rising_edge(clock);
                capture_write <= false;
                check(capture_is_full, "capture_is_full");
            end if;
        end loop;

        test_runner_cleanup(runner);
    end process;

end architecture vunit_simulation;
