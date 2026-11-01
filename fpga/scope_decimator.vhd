------------------------------------------------------------------------
-- scope_decimator - the data logger's decimation (docs/plan_scope.md,
-- phase 4): between scope_capture's deep capture port and the DDR writer.
-- Enabled, it takes every record the scope sends (every sample of a
-- continuous deep capture, up to 50 MS/s) and sends one point per
-- g_n samples instead: four records,
--
--   record 4p      each channel's minimum over the point's samples
--   record 4p + 1  each channel's maximum
--   record 4p + 2  each channel's mean, the sum divided by n, rounded to
--                  nearest (halves away from zero)
--   record 4p + 3  the point's number since the restart (channels 0, 1: bits
--                  31:16, 15:0), the points lost before it (channels 2, 3),
--                  n (channels 4, 5), channels 6 and 7 zero
--
-- so 64 bytes a point in the ring, two whole beats of the DDR writer (which
-- writes out whole beats that wait, so a slow log's points come out). A digital channel's (bit lanes) minimum
-- is the AND of its samples, its maximum the OR (a bit that was ever 0, ever
-- 1), and its "mean" its last sample. Disabled, records pass straight
-- through. Only for continuous deep captures: a single deep capture's end
-- (capture_flush) waits for as many records written as it sent, which
-- decimated never comes.
--
-- The means come from eight dividers working in parallel after each point
-- (sum_bits clocks), then the four records go out on four clocks; n
-- must leave them the time: at least 64 samples. A point goes to the writer
-- whole or not at all (out_almost_full: no room for four records); a point
-- it has no room for, or one finished while the last is still going out, is
-- lost and counted, and the ring stays in whole points (record 4p is always
-- a minimum); a point's number says where points are missing.
--
-- register map, offsets from g_base_address
--   0  RW bit 0 decimate
--   1  RW n: samples a point, 64 .. 2**26 (reads back limited)
--   2  RW formats: 2 bits a channel, channel 0 in bits 1:0 - 0 signed,
--         1 unsigned, 2 digital
--   3  R  points sent since the capture port's last restart
--   4  R  points lost (the writer full) since then
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use work.fpga_interconnect_pkg.all;

entity scope_decimator is
    generic (
        g_base_address : natural
    );
    port (
        clock   : in  std_logic;
        bus_in  : in  fpga_interconnect_record;
        bus_out : out fpga_interconnect_record;

        -- from scope_capture
        in_reset    : in  boolean;
        in_write    : in  boolean;
        in_data     : in  std_logic_vector(127 downto 0);
        in_flush    : in  boolean;
        in_is_full  : out boolean;
        -- to the DDR writer
        out_reset   : out boolean;
        out_write   : out boolean;
        out_data    : out std_logic_vector(127 downto 0);
        out_flush   : out boolean;
        out_is_full : in  boolean;          -- the writer's capture_is_full (passed through)
        out_almost_full : in boolean        -- its capture_almost_full: no room for a point
    );
end entity scope_decimator;

architecture rtl of scope_decimator is

    constant channels : natural := 8;
    constant n_bits   : natural := 26;
    constant sum_bits : natural := 16 + n_bits + 1;   -- signed, never overflows
    constant n_min    : natural := 64;

    type sample_array is array (0 to channels - 1) of signed(16 downto 0);   -- 17 bits: unsigned fits
    type slv16_array  is array (0 to channels - 1) of std_logic_vector(15 downto 0);
    type sum_array    is array (0 to channels - 1) of signed(sum_bits - 1 downto 0);
    type mag_array    is array (0 to channels - 1) of unsigned(sum_bits - 1 downto 0);

    signal enable   : std_logic_vector(31 downto 0) := (others => '0');
    signal n_reg    : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(1000, 32));
    signal formats  : std_logic_vector(31 downto 0) := (others => '0');
    signal points   : unsigned(31 downto 0) := (others => '0');
    signal lost     : unsigned(31 downto 0) := (others => '0');
    signal numbered : unsigned(31 downto 0) := (others => '0');   -- points finished, sent or lost

    -- the point being gathered
    signal count    : natural range 0 to 2**n_bits := 0;
    signal mins, maxs : sample_array := (others => (others => '0'));
    signal sums     : sum_array := (others => (others => '0'));
    signal ands, ors, lasts : slv16_array := (others => (others => '0'));

    -- the point being finished: its dividers, then its four records
    signal busy     : boolean := false;
    signal step     : natural range 0 to sum_bits + 4 := 0;
    signal p_number : unsigned(31 downto 0) := (others => '0');
    signal p_n      : unsigned(31 downto 0) := (others => '0');
    signal p_min, p_max, p_last : slv16_array := (others => (others => '0'));
    signal p_neg    : std_logic_vector(channels - 1 downto 0) := (others => '0');
    signal dividend : mag_array := (others => (others => '0'));    -- becomes the quotient
    signal remainder : mag_array := (others => (others => '0'));
    signal divisor  : unsigned(sum_bits - 1 downto 0) := (others => '0');
    signal p_formats : std_logic_vector(15 downto 0) := (others => '0');

    signal is_on    : boolean;
    signal n        : natural range n_min to 2**n_bits;

    function fmt(f : std_logic_vector(15 downto 0); c : natural) return natural is
    begin
        return to_integer(unsigned(f(2*c + 1 downto 2*c)));
    end function;

    -- channel c of a capture record (channel 0 in bits 127:112) as a number
    function value(r : std_logic_vector(127 downto 0); c : natural; unsigned_format : boolean)
        return signed is
        constant v : std_logic_vector(15 downto 0) := r(127 - 16*c downto 112 - 16*c);
    begin
        if unsigned_format then
            return signed('0' & v);
        end if;
        return resize(signed(v), 17);
    end function;

    function bits(r : std_logic_vector(127 downto 0); c : natural) return std_logic_vector is
    begin
        return r(127 - 16*c downto 112 - 16*c);
    end function;

