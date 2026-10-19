------------------------------------------------------------------------
-- register_block - the fpga_interconnect register file, reached from the
-- HPS over the lwhps2fpga (LWH2F) AXI4 bridge via axi_lwh2f_bridge.vhd
-- (ported from ~/dev/datacenter_peak_shaving/fpga/agilex/de25/axi_led.vhd).
-- The fabric UART master it used to have as well was removed.
--
-- Register map (32 bit data; over LWH2F each register is a 16-byte-aligned
-- AXI offset, register N at byte offset 16*N, see axi_lwh2f_bridge.vhd):
--   addr 1 : constant id      0x0000DE25   (read only)
--   addr 2 : git hash                       (read only)
--   addr 3 : loopback register              (read / write)
--   addr 4 : read strobe counter            (read only, ++ on every read of 4)
--   addr 5 : LED register, low 10 bits -> LEDR[8:0] + spare  (read / write)
--   addr 6 : SW[9:0] slide switches         (read only)
--   addr 7 : KEY[3:0] push-buttons, 1 = pressed; bit 4 CPU_RESET_n
--            pressed  (read only)
--   addr 8 : free-running core-clock uptime counter  (read only)
--   addr 9 : fan target, MAX6650 KTACH register  (read / write)
--   addr 10: fan tach0/rpm - bits 7:0 raw Tach0Count, bits 23:8 rpm  (RO)
--   addr 11: fan link status - bits 7:0 Config readback, bit 8
--            init_done, bit 9 i2c_error                        (RO)
--   addr 13: LED blinker mode, low 3 bits (read / write) - 0 software,
--            1 off, 2 counter, 3 scanner, 4 breathing, 5 sparkle
--   addr 14: LEDR 3..0 brightness, a byte each (RO)
--   addr 15: LEDR 7..4 brightness (RO)
--   addr 16: features - bit 0 hardware blinkers, bit 1 HEX displays (RO)
--   addr 17: blinker module id, four ASCII chars, 0 in modes 0/1 (RO)
--   addr 18: board variant 0x53544400 ("STD\0"; the DE25-Nano reads 0)  (RO)
--   addr 19: build id, Unix time of the build (build_id_pkg.vhd)  (RO)
--   addr 20: LEDR 9..8 brightness, bits 15:0 (RO)
--   addr 21: HEX value, 24 bits, HEX0 = bits 3:0  (read / write)
--   addr 22: HEX control - bit 0 raw mode, bit 1 flip (read from the
--            other side), bits 13:8 blank mask  (R/W)
--   addr 23: HEX raw segments HEX3..0, a byte each, bits 6:0 g..a  (R/W)
--   addr 24: HEX raw segments HEX5..4  (R/W)
--   addr 25: HEX segments driven, HEX3..0, 1 = lit (RO)
--   addr 26: HEX segments driven, HEX5..4 (RO)
--
-- In blinker mode 0 (the reset default) LEDR[8:0] follow addr-5 bits 8..0
-- and LEDR[9] is a ~1 Hz heartbeat so the board shows life without a
-- terminal attached; modes 2..5 hand all ten LEDs to a pattern module
-- (source/led_blinkers.vhd, source/blinkers/). The HEX displays:
-- source/hex_display.vhd.
--
-- Resets: the power-on counter resets everything, the LWH2F side included.
-- CPU_RESET_n resets only the user registers and logic (LEDs, blinkers,
-- HEX, fan target, loopback) - never the AXI side: a button press while
-- Linux reads over LWH2F used to stall the CPU (plan §5.18).
--
-- Fan control (see source/fan_control/max6650_fan_control.vhd): the
-- board's MAX6650 fan-speed controller hangs off its own I2C bus
-- (FPGA_I2C_SCLK / FPGA_I2C_SDAT), and register 9 is its target speed
-- (KTACH encoding, not linear RPM - see that file's header). It resets to
-- g_fan_min_rpm converted to KTACH, so the fan comes up at a low,
-- vendor-chosen speed instead of whatever Terasic's own board-management
-- IP (not present here) would otherwise drive it to, and stays there
-- until something writes a new value.
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity register_block is
    generic (
        -- power-on reset length in core-clock cycles (~100 ms at 50 MHz).
        -- Was ~21 ms (1_048_575); widened while chasing the LWH2F hang on
        -- the chance the lwhps2fpga bridge hard macro (see axi_bridge_reset
        -- below) needed longer to see the fabric clock/logic driving it
        -- settle before its reset releases. Turned out not to be the fix
        -- (axi_bridge_reset's own polarity was inverted, see below) - kept
        -- at 100ms anyway as a bit of extra margin, since it's free.
        g_por_cycles   : natural := 4_999_999
        -- fan speed after reset, in RPM - converted to the MAX6650's KTACH
        -- encoding for register 9's reset value (see
        -- source/fan_control/max6650_fan_control.vhd's header for the
        -- formula). The single source of truth: also passed straight into
        -- max6650_fan_control's own g_min_rpm below, so the two stay in
        -- sync. 1500 was walked down live on a DE25-Standard from
        -- Terasic's own auto_fan.v floor of 3500 - see docs/de25_std_fan.md
        -- for the readings at each step and what was and wasn't confirmed.
        ;g_fan_min_rpm  : natural := 1500
        ;g_fan_kscale   : natural := 2
    );
    port (
        core_clock   : in  std_logic
        ;CPU_RESET_n : in  std_logic                       -- active low
        ;SW          : in  std_logic_vector(9 downto 0)     -- slide switches
        ;KEY         : in  std_logic_vector(3 downto 0)     -- push-buttons, active low
        ;LEDR        : out std_logic_vector(9 downto 0)     -- red user LEDs
        -- 7-segment displays, common anode: low = segment lit
        ;HEX0        : out std_logic_vector(6 downto 0)
        ;HEX1        : out std_logic_vector(6 downto 0)
        ;HEX2        : out std_logic_vector(6 downto 0)
        ;HEX3        : out std_logic_vector(6 downto 0)
        ;HEX4        : out std_logic_vector(6 downto 0)
        ;HEX5        : out std_logic_vector(6 downto 0)

        -- lwhps2fpga (LWH2F) AXI4 register access.  Runs on core_clock
        -- (de25_soc_top.vhd ties lwhps2fpga_axi_clock to the same 50 MHz
        -- clock, so no clock-domain crossing is needed here).
        ;axi_awid    : in  std_logic_vector(3 downto 0)  := (others => '0')
        ;axi_awaddr  : in  std_logic_vector(28 downto 0) := (others => '0')
        ;axi_awvalid : in  std_logic := '0'
        ;axi_awready : out std_logic
        ;axi_wdata   : in  std_logic_vector(31 downto 0) := (others => '0')
        ;axi_wstrb   : in  std_logic_vector(3 downto 0)  := (others => '0')
        ;axi_wvalid  : in  std_logic := '0'
        ;axi_wready  : out std_logic
        ;axi_bid     : out std_logic_vector(3 downto 0)
        ;axi_bresp   : out std_logic_vector(1 downto 0)
        ;axi_bvalid  : out std_logic
        ;axi_bready  : in  std_logic := '0'
        ;axi_arid    : in  std_logic_vector(3 downto 0)  := (others => '0')
        ;axi_araddr  : in  std_logic_vector(28 downto 0) := (others => '0')
        ;axi_arvalid : in  std_logic := '0'
        ;axi_arready : out std_logic
        ;axi_rid     : out std_logic_vector(3 downto 0)
        ;axi_rdata   : out std_logic_vector(31 downto 0)
        ;axi_rresp   : out std_logic_vector(1 downto 0)
        ;axi_rlast   : out std_logic
        ;axi_rvalid  : out std_logic
        ;axi_rready  : in  std_logic := '0'

        -- Reset for the HPS's own lwhps2fpga bridge hard macro
        -- (de25_soc_top.vhd's hps_subsystem lwhps2fpga_axi_reset_reset),
        -- NOT for axi_lwh2f_bridge.vhd above (that one uses the same
        -- por_reset internally, see u_axi_lwh2f_bridge below). The
        -- power-on-reset delay only (~100 ms at 50 MHz, see g_por_cycles),
        -- not CPU_RESET_n: releasing the HPS-side bridge macro's
        -- reset too early - before the FPGA fabric clock/logic driving
        -- it has settled - left it permanently wedged (every AXI
        -- transaction through it hangs the ARM core forever, recoverable
        -- only by a full JTAG reprogram) even though axi_lwh2f_bridge.vhd
        -- itself was verified correct in isolation.
        ;axi_bridge_reset : out std_logic := '1'

        -- MAX6650 fan controller I2C bus, open-drain (see
        -- source/fan_control/max6650_fan_control.vhd)
        ;FPGA_I2C_SCL : inout std_logic
        ;FPGA_I2C_SDA : inout std_logic
    );
end entity register_block;

architecture rtl of register_block is

    use work.fpga_interconnect_pkg.all;

    -- synchronous, active-high resets: por_reset from the power-on counter
    -- only (the LWH2F side), user_reset also from the CPU_RESET_n button
    signal por_counter  : natural range 0 to g_por_cycles := g_por_cycles;
    signal reset_meta   : std_logic := '1';
    signal reset_sync   : std_logic := '1';
    signal por_reset    : std_logic := '1';
    signal user_reset   : std_logic := '1';

    signal bus_to_axi   : fpga_interconnect_record := init_fpga_interconnect;
    signal bus_from_axi : fpga_interconnect_record := init_fpga_interconnect;
    signal bus_from_top_axi : fpga_interconnect_record := init_fpga_interconnect;

    -- register 18: "STD\0", so tools can refuse a core or release for the
    -- other board (the DE25-Nano reads 0 there)
    constant c_board_variant : std_logic_vector(31 downto 0) := x"53544400";

    signal loopback_register : std_logic_vector(31 downto 0) := (others => '0');
    signal read_counter      : std_logic_vector(31 downto 0) := (others => '0');
    signal led_register      : std_logic_vector(31 downto 0) := (others => '0');
    signal uptime_counter    : unsigned(31 downto 0)         := (others => '0');

    -- ~1 Hz heartbeat: 50 MHz / 2**26 ~= 0.75 Hz toggle
    signal heartbeat_count : unsigned(25 downto 0) := (others => '0');
    signal heartbeat       : std_logic := '0';

    -- LED blinkers (source/led_blinkers.vhd): register 13 picks the mode,
    -- levels/id are read back by the web GUI
    signal blinker_mode_register : std_logic_vector(31 downto 0) := (others => '0');
    signal blinker_levels        : std_logic_vector(79 downto 0);
    signal blinker_id            : std_logic_vector(31 downto 0);
    -- register 16: bit 0 hardware blinkers, bit 1 HEX displays
    constant c_features : std_logic_vector(31 downto 0) := x"00000003";

    -- HEX displays (source/hex_display.vhd)
    signal hex_value_register   : std_logic_vector(31 downto 0) := (others => '0');
    signal hex_control_register : std_logic_vector(31 downto 0) := (others => '0');
    signal hex_raw_low          : std_logic_vector(31 downto 0) := (others => '0');
    signal hex_raw_high         : std_logic_vector(31 downto 0) := (others => '0');
    signal hex_lit              : std_logic_vector(47 downto 0);

    -- double-flop the async inputs before they reach the register file
    signal sw_meta,  sw_sync  : std_logic_vector(9 downto 0) := (others => '0');
    signal key_meta, key_sync : std_logic_vector(3 downto 0) := (others => '1');

    ------------------------------------------------------------------
    -- fan control (see source/fan_control/max6650_fan_control.vhd)
    -- KTACH register value for g_fan_min_rpm - same formula as that
    -- entity's own c_ktach_min_rpm, duplicated here because the register
    -- (and its reset value) lives in this file, one level up from the
    -- driver. g_fan_min_rpm is the single generic both read from.
    constant c_fan_ktach_default : natural :=
        ((992 * g_fan_kscale) / (g_fan_min_rpm / 60)) - 1;

    signal fan_ktach_register  : std_logic_vector(31 downto 0) :=
        std_logic_vector(to_unsigned(c_fan_ktach_default, 32));
    signal fan_rpm             : std_logic_vector(15 downto 0);
    signal fan_tach0           : std_logic_vector(7 downto 0);
    signal fan_config_readback : std_logic_vector(7 downto 0);
    signal fan_init_done       : std_logic;
    signal fan_i2c_error       : std_logic;

    signal i2c_sda_low : std_logic;
    signal i2c_scl_low : std_logic;

begin

------------------------------------------------------------------------
    -- hold both resets for ~100 ms after configuration; the button then
    -- drives user_reset only
    reset_synchroniser : process (core_clock) is
    begin
        if rising_edge(core_clock) then
            reset_meta <= not CPU_RESET_n;
            reset_sync <= reset_meta;

            if por_counter /= 0 then
                por_counter <= por_counter - 1;
                por_reset   <= '1';
                user_reset  <= '1';
            else
                por_reset   <= '0';
                user_reset  <= reset_sync;
            end if;
        end if;
    end process reset_synchroniser;

------------------------------------------------------------------------
    input_synchroniser : process (core_clock) is
    begin
        if rising_edge(core_clock) then
            sw_meta  <= SW;   sw_sync  <= sw_meta;
            key_meta <= KEY;  key_sync <= key_meta;
        end if;
    end process input_synchroniser;

------------------------------------------------------------------------
    heartbeat_gen : process (core_clock) is
    begin
        if rising_edge(core_clock) then
            heartbeat_count <= heartbeat_count + 1;
            if heartbeat_count = 0 then
                heartbeat <= not heartbeat;
            end if;
        end if;
    end process heartbeat_gen;

------------------------------------------------------------------------
    u_led_blinkers : entity work.led_blinkers
    generic map (
        g_clock_hz => 50_000_000
    )
    port map (
        clock    => core_clock
        ,reset   => user_reset
        ,mode    => unsigned(blinker_mode_register(2 downto 0))
        ,sw_leds => heartbeat & led_register(8 downto 0)
        ,leds    => LEDR
        ,levels  => blinker_levels
        ,id      => blinker_id
    );

------------------------------------------------------------------------
    u_hex_display : entity work.hex_display
    port map (
        clock     => core_clock
        ,reset    => user_reset
        ,value    => hex_value_register(23 downto 0)
        ,raw_mode => hex_control_register(0)
        ,flip     => hex_control_register(1)
        ,blank    => hex_control_register(13 downto 8)
        ,raw      => hex_raw_high(15 downto 0) & hex_raw_low
        ,lit      => hex_lit
        ,HEX0     => HEX0
        ,HEX1     => HEX1
        ,HEX2     => HEX2
        ,HEX3     => HEX3
        ,HEX4     => HEX4
        ,HEX5     => HEX5
    );

------------------------------------------------------------------------
    test_registers : process (core_clock) is
    begin
        if rising_edge(core_clock) then
            init_bus(bus_from_top_axi);

            connect_read_only_data_to_address(bus_from_axi, bus_from_top_axi, 1, x"0000DE25");
            connect_read_only_data_to_address(bus_from_axi, bus_from_top_axi, 2, work.git_hash_pkg.git_hash);
            connect_data_to_address(bus_from_axi, bus_from_top_axi, 3, loopback_register);
            if data_is_requested_from_address(bus_from_axi, 4) then
                read_counter <= std_logic_vector(unsigned(read_counter) + 1);
                write_data_to_address(bus_from_top_axi, 0, read_counter);
            end if;
            connect_data_to_address(bus_from_axi, bus_from_top_axi, 5, led_register);
            connect_read_only_data_to_address(bus_from_axi, bus_from_top_axi, 6,
                std_logic_vector(resize(unsigned(sw_sync), 32)));
            connect_read_only_data_to_address(bus_from_axi, bus_from_top_axi, 7,
                (31 downto 5 => '0') & reset_sync & (not key_sync));
            connect_read_only_data_to_address(bus_from_axi, bus_from_top_axi, 8,
                std_logic_vector(uptime_counter));
            connect_data_to_address(bus_from_axi, bus_from_top_axi, 9, fan_ktach_register);
            connect_read_only_data_to_address(bus_from_axi, bus_from_top_axi, 10,
                x"00" & fan_rpm & fan_tach0);
            connect_read_only_data_to_address(bus_from_axi, bus_from_top_axi, 11,
                (31 downto 10 => '0') & fan_i2c_error & fan_init_done & fan_config_readback);
            connect_data_to_address(bus_from_axi, bus_from_top_axi, 13, blinker_mode_register);
            connect_read_only_data_to_address(bus_from_axi, bus_from_top_axi, 14, blinker_levels(31 downto 0));
            connect_read_only_data_to_address(bus_from_axi, bus_from_top_axi, 15, blinker_levels(63 downto 32));
            connect_read_only_data_to_address(bus_from_axi, bus_from_top_axi, 16, c_features);
            connect_read_only_data_to_address(bus_from_axi, bus_from_top_axi, 17, blinker_id);
            connect_read_only_data_to_address(bus_from_axi, bus_from_top_axi, 18, c_board_variant);
            connect_read_only_data_to_address(bus_from_axi, bus_from_top_axi, 19, work.build_id_pkg.build_id);
            connect_read_only_data_to_address(bus_from_axi, bus_from_top_axi, 20,
                x"0000" & blinker_levels(79 downto 64));
            connect_data_to_address(bus_from_axi, bus_from_top_axi, 21, hex_value_register);
            connect_data_to_address(bus_from_axi, bus_from_top_axi, 22, hex_control_register);
            connect_data_to_address(bus_from_axi, bus_from_top_axi, 23, hex_raw_low);
            connect_data_to_address(bus_from_axi, bus_from_top_axi, 24, hex_raw_high);
            connect_read_only_data_to_address(bus_from_axi, bus_from_top_axi, 25, hex_lit(31 downto 0));
            connect_read_only_data_to_address(bus_from_axi, bus_from_top_axi, 26,
                x"0000" & hex_lit(47 downto 32));

            uptime_counter <= uptime_counter + 1;

            bus_to_axi <= bus_from_top_axi;

            -- the button: the user registers back to their reset values
            -- (not bus_to_axi: a read in flight still gets its answer)
            if user_reset = '1' then
                loopback_register     <= (others => '0');
                read_counter          <= (others => '0');
                led_register          <= (others => '0');
                fan_ktach_register    <= std_logic_vector(to_unsigned(c_fan_ktach_default, 32));
                blinker_mode_register <= (others => '0');
                hex_value_register    <= (others => '0');
                hex_control_register  <= (others => '0');
                hex_raw_low           <= (others => '0');
                hex_raw_high          <= (others => '0');
            end if;
            if por_reset = '1' then
                uptime_counter        <= (others => '0');
                bus_to_axi            <= init_fpga_interconnect;
            end if;
        end if;
    end process test_registers;

------------------------------------------------------------------------
    u_axi_lwh2f_bridge : entity work.axi_lwh2f_bridge
    generic map (
        axi_interconnect_pkg => work.fpga_interconnect_pkg
    )
    port map (
        clock   => core_clock
        ,resetn => not por_reset

        ,awid    => axi_awid
        ,awaddr  => axi_awaddr
        ,awvalid => axi_awvalid
        ,awready => axi_awready
        ,wdata   => axi_wdata
        ,wstrb   => axi_wstrb
        ,wvalid  => axi_wvalid
        ,wready  => axi_wready
        ,bid     => axi_bid
        ,bresp   => axi_bresp
        ,bvalid  => axi_bvalid
        ,bready  => axi_bready
        ,arid    => axi_arid
        ,araddr  => axi_araddr
        ,arvalid => axi_arvalid
        ,arready => axi_arready
        ,rid     => axi_rid
        ,rdata   => axi_rdata
        ,rresp   => axi_rresp
        ,rlast   => axi_rlast
        ,rvalid  => axi_rvalid
        ,rready  => axi_rready

        ,bus_from_lwh2f => bus_from_axi
        ,bus_to_lwh2f   => bus_to_axi
    );

------------------------------------------------------------------------
    -- axi_bridge_reset is active-HIGH (see its declaration above and the
    -- fan controller's `reset => user_reset` a few lines down) - unlike
    -- `resetn` above it, it must NOT be inverted. It was: this held the
    -- HPS's lwhps2fpga hard macro released during our own POR hold and
    -- then asserted (permanently in reset) for the rest of normal
    -- operation - the exact opposite of the intended "delay the release"
    -- behaviour, and the real cause of the LWH2F hang chased across this
    -- whole session (widening g_por_cycles never had a chance to help,
    -- since the bridge was never actually held in reset during the delay
    -- in the first place - see linux/README.md's session-status notes).
    axi_bridge_reset <= por_reset;

------------------------------------------------------------------------
-- MAX6650 fan controller, on its own I2C bus - see
-- source/fan_control/max6650_fan_control.vhd and this file's header.
-- Tri-stated here exactly like the i2c_master_pkg.vhd header documents:
-- only ever driven low or released, never driven high.
------------------------------------------------------------------------
    FPGA_I2C_SCL <= '0' when i2c_scl_low = '1' else 'Z';
    FPGA_I2C_SDA <= '0' when i2c_sda_low = '1' else 'Z';

    u_fan_control : entity work.max6650_fan_control
    generic map (
        g_clock_hz => 50_000_000
        ,g_min_rpm => g_fan_min_rpm
        ,g_kscale  => g_fan_kscale
    )
    port map (
        clock            => core_clock
        ,reset           => user_reset
        ,ktach_in        => fan_ktach_register(7 downto 0)
        ,rpm_out         => fan_rpm
        ,tach0_out       => fan_tach0
        ,config_readback => fan_config_readback
        ,ktach_out       => open
        ,init_done       => fan_init_done
        ,i2c_error       => fan_i2c_error
        ,sda_in          => FPGA_I2C_SDA
        ,sda_low         => i2c_sda_low
        ,scl_low         => i2c_scl_low
    );

end rtl;
