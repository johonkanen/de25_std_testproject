------------------------------------------------------------------------
-- i2c_master_pkg / i2c_master - minimal byte-level I2C (SMBus) master.
--
-- Open-drain by construction: the entity never drives a line high, it only
-- asserts sda_low / scl_low to pull a line down. Tri-state the actual pads
-- at the top level:
--
--     FPGA_I2C_SDAT <= '0' when sda_low = '1' else 'Z';
--     FPGA_I2C_SCLK <= '0' when scl_low = '1' else 'Z';
--     sda_in        <= FPGA_I2C_SDAT;
--
-- One operation per request. Pulse req with op set, wait for done:
--
--     i2c_op_start : issue (repeated) START
--     i2c_op_write : shift out wr_data (MSB first), sample the slave ACK
--                    into ack_err ('1' = the slave did not acknowledge)
--     i2c_op_read  : shift in 8 bits to rd_data, then drive ACK if read_ack
--                    is '1', or NACK if it is '0' (NACK ends a read)
--     i2c_op_stop  : issue STOP and return to idle
--
-- Four quarter-bit phases per SCL period, so SCL is a symmetric square wave
-- at g_scl_hz. Clock stretching by the slave is not handled - the MAX6650
-- does not stretch.
--
-- Vendored unchanged from de25_nano_testproject's source/fan_control/ (same
-- author) - board-agnostic, no de25_nano- or AMC6821-specific content.
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;

package i2c_master_pkg is

    subtype t_i2c_op is std_logic_vector(1 downto 0);

    constant i2c_op_start : t_i2c_op := "00";
    constant i2c_op_write : t_i2c_op := "01";
    constant i2c_op_read  : t_i2c_op := "10";
    constant i2c_op_stop  : t_i2c_op := "11";

end package i2c_master_pkg;

------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

    use work.i2c_master_pkg.all;

entity i2c_master is
    generic (
        g_clock_hz : natural := 50_000_000
        ;g_scl_hz  : natural := 100_000
    );
    port (
        clock     : in  std_logic
        ;reset    : in  std_logic                      -- synchronous, active high
        -- command interface
        ;req      : in  std_logic                      -- pulse high for one op
        ;op       : in  t_i2c_op
        ;wr_data  : in  std_logic_vector(7 downto 0)
        ;read_ack : in  std_logic                      -- '1' = ACK after read
        ;busy     : out std_logic
        ;done     : out std_logic                      -- one-cycle pulse
        ;rd_data  : out std_logic_vector(7 downto 0)
        ;ack_err  : out std_logic                      -- latched per write op
        -- open-drain pins
        ;sda_in   : in  std_logic
        ;sda_low  : out std_logic
        ;scl_low  : out std_logic
    );
end entity i2c_master;

architecture rtl of i2c_master is

    -- one quarter of an SCL period, in core-clock cycles
    constant c_quarter : natural := g_clock_hz / (g_scl_hz * 4);

    type t_state is (st_idle, st_start, st_stop, st_write, st_write_ack,
                     st_read, st_read_ack, st_done);

    signal state : t_state := st_idle;

    signal phase     : natural range 0 to 3 := 0;   -- quarter within a bit
    signal tick      : natural range 0 to c_quarter - 1 := 0;
    signal bit_index : natural range 0 to 7 := 7;

    signal shift_out : std_logic_vector(7 downto 0) := (others => '1');
    signal shift_in  : std_logic_vector(7 downto 0) := (others => '0');

    -- lines are active-low pulls: '1' here means "pull the line to 0"
    signal sda_pull : std_logic := '0';
    signal scl_pull : std_logic := '0';

    signal ack_err_i : std_logic := '0';
    signal done_i    : std_logic := '0';

    -- synchronise the incoming SDA before sampling it
    signal sda_meta, sda_sync : std_logic := '1';

begin

    busy    <= '0' when state = st_idle else '1';
    done    <= done_i;
    rd_data <= shift_in;
    ack_err <= ack_err_i;
    sda_low <= sda_pull;
    scl_low <= scl_pull;

    -- Resolve the sampled line to a clean 0/1 on the way in. A released
    -- open-drain line reads as the pull-up, which is '1' on a pin but 'H' or
    -- 'Z' against a simulation model - without this those weak states end up
    -- in the shift register and every read compares unequal to its value.
    input_sync : process (clock) is
    begin
        if rising_edge(clock) then
            if sda_in = '0' or sda_in = 'L' then
                sda_meta <= '0';
            else
                sda_meta <= '1';
            end if;
            sda_sync <= sda_meta;
        end if;
    end process input_sync;

    sequencer : process (clock) is

        -- advance the quarter-phase counter; returns true on a phase boundary
        variable phase_done : boolean;

    begin
        if rising_edge(clock) then

            done_i     <= '0';
            phase_done := false;

            if state /= st_idle then
                if tick = c_quarter - 1 then
                    tick       <= 0;
                    phase_done := true;
                else
                    tick <= tick + 1;
                end if;
            end if;

            case state is