begin

    is_on <= enable(0) = '1';
    n <= n_min when unsigned(n_reg) < n_min else
         2**n_bits when unsigned(n_reg) > 2**n_bits else
         to_integer(unsigned(n_reg));

    in_is_full <= out_is_full when not is_on else false;
    out_reset  <= in_reset;
    out_flush  <= in_flush;

    main : process (clock) is
        variable x       : signed(16 downto 0);
        variable fresh   : boolean;
        variable trial   : unsigned(sum_bits downto 0);
        variable rem_v   : unsigned(sum_bits - 1 downto 0);
        variable rec     : std_logic_vector(127 downto 0);
        variable q       : unsigned(sum_bits - 1 downto 0);
        variable mean    : signed(sum_bits - 1 downto 0);
    begin
        if rising_edge(clock) then
            init_bus(bus_out);
            connect_data_to_address(bus_in, bus_out, g_base_address + 0, enable);
            connect_data_to_address(bus_in, bus_out, g_base_address + 2, formats);
            if write_to_address_is_requested(bus_in, g_base_address + 1) then
                n_reg <= bus_in.data;
            end if;
            if data_is_requested_from_address(bus_in, g_base_address + 1) then
                write_data_to_address(bus_out, 0, std_logic_vector(to_unsigned(n, 32)));
            end if;
            if data_is_requested_from_address(bus_in, g_base_address + 3) then
                write_data_to_address(bus_out, 0, std_logic_vector(points));
            end if;
            if data_is_requested_from_address(bus_in, g_base_address + 4) then
                write_data_to_address(bus_out, 0, std_logic_vector(lost));
            end if;

            out_write <= false;
            if not is_on then
                out_write <= in_write;
                out_data  <= in_data;
            end if;

            ------------------------------------------------------------
            -- gather: a sample into the point
            if is_on and in_write then
                fresh := count = 0;
                for c in 0 to channels - 1 loop
                    x := value(in_data, c, fmt(formats(15 downto 0), c) /= 0);
                    if fresh or x < mins(c) then
                        mins(c) <= x;
                    end if;
                    if fresh or x > maxs(c) then
                        maxs(c) <= x;
                    end if;
                    if fresh then
                        sums(c) <= resize(x, sum_bits);
                        ands(c) <= bits(in_data, c);
                        ors(c)  <= bits(in_data, c);
                    else
                        sums(c) <= sums(c) + x;
                        ands(c) <= ands(c) and bits(in_data, c);
                        ors(c)  <= ors(c) or bits(in_data, c);
                    end if;
                    lasts(c) <= bits(in_data, c);
                end loop;
                if count + 1 >= n and busy then
                    count <= 0;
                    lost  <= lost + 1;              -- the last one is still going out
                    numbered <= numbered + 1;
                elsif count + 1 >= n then
                    count <= 0;
                    numbered  <= numbered + 1;
                    p_number  <= numbered;
                    p_n       <= to_unsigned(n, 32);
                    -- the point complete: hand it on (the last sample included)
                    busy      <= true;
                    step      <= 0;
                    divisor   <= to_unsigned(n, sum_bits);
                    p_formats <= formats(15 downto 0);
                    for c in 0 to channels - 1 loop
                        x := value(in_data, c, fmt(formats(15 downto 0), c) /= 0);
                        if fmt(formats(15 downto 0), c) = 2 then
                            p_min(c) <= (ands(c) and bits(in_data, c));
                            p_max(c) <= (ors(c) or bits(in_data, c));
                        else
                            if x < mins(c) then
                                p_min(c) <= std_logic_vector(x(15 downto 0));
                            else
                                p_min(c) <= std_logic_vector(mins(c)(15 downto 0));
                            end if;
                            if x > maxs(c) then
                                p_max(c) <= std_logic_vector(x(15 downto 0));
                            else
                                p_max(c) <= std_logic_vector(maxs(c)(15 downto 0));
                            end if;
                        end if;
                        p_last(c) <= bits(in_data, c);
                        -- |sum| + n/2, divided below: rounded to nearest
                        mean := sums(c) + x;
                        if mean < 0 then
                            p_neg(c) <= '1';
                            dividend(c) <= unsigned(-mean) + to_unsigned(n / 2, sum_bits);
                        else
                            p_neg(c) <= '0';
                            dividend(c) <= unsigned(mean) + to_unsigned(n / 2, sum_bits);
                        end if;
                        remainder(c) <= (others => '0');
                    end loop;
                else
                    count <= count + 1;
                end if;
            end if;

            ------------------------------------------------------------
            -- finish a point: sum_bits steps of restoring division, then
            -- the four records
            if busy then
                if step < sum_bits then
                    for c in 0 to channels - 1 loop
                        trial := (remainder(c) & dividend(c)(sum_bits - 1)) - ('0' & divisor);
                        if trial(sum_bits) = '0' then                      -- fits
                            rem_v := trial(sum_bits - 1 downto 0);
                            dividend(c) <= dividend(c)(sum_bits - 2 downto 0) & '1';
                        else
                            rem_v := remainder(c)(sum_bits - 2 downto 0) & dividend(c)(sum_bits - 1);
                            dividend(c) <= dividend(c)(sum_bits - 2 downto 0) & '0';
                        end if;
                        remainder(c) <= rem_v;
                    end loop;
                    step <= step + 1;
                else
                    if step = sum_bits and out_almost_full then
                        lost <= lost + 1;           -- all four records or none
                        busy <= false;
                    else
                        for c in 0 to channels - 1 loop
                            CASE step - sum_bits is
                                WHEN 0      => rec(127 - 16*c downto 112 - 16*c) := p_min(c);
                                WHEN 1      => rec(127 - 16*c downto 112 - 16*c) := p_max(c);
                                WHEN 3      => null;
                                WHEN others =>
                                    if fmt(p_formats, c) = 2 then
                                        rec(127 - 16*c downto 112 - 16*c) := p_last(c);
                                    else
                                        q := dividend(c);
                                        if p_neg(c) = '1' then
                                            mean := -signed(q);
                                        else
                                            mean := signed(q);
                                        end if;
                                        rec(127 - 16*c downto 112 - 16*c) := std_logic_vector(mean(15 downto 0));
                                    end if;
                            end CASE;
                        end loop;
                        if step = sum_bits + 3 then
                            rec := std_logic_vector(p_number) & std_logic_vector(lost)
                                   & std_logic_vector(p_n) & x"00000000";
                        end if;
                        out_write <= true;
                        out_data  <= rec;
                        if step = sum_bits + 3 then
                            busy   <= false;
                            points <= points + 1;
                        else
                            step <= step + 1;
                        end if;
                    end if;
                end if;
            end if;

            if in_reset then
                count  <= 0;
                busy   <= false;
                points <= (others => '0');
                lost   <= (others => '0');
                numbered <= (others => '0');
            end if;
        end if;
    end process main;

end architecture rtl;
