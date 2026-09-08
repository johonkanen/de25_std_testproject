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
--   FPGA_I2C_SCL PIN_BF120  3.3-V LVCMOS   MAX6650 fan controller (open-drain)
--   FPGA_I2C_SDA PIN_BH118  3.3-V LVCMOS   MAX6650 fan controller (open-drain)
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
-- This is a thin wrapper around uart_register_block.vhd (register map,
-- clocking and reset documented there) - it and de25_soc_top.vhd (which
-- additionally wires the HPS's lwhps2fpga AXI4 port into the same block)
-- share one register file instead of keeping two.
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;

entity de25_uart_top is
    generic (
        g_clock_divider : natural := 434
        ;g_por_cycles   : natural := 1_048_575
        -- fan speed after reset - matches uart_register_block.vhd's own
        -- default (1500 RPM, confirmed spinning on a real DE25-Standard -
        -- see docs/de25_std_fan.md). Threaded through as a generic here
        -- too since it was useful for walking the value down live; no
        -- need to override it for a normal build.
        ;g_fan_min_rpm  : natural := 1500
    );
    port (
        CLOCK0_50     : in  std_logic                       -- 50 MHz (PIN_CH128)
        ;CPU_RESET_n  : in  std_logic                       -- active low (PIN_BM78)
        ;SW           : in  std_logic_vector(9 downto 0)     -- slide switches
        ;KEY          : in  std_logic_vector(3 downto 0)     -- push-buttons, active low
        ;LEDR         : out std_logic_vector(9 downto 0)     -- red user LEDs
        ;uart_rxd     : in  std_logic                        -- GPIO_D[0]  (PIN_BK31)
        ;uart_txd     : out std_logic                        -- GPIO_D[1]  (PIN_BE43)
        ;FPGA_I2C_SCL : inout std_logic                      -- PIN_BF120, open-drain
        ;FPGA_I2C_SDA : inout std_logic                      -- PIN_BH118, open-drain
    );
end entity de25_uart_top;

architecture rtl of de25_uart_top is
begin

    u_registers : entity work.uart_register_block
    generic map (
        g_clock_divider => g_clock_divider
        ,g_por_cycles   => g_por_cycles
        ,g_fan_min_rpm  => g_fan_min_rpm
    )
    port map (
        core_clock  => CLOCK0_50
        ,CPU_RESET_n => CPU_RESET_n
        ,SW          => SW
        ,KEY         => KEY
        ,LEDR        => LEDR
        ,uart_rxd    => uart_rxd
        ,uart_txd    => uart_txd
        -- lwhps2fpga (axi_*) ports left unconnected - no HPS in this build,
        -- every input defaults to idle so the bridge never requests anything.
        ,FPGA_I2C_SCL => FPGA_I2C_SCL
        ,FPGA_I2C_SDA => FPGA_I2C_SDA
    );

end rtl;
