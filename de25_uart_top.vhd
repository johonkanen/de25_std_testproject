------------------------------------------------------------------------
-- Minimal Agilex 5 UART bring-up build for the Terasic DE25-Standard board.
--
-- Same skeleton as johonkanen/axc3000_test, trimmed to the essentials:
-- the fpga_communication UART block + an fpga_interconnect register file.
-- No PLL, no DSP, no processors - the 50 MHz board clock drives everything.
--
-- Board / pinout from the DE25-Standard golden top (Demonstration/FPGA):
--   CLOCK0_50    PIN_CH128  3.3-V LVCMOS   50 MHz oscillator
--   CPU_RESET_n  PIN_BM78   1.2-V          active low push-button
--   LEDR[9:0]    ...        1.2-V          red user LEDs
--   SW[9:0]      ...        1.2-V          slide switches
--   KEY[3:0]     ...        1.2-V          push-buttons, active low
--   uart_rxd     PIN_BK31   3.3-V LVCMOS   GPIO_D[0]   (board TX -> FPGA RX)
--   uart_txd     PIN_BE43   3.3-V LVCMOS   GPIO_D[1]   (FPGA TX -> board RX)
--
-- The DE25-Standard has no FPGA-fabric UART wired to its on-board CP2105
-- USB bridge (that port goes to the HPS), so the UART is broken out to two
-- GPIO header pins - connect a 3.3 V USB-serial adapter:
--   adapter GND  <-> header GND
--   adapter TXD  -> GPIO_D[0]  (uart_rxd)
--   adapter RXD  <- GPIO_D[1]  (uart_txd)
-- See docs/de25_pinout.md to repoint these two pins.
--
-- Clocking / baud:
--   g_clock_divider = 434  ->  50e6 / 434 = 115207 baud (~115200, 0.006% err)
--
-- Register map reachable over UART (32 bit data, 16 bit address):
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

entity de25_uart_top is
    generic (
        -- core clock (Hz) / baud rate.  50 MHz / 115200 = 434.
        g_clock_divider : natural := 434
        -- power-on reset length in core-clock cycles (~21 ms at 50 MHz).
        ;g_por_cycles   : natural := 1_048_575
    );
    port (
        CLOCK0_50     : in  std_logic                       -- 50 MHz (PIN_CH128)
        ;CPU_RESET_n  : in  std_logic                       -- active low (PIN_BM78)
        ;SW           : in  std_logic_vector(9 downto 0)     -- slide switches
        ;KEY          : in  std_logic_vector(3 downto 0)     -- push-buttons, active low
        ;LEDR         : out std_logic_vector(9 downto 0)     -- red user LEDs
        ;uart_rxd     : in  std_logic                        -- GPIO_D[0]  (PIN_BK31)
        ;uart_txd     : out std_logic                        -- GPIO_D[1]  (PIN_BE43)
    );
end entity de25_uart_top;

architecture rtl of de25_uart_top is

    use work.fpga_interconnect_pkg.all;

    signal core_clock : std_logic;

    -- synchronous, active-high reset: power-on counter + CPU_RESET_n button
    signal por_counter  : natural range 0 to g_por_cycles := g_por_cycles;
    signal reset_meta   : std_logic := '1';
    signal reset_sync   : std_logic := '1';
    signal system_reset : std_logic := '1';

    signal bus_to_communications   : fpga_interconnect_record := init_fpga_interconnect;
    signal bus_from_communications : fpga_interconnect_record := init_fpga_interconnect;
    signal bus_from_top            : fpga_interconnect_record := init_fpga_interconnect;

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
    core_clock <= CLOCK0_50;

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
            init_bus(bus_from_top);

            connect_read_only_data_to_address(bus_from_communications, bus_from_top, 1, x"0000DE25");
            connect_read_only_data_to_address(bus_from_communications, bus_from_top, 2, work.git_hash_pkg.git_hash);
            connect_data_to_address(bus_from_communications, bus_from_top, 3, loopback_register);

            if data_is_requested_from_address(bus_from_communications, 4) then
                read_counter <= std_logic_vector(unsigned(read_counter) + 1);
                write_data_to_address(bus_from_top, 0, read_counter);
            end if;

            connect_data_to_address(bus_from_communications, bus_from_top, 5, led_register);
            connect_read_only_data_to_address(bus_from_communications, bus_from_top, 6,
                std_logic_vector(resize(unsigned(sw_sync), 32)));
            connect_read_only_data_to_address(bus_from_communications, bus_from_top, 7,
                std_logic_vector(resize(unsigned(not key_sync), 32)));   -- KEY is active low
            connect_read_only_data_to_address(bus_from_communications, bus_from_top, 8,
                std_logic_vector(uptime_counter));

            uptime_counter <= uptime_counter + 1;

            bus_to_communications <= bus_from_top;

            if system_reset = '1' then
                loopback_register     <= (others => '0');
                read_counter          <= (others => '0');
                led_register          <= (others => '0');
                uptime_counter        <= (others => '0');
                bus_to_communications <= init_fpga_interconnect;
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

end rtl;
