------------------------------------------------------------------------
-- scope_ddr_writer - scope_capture's deep capture port into a ring in the
-- HPS DDR, as 256 bit AXI4 write bursts over F2SDRAM or F2H
-- (docs/plan_scope.md, phase 2).
--
-- Memory layout as on the Ti60: record r of the ring is the 16 bytes at
-- ring base + 16*r, channel c of it the little-endian int16 at byte 2*c.
-- A 32-byte beat carries two records, the even one in the low half.
--
-- Bursts are at most g_burst_beats beats and never cross a multiple of
-- g_burst_beats beats (so never a 4 KB boundary, nor the ring's end). A
-- capture's last odd record goes out as a beat with only its low 16 bytes
-- strobed: nothing past the capture is written. Several bursts may be in
-- flight; capture_written counts the records whose burst the bus has
-- answered (the B response), so they are in memory.
--
-- A test pattern, for measuring the buses without the scope: a fill
-- writes beats 0..count-1 of the ring, 32-bit word i (counted from the
-- ring base) = seed + i, as fast as the bus takes it, and keeps the
-- clocks it took.
--
-- register map, offsets from g_base_address
--   0  RW ring base: the bus address of record 0, 4 KB aligned (bits 11:0
--         are ignored)
--   1  RW bus: bit 0 the bus (0 F2SDRAM, 1 F2H), bits 7:4 AxCACHE,
--         bits 9:8 AxDOMAIN (F2H only), bits 14:12 AxPROT, bits 23:16
--         AxUSER. Change it only while nothing is written. Reset 0x00E03020:
--         F2SDRAM, AxCACHE 0010, AxPROT 011, AxUSER 0xE0 (as Altera's
--         f2sdram_adapter in the Agilex 5 GSRD)
--   2  W  command: bit 0 start a pattern fill (once the writer is idle),
--         bit 1 clear the counters in 5..7
--      R  status: bit 0 pattern fill running, bit 1 capture port
--         restarting, bit 2 a W burst under way, bit 3 an address waiting
--         (AWVALID), bits 11:8 bursts in flight, bits 31:16 most beats
--         waiting in the FIFO since the capture port's last restart
--   3  RW pattern fill length in beats (32 bytes), up to the ring
--   4  RW pattern seed
--   5  R  clocks the last pattern fill took, its start to its last answer
--   6  R  bursts answered (B responses)
--   7  R  bits 15:0 answers that were not OKAY, bits 17:16 the last such
--         BRESP
--   8  R  g_ring_records
--   9  R  bits 15:0 g_burst_beats, bits 31:16 g_fifo_beats
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use work.fpga_interconnect_pkg.all;
    use work.hps_axi_pkg.all;

entity scope_ddr_writer is
    generic (
        g_base_address    : natural;
        g_ring_records    : positive;           -- power of two, >= 2*g_burst_beats
        g_burst_beats     : positive := 16;     -- power of two, at most 128 (4 KB)
        g_fifo_beats      : positive := 512;    -- power of two
        g_max_outstanding : positive := 8       -- bursts in flight, at most 15
    );
    port (
        clock   : in  std_logic;
        reset   : in  std_logic;                -- active high: the buses idle
        bus_in  : in  fpga_interconnect_record;
        bus_out : out fpga_interconnect_record;

        -- from scope_capture
        capture_reset    : in  boolean;
        capture_write    : in  boolean;
        capture_data     : in  std_logic_vector(127 downto 0);
        capture_flush    : in  boolean;
        capture_is_full  : out boolean;
        capture_is_ready : out boolean;
        capture_written  : out unsigned(31 downto 0);

        f2sdram_m2s : out t_axi256_m2s;
        f2sdram_s2m : in  t_axi256_s2m;
        f2h_m2s     : out t_axi256_m2s;
        f2h_s2m     : in  t_axi256_s2m
    );
end entity scope_ddr_writer;

architecture rtl of scope_ddr_writer is

    constant ring_beats : positive := g_ring_records / 2;

    -- a beat in the FIFO: bit 256 set when only its low half is a record
    subtype beat_t is std_logic_vector(256 downto 0);
    type beat_array is array (natural range <>) of beat_t;

    -- registers
    signal ring_base     : std_logic_vector(31 downto 0) := (others => '0');
    signal bus_config    : std_logic_vector(31 downto 0) := x"00E03020";
    signal pattern_beats : std_logic_vector(31 downto 0) := (others => '0');
    signal pattern_seed  : std_logic_vector(31 downto 0) := (others => '0');
    signal fill_clocks   : unsigned(31 downto 0) := (others => '0');
    signal answers       : unsigned(31 downto 0) := (others => '0');
    signal errors        : unsigned(15 downto 0) := (others => '0');
    signal last_error    : std_logic_vector(1 downto 0) := "00";
    signal high_water    : natural range 0 to g_fifo_beats + 3 := 0;

    -- the capture side: records paired into beats
    signal half_valid    : boolean := false;
    signal half_data     : std_logic_vector(127 downto 0) := (others => '0');
    signal fifo_write    : boolean := false;
    signal fifo_wdata    : beat_t := (others => '0');
    signal fifo_clear    : boolean := false;
    signal fifo_read     : boolean;
    signal fifo_rdata    : beat_t;
    signal fifo_count    : natural range 0 to g_fifo_beats;

    -- the FIFO's output: up to three beats, q(0) the next; a read issued on
    -- the last clock arrives on this one
    signal q             : beat_array(0 to 2) := (others => (others => '0'));
    signal occupied      : natural range 0 to 3 := 0;
    signal inflight      : boolean := false;

    -- the writer
    signal restarting    : boolean := false;
    signal pattern_start : boolean := false;
    signal pattern_run   : boolean := false;
    signal pattern_left  : natural range 0 to ring_beats := 0;
    signal pattern_word  : unsigned(31 downto 0) := (others => '0');
    signal burst_pattern : boolean := false;     -- the W burst under way
    signal wptr          : natural range 0 to ring_beats - 1 := 0;
    signal aw_pending    : boolean := false;
    signal awaddr        : std_logic_vector(31 downto 0) := (others => '0');
    signal awlen         : std_logic_vector(7 downto 0) := (others => '0');
    signal w_left        : natural range 0 to g_burst_beats := 0;
    signal w_records     : natural range 0 to 2 * g_burst_beats := 0;
    signal in_flight     : natural range 0 to g_max_outstanding := 0;
    type count_array is array (0 to g_max_outstanding) of natural range 0 to 2 * g_burst_beats;
    signal burst_records : count_array := (others => 0);
    signal rq_head, rq_tail : natural range 0 to g_max_outstanding := 0;
    signal written       : unsigned(31 downto 0) := (others => '0');

    signal m   : t_axi256_m2s := c_axi256_m2s_idle;
    signal s   : t_axi256_s2m;
    signal use_f2h : boolean;

    -- channel 0 of a capture record is in bits 127:112: in memory it comes first
    function reorder(r : std_logic_vector(127 downto 0)) return std_logic_vector is
        variable v : std_logic_vector(127 downto 0);
    begin
        for c in 0 to 7 loop
            v(16*c + 15 downto 16*c) := r(127 - 16*c downto 112 - 16*c);
        end loop;
        return v;
    end function;

    function pattern_data(w : unsigned(31 downto 0)) return std_logic_vector is
        variable v : std_logic_vector(255 downto 0);
    begin
        for j in 0 to 7 loop
            v(32*j + 31 downto 32*j) := std_logic_vector(w + j);
        end loop;
        return v;
    end function;

    function b(x : boolean) return std_logic is
    begin
        if x then return '1'; end if;
        return '0';
    end function;

    function n(x : boolean) return natural is
    begin
        if x then return 1; end if;
        return 0;
    end function;

    function next_ring(p : natural; n : natural) return natural is
    begin
        return (p + n) mod ring_beats;
    end function;

begin

    use_f2h <= bus_config(0) = '1';
    s <= f2h_s2m when use_f2h else f2sdram_s2m;
    f2sdram_m2s <= m when not use_f2h else c_axi256_m2s_idle;
    f2h_m2s     <= m when use_f2h else c_axi256_m2s_idle;

    capture_is_full  <= fifo_count >= g_fifo_beats - 1;
    capture_is_ready <= not restarting;
    capture_written  <= written;

    u_fifo : entity work.scope_fifo
        generic map (g_width => 257, g_depth => g_fifo_beats)
        port map (
            clock      => clock,
            clear      => fifo_clear,
            write      => fifo_write,
            write_data => fifo_wdata,
            read       => fifo_read,
            read_data  => fifo_rdata,
            count      => fifo_count,
            is_empty   => open,
            is_full    => open
        );

    -- from registers only: a read when what arrives next clock still fits
    fifo_read <= fifo_count > 0 and occupied + n(inflight) <= 2
                 and not restarting and not fifo_clear;

    -- the AXI manager's outputs
    m.awaddr  <= awaddr;
    m.awlen   <= awlen;
    m.awcache <= bus_config(7 downto 4);
    m.awdomain <= bus_config(9 downto 8);
    m.awprot  <= bus_config(14 downto 12);
    m.awuser  <= bus_config(23 downto 16);
    m.awvalid <= '1' when aw_pending else '0';
    m.wdata   <= pattern_data(pattern_word) when burst_pattern else q(0)(255 downto 0);
    m.wstrb   <= x"0000FFFF" when not burst_pattern and q(0)(256) = '1' else (others => '1');
    m.wlast   <= '1' when w_left = 1 else '0';
    m.wvalid  <= '1' when w_left > 0 and (burst_pattern or occupied > 0) else '0';

    main : process (clock) is
        variable v_q        : beat_array(0 to 2);
        variable v_occupied : natural range 0 to 3;
        variable pop        : boolean;
        variable avail      : natural range 0 to g_fifo_beats + 3;
        variable room       : natural range 1 to g_burst_beats;
        variable len        : natural range 0 to g_burst_beats;
        variable v_in_flight : natural range 0 to g_max_outstanding;
        variable start      : boolean;
    begin
        if rising_edge(clock) then
            init_bus(bus_out);
            fifo_write <= false;
            fifo_clear <= false;

            ------------------------------------------------------------
            -- registers
            connect_data_to_address(bus_in, bus_out, g_base_address + 0, ring_base);
            connect_data_to_address(bus_in, bus_out, g_base_address + 1, bus_config);
            connect_data_to_address(bus_in, bus_out, g_base_address + 3, pattern_beats);
            connect_data_to_address(bus_in, bus_out, g_base_address + 4, pattern_seed);
            if data_is_requested_from_address(bus_in, g_base_address + 2) then
                write_data_to_address(bus_out, 0,
                    std_logic_vector(to_unsigned(high_water, 16))
                    & x"0" & std_logic_vector(to_unsigned(in_flight, 4))
                    & "0000" & b(aw_pending) & b(w_left > 0) & b(restarting) & b(pattern_run));
            end if;
            if data_is_requested_from_address(bus_in, g_base_address + 5) then
                write_data_to_address(bus_out, 0, std_logic_vector(fill_clocks));
            end if;
            if data_is_requested_from_address(bus_in, g_base_address + 6) then
                write_data_to_address(bus_out, 0, std_logic_vector(answers));
            end if;
            if data_is_requested_from_address(bus_in, g_base_address + 7) then
                write_data_to_address(bus_out, 0, x"000" & "00" & last_error & std_logic_vector(errors));
            end if;
            connect_read_only_data_to_address(bus_in, bus_out, g_base_address + 8, g_ring_records);
            connect_read_only_data_to_address(bus_in, bus_out, g_base_address + 9,
                                              g_fifo_beats * 65536 + g_burst_beats);
            if write_to_address_is_requested(bus_in, g_base_address + 2) then
                if bus_in.data(0) = '1' then
                    pattern_start <= true;
                end if;
                if bus_in.data(1) = '1' then
                    answers    <= (others => '0');
                    errors     <= (others => '0');
                    last_error <= "00";
                    fill_clocks <= (others => '0');
                end if;
            end if;

            ------------------------------------------------------------
            -- records in pairs into the FIFO; a lone last one when flushing
            if capture_write and not (fifo_count >= g_fifo_beats - 1) then
                if not half_valid then
                    half_data  <= reorder(capture_data);
                    half_valid <= true;
                else
                    fifo_wdata <= '0' & reorder(capture_data) & half_data;
                    fifo_write <= true;
                    half_valid <= false;
                end if;
            elsif capture_flush and half_valid then
                fifo_wdata <= '1' & x"00000000000000000000000000000000" & half_data;
                fifo_write <= true;
                half_valid <= false;
            end if;

            ------------------------------------------------------------
            -- the FIFO's output stage
            v_q := q;
            v_occupied := occupied;
            pop := w_left > 0 and not burst_pattern and occupied > 0 and s.wready = '1';
            if pop then
                v_q(0) := v_q(1);
                v_q(1) := v_q(2);
                v_occupied := v_occupied - 1;
            end if;
            if inflight then
                v_q(v_occupied) := fifo_rdata;
                v_occupied := v_occupied + 1;
            end if;
            inflight <= fifo_read;

            -- a beat read this clock is still in fifo_count
            avail := fifo_count + v_occupied;
            if avail > high_water then
                high_water <= avail;
            end if;

            ------------------------------------------------------------
            -- the W channel
            if w_left > 0 and s.wready = '1' and (burst_pattern or occupied > 0) then
                w_left <= w_left - 1;
                if burst_pattern then
                    pattern_word <= pattern_word + 8;
                elsif q(0)(256) = '1' then
                    w_records <= w_records + 1;
                else
                    w_records <= w_records + 2;
                end if;
                if w_left = 1 then
                    -- the burst's records, counted when it is answered
                    if burst_pattern then
                        burst_records(rq_tail) <= 0;
                    elsif q(0)(256) = '1' then
                        burst_records(rq_tail) <= w_records + 1;
                    else
                        burst_records(rq_tail) <= w_records + 2;
                    end if;
                    rq_tail <= (rq_tail + 1) mod (g_max_outstanding + 1);
                    w_records <= 0;
                end if;
            end if;

            -- the AW channel
            if aw_pending and s.awready = '1' then
                aw_pending <= false;
            end if;

            -- the B channel (bready is always 1)
            v_in_flight := in_flight;
            if s.bvalid = '1' and in_flight > 0 then
                v_in_flight := v_in_flight - 1;
                answers <= answers + 1;
                if s.bresp /= "00" then
                    errors     <= errors + 1;
                    last_error <= s.bresp;
                end if;
                written <= written + burst_records(rq_head);
                rq_head <= (rq_head + 1) mod (g_max_outstanding + 1);
            end if;

            ------------------------------------------------------------
            -- the next burst: when the last one's address and data are out
            start := false;
            len   := 0;
            room  := g_burst_beats - (wptr mod g_burst_beats);
            if not aw_pending and w_left = 0 and in_flight < g_max_outstanding then
                if pattern_run then
                    if pattern_left > 0 then
                        len := minimum(pattern_left, room);
                        start := true;
                        pattern_left <= pattern_left - len;
                        burst_pattern <= true;
                    end if;
                elsif not restarting then
                    if avail >= room or (capture_flush and avail > 0) then
                        len := minimum(avail, room);
                        start := true;
                        burst_pattern <= false;
                    end if;
                end if;
            end if;
            if start then
                awaddr     <= std_logic_vector(unsigned(std_logic_vector'(ring_base(31 downto 12) & x"000"))
                                               + to_unsigned(wptr * 32, 32));
                awlen      <= std_logic_vector(to_unsigned(len - 1, 8));
                aw_pending <= true;
                w_left     <= len;
                wptr       <= next_ring(wptr, len);
                v_in_flight := v_in_flight + 1;
            end if;
            in_flight <= v_in_flight;

            ------------------------------------------------------------
            -- the pattern fill: starts when nothing else is going on
            if pattern_run then
                fill_clocks <= fill_clocks + 1;
                if pattern_left = 0 and not aw_pending and w_left = 0 and in_flight = 0 then
                    pattern_run <= false;
                end if;
            elsif pattern_start and not restarting and not aw_pending and w_left = 0
                  and in_flight = 0 then
                pattern_start <= false;
                pattern_run   <= true;
                pattern_left  <= minimum(to_integer(unsigned(pattern_beats(23 downto 0))), ring_beats);
                pattern_word  <= unsigned(pattern_seed);
                fill_clocks   <= (others => '0');
                wptr          <= 0;
            end if;

            ------------------------------------------------------------
            -- the capture port restarts: finish what is on the bus, then
            -- empty everything and start again at record 0
            if capture_reset then
                restarting <= true;
            elsif restarting and not aw_pending and w_left = 0 and in_flight = 0
                  and not pattern_run then
                restarting <= false;
                fifo_clear <= true;
                half_valid <= false;
                v_occupied := 0;
                inflight   <= false;
                wptr       <= 0;
                written    <= (others => '0');
                high_water <= 0;
            end if;

            q        <= v_q;
            occupied <= v_occupied;

            if reset = '1' then
                aw_pending  <= false;
                w_left      <= 0;
                in_flight   <= 0;
                rq_head     <= 0;
                rq_tail     <= 0;
                w_records   <= 0;
                pattern_run <= false;
                pattern_start <= false;
                restarting  <= false;
            end if;
        end if;
    end process main;

end architecture rtl;
