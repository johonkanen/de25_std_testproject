------------------------------------------------------------------------
-- max6650_fan_control - drive the DE25-Standard's fan through the on-board
-- MAX6650 fan-speed controller, and report back the measured speed.
--
-- The MAX6650 sits on its own dedicated I2C bus (FPGA_I2C_SCLK PIN_BF120 /
-- FPGA_I2C_SDAT PIN_BH118, 3.3-V LVCMOS - not shared with anything else on
-- this board) at 7-bit address 0x48. Terasic's
-- Demonstration/SoC_FPGA/GHRD/board_management_ip/BOARD_MANAGEMENT.v (and
-- its auto_fan.v) is the reference for the bus, the address, the register
-- map and every register value below - all taken from there, not derived.
--
-- Control mode: closed-loop tachometer regulation (MAX6650's only real
-- mode - unlike the DE25-Nano's AMC6821, there is no open-loop
-- duty-cycle register to fall back on). ktach_in is written straight to
-- the Speed register (0x00): the chip servos the fan's own PWM duty until
-- the measured tach count matches it, no ramping/kick logic needed here -
-- that servo action is the whole point of closed-loop mode. The register
-- is called "ktach" rather than "rpm" because the encoding is the
-- datasheet's, not a linear RPM count - see "Choosing a target" below.
--
-- Register values written, all board-specific bits following Terasic
-- (fan chip only - this driver does not touch the board's separate
-- ADT7461 temperature sensor, which BOARD_MANAGEMENT.v shares the same
-- state machine with but is out of scope here):
--   0x16 Count    = 0x01  0.5 s tach sample window
--   0x02 Config   = 0x0A  intermediate value while ALARM_ENABLE and the
--                         final Config are still being written, so the
--                         chip is never left running under a half-applied
--                         configuration
--   0x08 AlarmEn  = 0x0F  GPIO1/tach-overflow/min-output/max-output alarms
--   0x02 Config   = 0x29  final: closed-loop operation, KSCALE = 2
--   0x04 GPIODef  = 0xF5  GPIO1 = FULL-ON input, GPIO0 = ALERT output
--   0x00 Speed    = ktach_in  the target - written last, and again
--                         whenever ktach_in changes
--
-- Then it polls Tach0Count (0x0C) forever, gap g_poll_cycles apart, for
-- rpm_out - and re-writes Speed whenever ktach_in changes.
--
-- Choosing a target: KTACH = ((992 * KSCALE) / (RPM / 60)) - 1, straight
-- from auto_fan.v's own formula (KSCALE = 2 throughout this module,
-- matching the Config value above - the two must be changed together).
-- g_min_rpm computes the reset value of ktach_in's register at the top
-- level from an RPM figure instead of a raw KTACH one, so the low-speed
-- default has an interpretable unit. 3500 RPM is Terasic's own auto_fan.v
-- curve's minimum (its "Speed8", the quietest point in their validated
-- 3500-6000 RPM ramp) - a vendor-chosen floor, not a soak-tested one the
-- way the DE25-Nano's g_fan_min_duty was measured on real hardware (see
-- docs/de25_nano_fan.md in the sibling project); nothing here has been
-- run on a DE25-Standard yet.
--
-- Fan speed readback: rpm_out = 60 * Tach0Count, straight from
-- BOARD_MANAGEMENT.v's own `assign Fan_Speed = 60 * TACH0` - a plain
-- linear scale (unlike the KTACH encoding above), read as an 8-bit
-- register so rpm_out tops out at 60 * 255 = 15300, comfortably above
-- this board's fan range.
--
-- config_readback is Config (0x02) read back once right after the last
-- configuration write completes - not part of the ongoing poll, just a
-- one-shot "the I2C link is alive and the write landed" check, since the
-- MAX6650 (unlike the AMC6821) has no separate device-ID register to poll
-- for the same purpose.
------------------------------------------------------------------------
--
-- A write the MAX6650 does not acknowledge aborts the transaction with a
-- STOP - never mid-frame, which would wedge the bus - raises i2c_error,
-- and retries the whole configuration after a back-off.
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

    use work.i2c_master_pkg.all;

