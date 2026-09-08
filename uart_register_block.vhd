------------------------------------------------------------------------
-- uart_register_block - the fpga_interconnect register file, reachable
-- over two independent masters:
--   * the fabric UART (fpga_communications, GPIO_D[0]/[1])
--   * the HPS lwhps2fpga (LWH2F) AXI4 bridge, when connected
--
-- Extracted from de25_uart_top.vhd so de25_soc_top.vhd can wire the HPS's
-- lwhps2fpga_* ports straight into the same register file the fabric UART
-- already talks to, via axi_lwh2f_bridge.vhd (ported from
-- ~/dev/datacenter_peak_shaving/fpga/agilex/de25/axi_led.vhd). The
-- standalone de25_uart_top.vhd instantiates this block too, leaving the
-- axi_* ports unconnected - they all default to inert values, so that
-- build is otherwise unchanged.
--
-- Each register is decoded twice, once per master, into two SEPARATE
-- response accumulators (bus_from_top_uart / bus_from_top_axi) rather
-- than one shared one: a shared accumulator would let a same-cycle
-- read from one master briefly overwrite the other master's response
-- (both use address 0 as the "here is your read data" slot). Register
-- *storage* (loopback_register, led_register, ...) is still one copy,
-- shared by both masters - the split is only where each master's
-- response goes.
--
-- Register map (32 bit data, 16 bit address - see docs/de25_pinout.md
-- for the UART protocol; over LWH2F each register is a 16-byte-aligned
-- AXI offset, register N at byte offset 16*N, see axi_lwh2f_bridge.vhd):
--   addr 1 : constant id      0x0000DE25   (read only)
--   addr 2 : git hash                       (read only)
--   addr 3 : loopback register              (read / write)
--   addr 4 : read strobe counter            (read only, ++ on every read of 4)
--   addr 5 : LED register, low 10 bits -> LEDR[8:0] + spare  (read / write)
--   addr 6 : SW[9:0] slide switches         (read only)
--   addr 7 : KEY[3:0] push-buttons, 1 = pressed  (read only)
--   addr 8 : free-running core-clock uptime counter  (read only)
--
-- LEDR[8:0] follow addr-5 bits 8..0; LEDR[9] is a ~1 Hz heartbeat so the
-- board shows life without a terminal attached.
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity uart_register_block is
    generic (
        -- core clock (Hz) / baud rate.  50 MHz / 115200 = 434.
        g_clock_divider : natural := 434
        -- power-on reset length in core-clock cycles (~21 ms at 50 MHz).
        ;g_por_cycles   : natural := 1_048_575
    );
    port (
        core_clock   : in  std_logic
        ;CPU_RESET_n : in  std_logic                       -- active low
        ;SW          : in  std_logic_vector(9 downto 0)     -- slide switches
        ;KEY         : in  std_logic_vector(3 downto 0)     -- push-buttons, active low
        ;LEDR        : out std_logic_vector(9 downto 0)     -- red user LEDs
        ;uart_rxd    : in  std_logic                        -- fabric UART rx
        ;uart_txd    : out std_logic                        -- fabric UART tx

        -- lwhps2fpga (LWH2F) AXI4 register access.  Runs on core_clock
        -- (de25_soc_top.vhd ties lwhps2fpga_axi_clock to the same 50 MHz
        -- clock, so no clock-domain crossing is needed here).  Left
        -- unconnected, every input defaults to idle / '0' and the bridge
        -- never asserts a request - inert for the standalone de25_uart_top.
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
    );
end entity uart_register_block;