------------------------------------------------------------------------
                when st_idle =>
                    if req = '1' then
                        tick      <= 0;
                        phase     <= 0;
                        bit_index <= 7;
                        shift_out <= wr_data;
                        case op is
                            when i2c_op_start => state <= st_start;
                            when i2c_op_write => state <= st_write;
                                                 ack_err_i <= '0';
                            when i2c_op_read  => state <= st_read;
                            when others       => state <= st_stop;
                        end case;
                    end if;

------------------------------------------------------------------------
                -- START / repeated START: release SDA and SCL, then pull SDA
                -- low while SCL is high, then pull SCL low.
                when st_start =>
                    case phase is
                        when 0 => sda_pull <= '0'; scl_pull <= '0';
                        when 1 => sda_pull <= '0'; scl_pull <= '0';
                        when 2 => sda_pull <= '1'; scl_pull <= '0';   -- START
                        when others => sda_pull <= '1'; scl_pull <= '1';
                    end case;
                    if phase_done then
                        if phase = 3 then
                            state <= st_done;
                        else
                            phase <= phase + 1;
                        end if;
                    end if;

------------------------------------------------------------------------
                -- STOP: with SCL low pull SDA low, release SCL, then release
                -- SDA while SCL is high.
                when st_stop =>
                    case phase is
                        when 0 => sda_pull <= '1'; scl_pull <= '1';
                        when 1 => sda_pull <= '1'; scl_pull <= '0';
                        when others => sda_pull <= '0'; scl_pull <= '0';  -- STOP
                    end case;
                    if phase_done then
                        if phase = 3 then
                            state <= st_done;
                        else
                            phase <= phase + 1;
                        end if;
                    end if;

------------------------------------------------------------------------
                -- write 8 bits, MSB first: set SDA while SCL is low, then
                -- release SCL for the high half.
                when st_write =>
                    case phase is
                        when 0 => scl_pull <= '1'; sda_pull <= not shift_out(bit_index);
                        when 1 => scl_pull <= '0';
                        when 2 => scl_pull <= '0';
                        when others => scl_pull <= '1';
                    end case;
                    if phase_done then
                        if phase = 3 then
                            phase <= 0;
                            if bit_index = 0 then
                                state <= st_write_ack;
                            else
                                bit_index <= bit_index - 1;
                            end if;
                        else
                            phase <= phase + 1;
                        end if;
                    end if;

                -- release SDA and sample it while SCL is high: 0 = ACK
                when st_write_ack =>
                    case phase is
                        when 0 => scl_pull <= '1'; sda_pull <= '0';
                        when 1 => scl_pull <= '0';
                        when 2 => scl_pull <= '0';
                        when others => scl_pull <= '1';
                    end case;
                    if phase_done then
                        if phase = 1 then            -- mid-way through SCL high
                            ack_err_i <= sda_sync;   -- '1' = no acknowledge
                        end if;
                        if phase = 3 then
                            phase <= 0;
                            state <= st_done;
                        else
                            phase <= phase + 1;
                        end if;
                    end if;

------------------------------------------------------------------------
                -- read 8 bits, MSB first, sampling while SCL is high
                when st_read =>
                    case phase is
                        when 0 => scl_pull <= '1'; sda_pull <= '0';
                        when 1 => scl_pull <= '0';
                        when 2 => scl_pull <= '0';
                        when others => scl_pull <= '1';
                    end case;
                    if phase_done then
                        if phase = 1 then            -- mid-way through SCL high
                            shift_in <= shift_in(6 downto 0) & sda_sync;
                        end if;
                        if phase = 3 then
                            phase <= 0;
                            if bit_index = 0 then
                                state <= st_read_ack;
                            else
                                bit_index <= bit_index - 1;
                            end if;
                        else
                            phase <= phase + 1;
                        end if;
                    end if;

                -- drive ACK ('0' on the wire) or leave it released for NACK
                when st_read_ack =>
                    case phase is
                        when 0 => scl_pull <= '1'; sda_pull <= read_ack;
                        when 1 => scl_pull <= '0';
                        when 2 => scl_pull <= '0';
                        when others => scl_pull <= '1';
                    end case;
                    if phase_done then
                        if phase = 3 then
                            phase <= 0;
                            state <= st_done;
                        else
                            phase <= phase + 1;
                        end if;
                    end if;

------------------------------------------------------------------------
                when st_done =>
                    done_i <= '1';
                    state  <= st_idle;

            end case;

            if reset = '1' then
                state     <= st_idle;
                phase     <= 0;
                tick      <= 0;
                bit_index <= 7;
                sda_pull  <= '0';
                scl_pull  <= '0';
                ack_err_i <= '0';
                done_i    <= '0';
                shift_in  <= (others => '0');
            end if;
        end if;
    end process sequencer;

end architecture rtl;