entity max6650_fan_control is
    generic (
        g_clock_hz    : natural := 50_000_000
        ;g_scl_hz     : natural := 100_000
        -- MAX6650 7-bit address on the DE25-Standard (Terasic uses 0x90 as
        -- the 8-bit write address, i.e. 0x48 << 1).
        ;g_slave_addr : std_logic_vector(6 downto 0) := "1001000"     -- 0x48
        -- fan speed target after reset, in RPM - converted to the KTACH
        -- encoding at elaboration time (see header). Must stay above the
        -- MAX6650's low-speed lock range for KSCALE = 2 to mean anything;
        -- 3500 is Terasic's own auto_fan.v floor, see header.
        ;g_min_rpm    : natural := 3500
        ;g_kscale     : natural := 2
        -- gap between poll cycles
        ;g_poll_cycles : natural := 5_000_000                         -- 100 ms
        -- settling time before the first config, and the back-off after an
        -- I2C error (~100 ms at 50 MHz)
        ;g_por_cycles  : natural := 5_000_000
    );
    port (
        clock            : in  std_logic
        ;reset           : in  std_logic                       -- synchronous, active high
        -- fan speed setpoint: MAX6650 Speed (KTACH) register
        ;ktach_in        : in  std_logic_vector(7 downto 0)
        -- measurements
        ;rpm_out         : out std_logic_vector(15 downto 0)   -- 60 * tach0
        ;tach0_out       : out std_logic_vector(7 downto 0)    -- raw Tach0Count
        ;config_readback : out std_logic_vector(7 downto 0)    -- Config, read once post-init
        ;ktach_out       : out std_logic_vector(7 downto 0)    -- KTACH last programmed
        ;init_done       : out std_logic                       -- config sequence sent
        ;i2c_error       : out std_logic                       -- a write went unacknowledged
        -- open-drain I2C pins
        ;sda_in          : in  std_logic
        ;sda_low         : out std_logic
        ;scl_low         : out std_logic
    );
end entity max6650_fan_control;

