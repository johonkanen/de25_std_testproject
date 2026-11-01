------------------------------------------------------------------------
-- tla2518_reader - the board's TI TLA2518 (8-channel 12-bit SAR ADC,
-- 1 MS/s, on the 2x5 header J18) read continuously by the fabric
-- (docs/plan_scope.md, phase 5).
--
-- After a restart (reset, or a write of the control register) it waits
-- 5 ms (the ADC's power-up), resets the ADC (RST), waits 5 ms, appends the
-- 4-bit channel ID to every result (DATA_CFG; FIX_PAT too when asked),
-- calibrates the offset (CAL) and waits 5 ms, writes the channel mask to
-- AUTO_SEQ_CH_SEL and starts the sequencer (SEQUENCE_CFG: auto-sequence,
-- SEQ_START). From then on it reads frame after frame, 16 bits each: 12 bits
-- of result and the channel ID. Each conversion starts at CS's rising edge
-- and takes 600 ns (tCONV), so CS stays high g_cs_high clocks between
-- frames. The channel sequencer goes through the mask in ascending order;
-- a frame whose ID is not the next one expected counts as an error.
--
-- SPI-00 (the ADC's power-up mode): SCLK low at CS's falling edge, SDI set
-- on falling edges and taken by the ADC on rising ones. SDO is launched by
-- the ADC on SCLK's falling edge (its MSB at CS's falling edge) and is
-- taken here at the next falling edge, a whole SCLK period later: at 25
-- MHz that leaves 40 ns for SCLK out, the ADC's 16 ns (tD_CKDO) and SDO
-- back. SCLK, CS and SDI leave from I/O registers and SDO is taken in one
-- (build_de25_soc.tcl), so the FPGA's part of that is a few ns.
--
-- With the defaults (SCLK 25 MHz, 32 clocks CS high) a conversion takes 66
-- clocks of 50 MHz: 758 kS/s in all, 94.7 kS/s a channel with all eight.
--
-- register map, offsets from g_base_address
--   0  RW control; a write restarts. Reset 0x2001FF05:
--         bit 0 run, bit 1 fixed pattern (the ADC sends 0xA5A5 for every
--         frame, no channel ID: a link test; the results are 0xA5A, the
--         channels taken in the sequencer's order), bit 2 calibrate the offset at the start,
--         bits 15:8 channel mask (bit n: AINn), bits 19:16 SCLK half period
--         in clocks (1..15; 1 = 25 MHz), bits 31:24 clocks CS high between
--         frames (at least 31 = 620 ns)
--   1  R  status: bits 2:0 state (0 stopped, 1 waiting, 2 setting up, 3
--         converting, 4 a register access), bit 3 a register access
--         waiting, bits 15:8 the last register read
--   2  R  conversions since the start (frames with the expected ID)
--   3  R  frames with an unexpected channel ID since the start (in the
--         fixed pattern: frames not 0xA5A5)
--   4  W  a register of the ADC, only while stopped (run 0): bit 16 read
--         (else write), bits 15:8 the address, bits 7:0 the data; the
--         read's answer is in status bits 15:8
--   5..12  R  AIN0..AIN7: bits 11:0 the last result, bits 31:16 its
--         conversions (wrapping)
--   13 R  scans: times the highest channel of the mask was read
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use work.fpga_interconnect_pkg.all;

entity tla2518_reader is
    generic (
        g_base_address : natural;
        g_wait_clocks  : positive := 250_000      -- 5 ms at 50 MHz: power-up, RST, CAL
    );
    port (
        clock   : in  std_logic;
        reset   : in  std_logic;
        bus_in  : in  fpga_interconnect_record;
        bus_out : out fpga_interconnect_record;

        adc_sclk : out std_logic;
        adc_cs_n : out std_logic;
        adc_sdi  : out std_logic;
        adc_sdo  : in  std_logic;

        -- AINn's last result in bits 12n+11 .. 12n
        values    : out std_logic_vector(95 downto 0);
        converted : out boolean;                     -- one clock: a new result
        channel   : out natural range 0 to 7;       -- its channel
        scanned   : out boolean                      -- one clock: the mask's highest channel
    );
end entity tla2518_reader;

architecture rtl of tla2518_reader is

    constant c_control_reset : std_logic_vector(31 downto 0) := x"2001FF05";
    constant c_cs_high_min   : natural := 31;

    constant OP_READ  : std_logic_vector(7 downto 0) := x"10";
    constant OP_WRITE : std_logic_vector(7 downto 0) := x"08";

    type states is (stopped, waiting, setting_up, converting, register_access);
    signal state : states := stopped;
    signal step  : natural range 0 to 7 := 0;     -- the set-up's steps
    signal wait_count : natural range 0 to g_wait_clocks := 0;

    signal control  : std_logic_vector(31 downto 0) := c_control_reset;
    signal restart  : boolean := true;
    signal access_word    : std_logic_vector(31 downto 0) := (others => '0');
    signal access_pending : boolean := false;
    signal access_read    : boolean := false;
    signal access_second  : boolean := false;     -- a read's second frame
    signal second_due     : boolean := false;     -- ... to be sent once the engine is idle
    signal read_value     : std_logic_vector(7 downto 0) := (others => '0');

    signal conversions : unsigned(31 downto 0) := (others => '0');
    signal id_errors   : unsigned(31 downto 0) := (others => '0');
    signal scans       : unsigned(31 downto 0) := (others => '0');
    type count_array is array (0 to 7) of unsigned(15 downto 0);
    signal counts : count_array := (others => (others => '0'));
    signal results : std_logic_vector(95 downto 0) := (others => '0');
    signal skip     : natural range 0 to 3 := 0;    -- frames after SEQ_START not used
    signal expected : natural range 0 to 7 := 0;
    signal synced   : boolean := false;

    -- the frame engine
    type frame_states is (idle, setup, high, low, finish, gap);
    signal frame : frame_states := idle;
    signal f_start  : boolean := false;
    signal f_bits   : natural range 1 to 24 := 16;
    signal f_left   : natural range 0 to 24 := 0;
    signal f_tx     : std_logic_vector(23 downto 0) := (others => '0');
    signal f_rx     : std_logic_vector(23 downto 0) := (others => '0');
    signal f_count  : natural range 0 to 255 := 0;
    signal f_done   : boolean := false;               -- one clock: f_rx holds the frame

    signal sclk, sdi : std_logic := '0';
    signal cs_n      : std_logic := '1';
    -- SDO in an I/O register (build_de25_soc.tcl: FAST_INPUT_REGISTER), taken
    -- into f_rx a clock later: sampled at the very edge that sends SCLK low
    signal sdo_reg : std_logic := '0';
    signal take    : boolean := false;

    function run(c : std_logic_vector) return boolean is
    begin
        return c(0) = '1';
    end function;

    function half(c : std_logic_vector) return natural is
    begin
        if unsigned(c(19 downto 16)) = 0 then
            return 1;
        end if;
        return to_integer(unsigned(c(19 downto 16)));
    end function;

    function cs_high(c : std_logic_vector) return natural is
    begin
        if unsigned(c(31 downto 24)) < c_cs_high_min then
            return c_cs_high_min;
        end if;
        return to_integer(unsigned(c(31 downto 24)));
    end function;

    -- the next channel of the mask after c (ascending, wrapping)
    function next_channel(mask : std_logic_vector(7 downto 0); c : natural) return natural is
        variable k : natural;
    begin
        for i in 1 to 8 loop
            k := (c + i) mod 8;
            if mask(k) = '1' then
                return k;
            end if;
        end loop;
        return c;
    end function;

    function lowest(mask : std_logic_vector(7 downto 0)) return natural is
    begin
        for k in 0 to 7 loop
            if mask(k) = '1' then
                return k;
            end if;
        end loop;
        return 0;
    end function;

    function highest(mask : std_logic_vector(7 downto 0)) return natural is
    begin
        for k in 7 downto 0 loop
            if mask(k) = '1' then
                return k;
            end if;
        end loop;
        return 0;
    end function;

begin

    adc_sclk <= sclk;
    adc_cs_n <= cs_n;
    adc_sdi  <= sdi;
    values   <= results;

    main : process (clock) is
        variable id   : natural range 0 to 15;
        variable mask : std_logic_vector(7 downto 0);
        variable pend : std_logic;

        procedure send(bits : natural; tx : std_logic_vector(23 downto 0)) is
        begin
            f_start <= true;
            f_bits  <= bits;
            f_tx    <= tx;
        end procedure;
    begin
        if rising_edge(clock) then
            init_bus(bus_out);
            connect_read_only_data_to_address(bus_in, bus_out, g_base_address + 0, control);
            if write_to_address_is_requested(bus_in, g_base_address + 0) then
                control <= bus_in.data;
                restart <= true;
            end if;
            if write_to_address_is_requested(bus_in, g_base_address + 4) then
                access_word    <= bus_in.data;
                access_pending <= true;
            end if;
            if data_is_requested_from_address(bus_in, g_base_address + 1) then
                pend := '0';
                if access_pending then
                    pend := '1';
                end if;
                write_data_to_address(bus_out, 0,
                    x"0000" & read_value & "0000" & pend
                    & std_logic_vector(to_unsigned(states'pos(state), 3)));
            end if;
            connect_read_only_data_to_address(bus_in, bus_out, g_base_address + 2, std_logic_vector(conversions));
            connect_read_only_data_to_address(bus_in, bus_out, g_base_address + 3, std_logic_vector(id_errors));
            for c in 0 to 7 loop
                connect_read_only_data_to_address(bus_in, bus_out, g_base_address + 5 + c,
                    std_logic_vector(counts(c)) & x"0" & results(12*c + 11 downto 12*c));
            end loop;
            connect_read_only_data_to_address(bus_in, bus_out, g_base_address + 13, std_logic_vector(scans));

            ------------------------------------------------------------
            -- the frame engine: CS low, f_bits bits, CS high for the gap
            f_done  <= false;
            sdo_reg <= adc_sdo;
            take    <= false;
            if take then
                f_rx <= f_rx(22 downto 0) & sdo_reg;
            end if;
            f_start <= false;
            CASE frame is
                WHEN idle =>
                    cs_n <= '1';
                    sclk <= '0';
                    if f_start then
                        cs_n    <= '0';
                        sdi     <= f_tx(f_bits - 1);
                        f_tx    <= std_logic_vector(shift_left(unsigned(f_tx), 24 - f_bits + 1));
                        f_left  <= f_bits;
                        f_count <= 1;
                        frame   <= setup;
                    end if;
                WHEN setup =>                               -- CS low, SCLK low: half a period
                    if f_count >= half(control) then
                        sclk    <= '1';
                        f_count <= 1;
                        frame   <= high;
                    else
                        f_count <= f_count + 1;
                    end if;
                WHEN high =>
                    if f_count >= half(control) then
                        sclk    <= '0';
                        -- the bit the ADC launched at the last falling edge (or CS)
                        take    <= true;
                        sdi     <= f_tx(23);
                        f_tx    <= f_tx(22 downto 0) & '0';
                        f_left  <= f_left - 1;
                        f_count <= 1;
                        if f_left = 1 then
                            frame <= finish;
                        else
                            frame <= low;
                        end if;
                    else
                        f_count <= f_count + 1;
                    end if;
                WHEN low =>
                    if f_count >= half(control) then
                        sclk    <= '1';
                        f_count <= 1;
                        frame   <= high;
                    else
                        f_count <= f_count + 1;
                    end if;
                WHEN finish =>                              -- SCLK low a half period, then CS up
                    if f_count >= half(control) then
                        cs_n    <= '1';
                        sdi     <= '0';
                        f_done  <= true;
                        f_count <= 1;
                        frame   <= gap;
                    else
                        f_count <= f_count + 1;
                    end if;
                WHEN gap =>                                 -- the conversion: tCONV
                    if f_count >= cs_high(control) then
                        frame <= idle;
                    else
                        f_count <= f_count + 1;
                    end if;
            end CASE;

            ------------------------------------------------------------
            converted <= false;
            scanned   <= false;
            mask := control(15 downto 8);
            CASE state is
                WHEN stopped =>
                    if access_pending and frame = idle and not f_start then
                        access_pending <= false;
                        access_read    <= access_word(16) = '1';
                        access_second  <= false;
                        if access_word(16) = '1' then
                            send(24, OP_READ & access_word(15 downto 8) & x"00");
                        else
                            send(24, OP_WRITE & access_word(15 downto 8) & access_word(7 downto 0));
                        end if;
                        state <= register_access;
                    end if;

                WHEN register_access =>
                    if second_due and frame = idle and not f_start then
                        second_due <= false;
                        send(24, x"000000");                -- the answer comes in this frame
                    end if;
                    if f_done then
                        if access_read and not access_second then
                            access_second <= true;
                            second_due    <= true;
                        else
                            if access_read then
                                read_value <= f_rx(23 downto 16);
                            end if;
                            state <= stopped;
                        end if;
                    end if;

                WHEN waiting =>
                    if wait_count >= g_wait_clocks then
                        state <= setting_up;
                    else
                        wait_count <= wait_count + 1;
                    end if;

                WHEN setting_up =>
                    if frame = idle and not f_start then
                        wait_count <= 0;
                        step <= step + 1;
                        CASE step is
                            WHEN 0 =>
                                send(24, OP_WRITE & x"01" & x"01");            -- GENERAL_CFG: RST
                                state <= waiting;
                            WHEN 1 =>
                                send(24, OP_WRITE & x"02" & control(1) & "0010000");   -- DATA_CFG: FIX_PAT, channel ID
                            WHEN 2 =>
                                if control(2) = '1' then
                                    send(24, OP_WRITE & x"01" & x"02");        -- GENERAL_CFG: CAL
                                    state <= waiting;
                                end if;
                            WHEN 3 =>
                                send(24, OP_WRITE & x"12" & mask);             -- AUTO_SEQ_CH_SEL
                            WHEN others =>
                                send(24, OP_WRITE & x"10" & x"11");            -- SEQUENCE_CFG: auto, SEQ_START
                                skip     <= 2;
                                synced   <= false;
                                expected <= lowest(mask);
                                state  <= converting;
                        end CASE;
                    end if;

                WHEN converting =>
                    if frame = idle and not f_start then
                        send(16, x"000000");
                    end if;
                    if f_done and skip > 0 then
                        skip <= skip - 1;
                    elsif f_done and control(1) = '1' then
                        -- the fixed pattern: the whole frame is 0xA5A5, no channel
                        -- ID; the channels in the sequencer's order
                        id := expected;
                        expected <= next_channel(mask, expected);
                        if f_rx(15 downto 0) /= x"A5A5" then
                            id_errors <= id_errors + 1;
                        else
                            results(12*id + 11 downto 12*id) <= f_rx(15 downto 4);
                            counts(id)  <= counts(id) + 1;
                            conversions <= conversions + 1;
                            converted   <= true;
                            channel     <= id;
                            if id = highest(mask) then
                                scans   <= scans + 1;
                                scanned <= true;
                            end if;
                        end if;
                    elsif f_done then
                        id := to_integer(unsigned(f_rx(3 downto 0)));
                        if id > 7 or mask(id mod 8) = '0' or (synced and id /= expected) then
                            id_errors <= id_errors + 1;
                            synced    <= false;
                        else
                            synced      <= true;
                            expected    <= next_channel(mask, id);
                            results(12*id + 11 downto 12*id) <= f_rx(15 downto 4);
                            counts(id)  <= counts(id) + 1;
                            conversions <= conversions + 1;
                            converted   <= true;
                            channel     <= id;
                            if id = highest(mask) then
                                scans   <= scans + 1;
                                scanned <= true;
                            end if;
                        end if;
                    end if;
            end CASE;

            if restart then
                restart <= false;
                state   <= stopped;
                if run(control) then
                    state      <= waiting;
                    step       <= 0;
                    wait_count <= 0;
                end if;
                conversions <= (others => '0');
                id_errors   <= (others => '0');
                scans       <= (others => '0');
                counts      <= (others => (others => '0'));
            end if;

            if reset = '1' then
                control <= c_control_reset;
                restart <= true;
                access_pending <= false;
            end if;
        end if;
    end process main;

end architecture rtl;