architecture rtl of uart_register_block is

    use work.fpga_interconnect_pkg.all;

    -- synchronous, active-high reset: power-on counter + CPU_RESET_n button
    signal por_counter  : natural range 0 to g_por_cycles := g_por_cycles;
    signal reset_meta   : std_logic := '1';
    signal reset_sync   : std_logic := '1';
    signal system_reset : std_logic := '1';

    signal bus_to_communications   : fpga_interconnect_record := init_fpga_interconnect;
    signal bus_from_communications : fpga_interconnect_record := init_fpga_interconnect;
    signal bus_from_top_uart       : fpga_interconnect_record := init_fpga_interconnect;

    signal bus_to_axi   : fpga_interconnect_record := init_fpga_interconnect;
    signal bus_from_axi : fpga_interconnect_record := init_fpga_interconnect;
    signal bus_from_top_axi : fpga_interconnect_record := init_fpga_interconnect;

    signal loopback_register : std_logic_vector(31 downto 0) := (others => '0');
    signal read_counter      : std_logic_vector(31 downto 0) := (others => '0');
    signal led_register      : std_logic_vector(31 downto 0) := (others => '0');
    signal uptime_counter    : unsigned(31 downto 0)         := (others => '0');

    -- ~1 Hz heartbeat: 50 MHz / 2**26 ~= 0.75 Hz toggle
    signal heartbeat_count : unsigned(25 downto 0) := (others => '0');
    signal heartbeat       : std_logic := '0';

    -- double-flop the async inputs before they reach the register file
    signal sw_meta,  sw_sync  : std_logic_vector(9 downto 0) := (others => '0');
    signal key_meta, key_sync : std_logic_vector(3 downto 0) := (others => '1');

begin

------------------------------------------------------------------------
    -- hold reset for ~21 ms after configuration, plus the button
    reset_synchroniser : process (core_clock) is
    begin
        if rising_edge(core_clock) then
            reset_meta <= not CPU_RESET_n;
            reset_sync <= reset_meta;

            if por_counter /= 0 then
                por_counter  <= por_counter - 1;
                system_reset <= '1';
            else
                system_reset <= reset_sync;
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

    LEDR(8 downto 0) <= led_register(8 downto 0);
    LEDR(9)          <= heartbeat;

------------------------------------------------------------------------
    test_registers : process (core_clock) is
    begin
        if rising_edge(core_clock) then
            init_bus(bus_from_top_uart);
            init_bus(bus_from_top_axi);

            -- ---- UART master ----
            connect_read_only_data_to_address(bus_from_communications, bus_from_top_uart, 1, x"0000DE25");
            connect_read_only_data_to_address(bus_from_communications, bus_from_top_uart, 2, work.git_hash_pkg.git_hash);
            connect_data_to_address(bus_from_communications, bus_from_top_uart, 3, loopback_register);
            if data_is_requested_from_address(bus_from_communications, 4) then
                read_counter <= std_logic_vector(unsigned(read_counter) + 1);
                write_data_to_address(bus_from_top_uart, 0, read_counter);
            end if;
            connect_data_to_address(bus_from_communications, bus_from_top_uart, 5, led_register);
            connect_read_only_data_to_address(bus_from_communications, bus_from_top_uart, 6,
                std_logic_vector(resize(unsigned(sw_sync), 32)));
            connect_read_only_data_to_address(bus_from_communications, bus_from_top_uart, 7,
                std_logic_vector(resize(unsigned(not key_sync), 32)));   -- KEY is active low
            connect_read_only_data_to_address(bus_from_communications, bus_from_top_uart, 8,
                std_logic_vector(uptime_counter));

            -- ---- LWH2F (AXI) master - same registers ----
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
                std_logic_vector(resize(unsigned(not key_sync), 32)));
            connect_read_only_data_to_address(bus_from_axi, bus_from_top_axi, 8,
                std_logic_vector(uptime_counter));

            uptime_counter <= uptime_counter + 1;

            bus_to_communications <= bus_from_top_uart;
            bus_to_axi             <= bus_from_top_axi;

            if system_reset = '1' then
                loopback_register     <= (others => '0');
                read_counter          <= (others => '0');
                led_register          <= (others => '0');
                uptime_counter        <= (others => '0');
                bus_to_communications <= init_fpga_interconnect;
                bus_to_axi            <= init_fpga_interconnect;
            end if;
        end if;
    end process test_registers;

------------------------------------------------------------------------
    u_fpga_communications : entity work.fpga_communications
    generic map (
        fpga_interconnect_pkg => work.fpga_interconnect_pkg
        ,g_clock_divider      => g_clock_divider
    )
    port map (
        clock                    => core_clock
        ,uart_rx                 => uart_rxd
        ,uart_tx                 => uart_txd
        ,bus_to_communications   => bus_to_communications
        ,bus_from_communications => bus_from_communications
    );

------------------------------------------------------------------------
    u_axi_lwh2f_bridge : entity work.axi_lwh2f_bridge
    generic map (
        axi_interconnect_pkg => work.fpga_interconnect_pkg
    )
    port map (
        clock   => core_clock
        ,resetn => not system_reset

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

end rtl;