architecture rtl of max6650_fan_control is

    function max2 (a, b : natural) return natural is
    begin
        if a > b then return a; else return b; end if;
    end function max2;

    ------------------------------------------------------------------
    -- MAX6650 register addresses
    constant c_reg_speed   : std_logic_vector(7 downto 0) := x"00";
    constant c_reg_config  : std_logic_vector(7 downto 0) := x"02";
    constant c_reg_gpiodef : std_logic_vector(7 downto 0) := x"04";
    constant c_reg_alarmen : std_logic_vector(7 downto 0) := x"08";
    constant c_reg_tach0   : std_logic_vector(7 downto 0) := x"0C";
    constant c_reg_count   : std_logic_vector(7 downto 0) := x"16";

    -- KTACH register value for g_min_rpm, per auto_fan.v's own formula:
    --   ktach = ((992 * kscale) / (rpm / 60)) - 1
    -- (integer division throughout, matching the Verilog reference)
    constant c_ktach_min_rpm : natural :=
        ((992 * g_kscale) / (g_min_rpm / 60)) - 1;

    ------------------------------------------------------------------
    -- the configuration script; Speed is written separately afterwards
    -- (st_write_speed), not as part of this array, since it also gets
    -- re-written later whenever ktach_in changes.
    type t_reg_write is record
        reg  : std_logic_vector(7 downto 0);
        data : std_logic_vector(7 downto 0);
    end record;

    type t_reg_write_array is array (natural range <>) of t_reg_write;

    constant c_config : t_reg_write_array := (
         (c_reg_count,   x"01")
        ,(c_reg_config,  x"0A")
        ,(c_reg_alarmen, x"0F")
        ,(c_reg_config,  x"29")
        ,(c_reg_gpiodef, x"F5")
    );

    ------------------------------------------------------------------
    signal addr_write : std_logic_vector(7 downto 0);
    signal addr_read  : std_logic_vector(7 downto 0);

    ------------------------------------------------------------------
    -- top-level sequencer
    type t_state is (st_por_wait, st_config, st_verify_config,
                     st_write_speed, st_poll, st_poll_wait, st_error_wait);

    signal state : t_state := st_por_wait;

    constant c_delay_max : natural := max2(g_por_cycles, g_poll_cycles);

    signal cfg_index : natural range 0 to c_config'high := 0;
    signal delay     : natural range 0 to c_delay_max   := 0;

    -- the KTACH value currently programmed into the chip, and the target
    signal ktach_target  : std_logic_vector(7 downto 0) := (others => '0');
    signal ktach_written : std_logic_vector(7 downto 0) := (others => '0');

    ------------------------------------------------------------------
    -- one I2C transaction: a register write or a register read
    --   write_reg : START, addr+W, reg, data, STOP
    --   read_reg  : START, addr+W, reg, START, addr+R, read+NACK, STOP
    type t_xact is (xact_idle, xact_write_reg, xact_read_reg);

    -- driven by the sequencer
    signal xact       : t_xact := xact_idle;
    signal xact_start : std_logic := '0';
    signal xact_reg   : std_logic_vector(7 downto 0) := (others => '0');
    signal xact_wdata : std_logic_vector(7 downto 0) := (others => '0');

    -- driven by the transaction sequencer
    signal xact_busy  : std_logic := '0';
    signal xact_done  : std_logic := '0';
    signal xact_err   : std_logic := '0';
    signal xact_abort : std_logic := '0';
    -- set only while the op just issued was a write, so a stale ack_err from
    -- an earlier failure cannot abort the transaction that is retrying
    signal check_ack  : std_logic := '0';
    signal xact_rdata : std_logic_vector(7 downto 0) := (others => '0');
    signal xact_step  : natural range 0 to 7 := 0;

    -- i2c_master handshake
    signal i2c_req      : std_logic := '0';
    signal i2c_op       : t_i2c_op := i2c_op_start;
    signal i2c_wr_data  : std_logic_vector(7 downto 0) := (others => '0');
    signal i2c_read_ack : std_logic := '0';
    signal i2c_busy     : std_logic;
    signal i2c_done     : std_logic;
    signal i2c_rd_data  : std_logic_vector(7 downto 0);
    signal i2c_ack_err  : std_logic;

begin

    addr_write <= g_slave_addr & '0';
    addr_read  <= g_slave_addr & '1';

    ktach_out <= ktach_written;

    -- rpm_out = 60 * tach0_out, a plain multiply - see header
    rpm_out <= std_logic_vector(resize(unsigned(tach0_out) * 60, 16));

------------------------------------------------------------------------
    u_i2c : entity work.i2c_master
    generic map (
        g_clock_hz => g_clock_hz
        ,g_scl_hz  => g_scl_hz
    )
    port map (
        clock     => clock
        ,reset    => reset
        ,req      => i2c_req
        ,op       => i2c_op
        ,wr_data  => i2c_wr_data
        ,read_ack => i2c_read_ack
        ,busy     => i2c_busy
        ,done     => i2c_done
        ,rd_data  => i2c_rd_data
        ,ack_err  => i2c_ack_err
        ,sda_in   => sda_in
        ,sda_low  => sda_low
        ,scl_low  => scl_low
    );

------------------------------------------------------------------------
-- transaction sequencer: expands a register write or read into individual
-- START / WRITE / READ / STOP operations of the i2c_master. A byte the
-- slave does not acknowledge is followed by a STOP so the bus is always
-- released, then the transaction completes with xact_err set.
--
-- (identical to de25_nano_testproject's amc6821_fan_control.vhd - the
-- transaction/byte layer of an I2C register write or read does not depend
-- on which chip is on the other end)
------------------------------------------------------------------------
    transaction : process (clock) is
        variable op_v : t_i2c_op;
    begin
        if rising_edge(clock) then

            i2c_req   <= '0';
            xact_done <= '0';

            if xact_busy = '1' and i2c_busy = '0' and i2c_req = '0' then

                if xact_abort = '1' then
                    -- the STOP that follows a NACK has completed
                    xact_busy  <= '0';
                    xact_done  <= '1';
                    xact_err   <= '1';
                    xact_abort <= '0';
                    xact_step  <= 0;

                elsif check_ack = '1' and i2c_ack_err = '1' then
                    -- the write just issued went unacknowledged: release the
                    -- bus with a STOP before giving up, never mid-frame
                    check_ack  <= '0';
                    xact_abort <= '1';
                    i2c_req    <= '1';
                    i2c_op     <= i2c_op_stop;

                else
                    op_v         := i2c_op_stop;
                    i2c_req      <= '1';
                    i2c_read_ack <= '0';        -- NACK terminates every read

                    case xact is

                        when xact_write_reg =>
                            case xact_step is
                                when 0 => op_v := i2c_op_start;
                                when 1 => op_v := i2c_op_write;
                                          i2c_wr_data <= addr_write;
                                when 2 => op_v := i2c_op_write;
                                          i2c_wr_data <= xact_reg;
                                when 3 => op_v := i2c_op_write;
                                          i2c_wr_data <= xact_wdata;
                                when others => op_v := i2c_op_stop;
                            end case;
                            if xact_step = 4 then
                                xact_busy <= '0';
                                xact_done <= '1';
                                xact_step <= 0;
                            else
                                xact_step <= xact_step + 1;
                            end if;

                        when xact_read_reg =>
                            case xact_step is
                                when 0 => op_v := i2c_op_start;
                                when 1 => op_v := i2c_op_write;
                                          i2c_wr_data <= addr_write;
                                when 2 => op_v := i2c_op_write;
                                          i2c_wr_data <= xact_reg;
                                when 3 => op_v := i2c_op_start;     -- repeated
                                when 4 => op_v := i2c_op_write;
                                          i2c_wr_data <= addr_read;
                                when 5 => op_v := i2c_op_read;
                                when others => op_v := i2c_op_stop;
                            end case;
                            -- step 6 issues the STOP, by which point the read
                            -- op has finished and rd_data holds the byte just
                            -- clocked in. Capturing at step 5 would latch the
                            -- previous transaction's byte.
                            if xact_step = 6 then
                                xact_rdata <= i2c_rd_data;
                            end if;
                            if xact_step = 6 then
                                xact_busy <= '0';
                                xact_done <= '1';
                                xact_step <= 0;
                            else
                                xact_step <= xact_step + 1;
                            end if;

                        when others =>
                            i2c_req   <= '0';
                            xact_busy <= '0';

                    end case;

                    i2c_op <= op_v;
                    -- only a write has an acknowledge worth judging
                    if op_v = i2c_op_write then
                        check_ack <= '1';
                    else
                        check_ack <= '0';
                    end if;
                end if;
            end if;

            -- a new transaction request always wins
            if xact_start = '1' then
                xact_busy  <= '1';
                xact_step  <= 0;
                xact_err   <= '0';
                xact_abort <= '0';
                check_ack  <= '0';
            end if;

            if reset = '1' then
                i2c_req    <= '0';
                xact_done  <= '0';
                xact_busy  <= '0';
                xact_err   <= '0';
                xact_abort <= '0';
                check_ack  <= '0';
                xact_step  <= 0;
            end if;
        end if;
    end process transaction;

------------------------------------------------------------------------
-- top-level sequencer
------------------------------------------------------------------------
    sequencer : process (clock) is

        procedure start_write (reg, data : in std_logic_vector(7 downto 0)) is
        begin
            xact       <= xact_write_reg;
            xact_reg   <= reg;
            xact_wdata <= data;
            xact_start <= '1';
        end procedure start_write;

        procedure start_read (reg : in std_logic_vector(7 downto 0)) is
        begin
            xact       <= xact_read_reg;
            xact_reg   <= reg;
            xact_start <= '1';
        end procedure start_read;

    begin
        if rising_edge(clock) then

            xact_start   <= '0';
            ktach_target <= ktach_in;

            case state is

                -- let the MAX6650 finish its own power-on sequence
                when st_por_wait =>
                    if delay = g_por_cycles then
                        delay     <= 0;
                        cfg_index <= 0;
                        state     <= st_config;
                        start_write(c_config(0).reg, c_config(0).data);
                    else
                        delay <= delay + 1;
                    end if;

                -- walk the configuration script
                when st_config =>
                    if xact_done = '1' then
                        if xact_err = '1' then
                            i2c_error <= '1';
                            delay     <= 0;
                            state     <= st_error_wait;
                        elsif cfg_index = c_config'high then
                            state <= st_verify_config;
                            start_read(c_reg_config);
                        else
                            cfg_index <= cfg_index + 1;
                            start_write(c_config(cfg_index + 1).reg,
                                        c_config(cfg_index + 1).data);
                        end if;
                    end if;

                -- one-shot readback of Config right after the last
                -- configuration write - confirms the link works (see
                -- header). Not repeated afterwards.
                when st_verify_config =>
                    if xact_done = '1' then
                        if xact_err = '1' then
                            i2c_error <= '1';
                            delay     <= 0;
                            state     <= st_error_wait;
                        else
                            config_readback <= xact_rdata;
                            init_done       <= '1';
                            state           <= st_write_speed;
                            start_write(c_reg_speed, ktach_target);
                        end if;
                    end if;

                -- a Speed write finished
                when st_write_speed =>
                    if xact_done = '1' then
                        if xact_err = '1' then
                            i2c_error <= '1';
                            delay     <= 0;
                            state     <= st_error_wait;
                        else
                            ktach_written <= xact_wdata;
                            delay         <= 0;
                            state         <= st_poll;
                            start_read(c_reg_tach0);
                        end if;
                    end if;

                -- read back the measured tach count
                when st_poll =>
                    if xact_done = '1' then
                        if xact_err = '1' then
                            i2c_error <= '1';
                            delay     <= 0;
                            state     <= st_error_wait;
                        else
                            tach0_out <= xact_rdata;
                            delay     <= 0;
                            state     <= st_poll_wait;
                        end if;
                    end if;

                -- idle between poll cycles; a new setpoint pre-empts the wait
                when st_poll_wait =>
                    if ktach_target /= ktach_written then
                        state <= st_write_speed;
                        start_write(c_reg_speed, ktach_target);
                    elsif delay = g_poll_cycles then
                        delay <= 0;
                        state <= st_poll;
                        start_read(c_reg_tach0);
                    else
                        delay <= delay + 1;
                    end if;

                -- back off, then reconfigure from scratch.
                when st_error_wait =>
                    if delay = g_por_cycles then
                        delay     <= 0;
                        init_done <= '0';
                        cfg_index <= 0;
                        state     <= st_config;
                        start_write(c_config(0).reg, c_config(0).data);
                    else
                        delay <= delay + 1;
                    end if;

            end case;

            if reset = '1' then
                state           <= st_por_wait;
                delay           <= 0;
                cfg_index       <= 0;
                xact            <= xact_idle;
                xact_start      <= '0';
                init_done       <= '0';
                i2c_error       <= '0';
                config_readback <= (others => '0');
                tach0_out       <= (others => '0');
                ktach_written   <= (others => '0');
            end if;
        end if;
    end process sequencer;

end architecture rtl;
