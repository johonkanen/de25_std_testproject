------------------------------------------------------------------------
-- de25_soc_top - DE25-Standard (Agilex 5) SoC bring-up.
--
--   * hps (hps/hps.vhd) : Agilex 5 HPS + HPS-EMIF DDR4, EMAC0 (RGMII+MDIO),
--                     SD/MMC, UART1 console, I2C1, SPIM0 + 3 GPIOs (LCD),
--                     its AXI buses as records (hps/hps_axi_pkg.vhd):
--                     lwhps2fpga to the register file; F2SDRAM and the F2H
--                     ACE5-Lite port enabled but unused for now (idle
--                     managers); H2F disabled; the F2H interrupts tied to 0.
--   * register_block : the fpga_interconnect register file, reachable
--                     over the HPS's lwhps2fpga (LWH2F) AXI4 bridge - see
--                     register_block.vhd and axi_lwh2f_bridge.vhd.
--   * h2f_user0_clk_heartbeat : proves out the HPS's dedicated free-running
--                     H2F User0 clock (50 MHz, independent of CLOCK0_50) by
--                     blinking GPIO_D[2] with it - deliberately isolated
--                     from the register file above, see that file's header.
--
-- hps wraps hps_subsystem, a Platform Designer system
-- (hps/hps_subsystem.qsys + its per-instance .ip files) - see
-- hps/README.md.  Pin / IO-standard assignments for the HPS and DDR4
-- pins come from the DE25 GHRD (hps/hps_pins.tcl).
--
-- lwhps2fpga runs on CLOCK0_50 (see lwhps2fpga_axi_clock_clk below), the
-- same clock as the register file - no clock-domain crossing needed.
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;

entity de25_soc_top is
    port (
        -- ---- fabric side ----
        CLOCK0_50     : in    std_logic;                     -- 50 MHz  (PIN_CH128)
        CPU_RESET_n   : in    std_logic;                     -- active low (PIN_BM78)
        SW            : in    std_logic_vector(9 downto 0);
        KEY           : in    std_logic_vector(3 downto 0);
        LEDR          : out   std_logic_vector(9 downto 0);
        -- six 7-segment displays, common anode (low = lit), see hex_display.vhd
        HEX0          : out   std_logic_vector(6 downto 0);
        HEX1          : out   std_logic_vector(6 downto 0);
        HEX2          : out   std_logic_vector(6 downto 0);
        HEX3          : out   std_logic_vector(6 downto 0);
        HEX4          : out   std_logic_vector(6 downto 0);
        HEX5          : out   std_logic_vector(6 downto 0);
        FPGA_I2C_SCL  : inout std_logic;                     -- PIN_BF120, MAX6650 fan (open-drain)
        FPGA_I2C_SDA  : inout std_logic;                     -- PIN_BH118, MAX6650 fan (open-drain)
        H2F_CLK_TEST  : out   std_logic;                     -- GPIO_D[2] (PIN_BF29) - see h2f_user0_clk_heartbeat.vhd

        -- ---- HPS ----
        HPS_CLK_25       : in    std_logic;
        HPS_ENET_MDC     : out   std_logic;
        HPS_ENET_MDIO    : inout std_logic;
        HPS_ENET_RX_CLK  : in    std_logic;
        HPS_ENET_RX_CTL  : in    std_logic;
        HPS_ENET_RX_DATA : in    std_logic_vector(3 downto 0);
        HPS_ENET_TX_CLK  : out   std_logic;
        HPS_ENET_TX_CTL  : out   std_logic;
        HPS_ENET_TX_DATA : out   std_logic_vector(3 downto 0);
        HPS_I2C_SCL      : inout std_logic;
        HPS_I2C_SDA      : inout std_logic;
        HPS_SD_CLK       : out   std_logic;
        HPS_SD_CMD       : inout std_logic;
        HPS_SD_DATA      : inout std_logic_vector(3 downto 0);
        HPS_UART_RX      : in    std_logic;
        HPS_UART_TX      : out   std_logic;
        -- 128x64 LCD module: HPS SPIM0 + three HPS GPIO1 lines
        HPS_LCM_SPIM_CLK  : out   std_logic;
        HPS_LCM_SPIM_MOSI : out   std_logic;
        HPS_LCM_SPIM_SS   : out   std_logic;
        HPS_LCM_RST_n     : inout std_logic;
        HPS_LCM_D_C       : inout std_logic;
        HPS_LCM_BK        : inout std_logic;

        -- ---- HPS DDR4 (EMIF) ----
        DDR4_REFCLK_p : in    std_logic;
        DDR4_A        : out   std_logic_vector(16 downto 0);
        DDR4_BA       : out   std_logic_vector(1 downto 0);
        DDR4_BG       : out   std_logic_vector(0 downto 0);
        DDR4_CK       : out   std_logic;
        DDR4_CK_n     : out   std_logic;
        DDR4_CKE      : out   std_logic;
        DDR4_DQS      : inout std_logic_vector(3 downto 0);
        DDR4_DQS_n    : inout std_logic_vector(3 downto 0);
        DDR4_DQ       : inout std_logic_vector(31 downto 0);
        DDR4_DBI_n    : inout std_logic_vector(3 downto 0);
        DDR4_CS_n     : out   std_logic;
        DDR4_RESET_n  : out   std_logic;
        DDR4_ODT      : out   std_logic;
        DDR4_PAR      : out   std_logic;
        DDR4_ALERT_n  : in    std_logic;
        DDR4_ACT_n    : out   std_logic;
        DDR4_RZQ      : in    std_logic
    );
end entity de25_soc_top;

architecture rtl of de25_soc_top is

    use work.hps_axi_pkg.all;

    component h2f_user0_clk_heartbeat is
        port (
            h2f_user0_clock : in  std_logic;
            heartbeat_out   : out std_logic
        );
    end component h2f_user0_clk_heartbeat;

    -- HPS's dedicated free-running H2F User0 clock (50 MHz, independent of
    -- CLOCK0_50) - see hps/README.md's "H2F User0 clock" section and
    -- h2f_user0_clk_heartbeat.vhd.
    signal h2f_user0_clock : std_logic;

    signal ninit_done : std_logic;

    -- lwhps2fpga AXI4, hps <-> register_block (hps/hps_axi_pkg.vhd)
    signal lwh2f_m2s : t_lwh2f_m2s;
    signal lwh2f_s2m : t_lwh2f_s2m;

    -- power-on-reset-delayed reset for the HPS's own lwhps2fpga bridge
    -- hard macro (lwh2f_reset below) - see register_block.vhd's
    -- axi_bridge_reset port.
    signal lwh2f_bridge_reset : std_logic;

    -- F2SDRAM and F2H: the scope's DDR writer manages them (one at a
    -- time, scope_ddr_writer.vhd). It only writes, and Quartus refuses an
    -- enabled bus whose read data drives nothing: the parity of all they
    -- return keeps it used (register 27).
    signal f2sdram_m2s   : t_axi256_m2s;
    signal f2h_m2s       : t_axi256_m2s;
    signal f2sdram_s2m   : t_axi256_s2m;
    signal f2h_s2m       : t_axi256_s2m;
    signal bridge_parity : std_logic_vector(1 downto 0) := "00";

begin

    ------------------------------------------------------------------
    -- LWH2F register block (see register_block.vhd)
    ------------------------------------------------------------------
    u_registers : entity work.register_block
        port map (
            core_clock   => CLOCK0_50,
            CPU_RESET_n  => CPU_RESET_n,
            SW           => SW,
            KEY          => KEY,
            LEDR         => LEDR,
            HEX0         => HEX0,
            HEX1         => HEX1,
            HEX2         => HEX2,
            HEX3         => HEX3,
            HEX4         => HEX4,
            HEX5         => HEX5,

            axi_m2s      => lwh2f_m2s,
            axi_s2m      => lwh2f_s2m,

            axi_bridge_reset => lwh2f_bridge_reset,
            bridge_parity    => bridge_parity,
            f2sdram_m2s      => f2sdram_m2s,
            f2sdram_s2m      => f2sdram_s2m,
            f2h_m2s          => f2h_m2s,
            f2h_s2m          => f2h_s2m,

            FPGA_I2C_SCL => FPGA_I2C_SCL,
            FPGA_I2C_SDA => FPGA_I2C_SDA
        );

    ------------------------------------------------------------------
    -- HPS + HPS-EMIF DDR4, its AXI buses as records (hps/hps.vhd)
    ------------------------------------------------------------------
    u_hps : entity work.hps
        port map (
            DDR4_REFCLK_p => DDR4_REFCLK_p,
            DDR4_A        => DDR4_A,
            DDR4_BA       => DDR4_BA,
            DDR4_BG       => DDR4_BG,
            DDR4_CK       => DDR4_CK,
            DDR4_CK_n     => DDR4_CK_n,
            DDR4_CKE      => DDR4_CKE,
            DDR4_ODT      => DDR4_ODT,
            DDR4_CS_n     => DDR4_CS_n,
            DDR4_ACT_n    => DDR4_ACT_n,
            DDR4_PAR      => DDR4_PAR,
            DDR4_RESET_n  => DDR4_RESET_n,
            DDR4_ALERT_n  => DDR4_ALERT_n,
            DDR4_DQ       => DDR4_DQ,
            DDR4_DQS      => DDR4_DQS,
            DDR4_DQS_n    => DDR4_DQS_n,
            DDR4_DBI_n    => DDR4_DBI_n,
            DDR4_RZQ      => DDR4_RZQ,

            HPS_CLK_25        => HPS_CLK_25,
            HPS_ENET_MDC      => HPS_ENET_MDC,
            HPS_ENET_MDIO     => HPS_ENET_MDIO,
            HPS_ENET_RX_CLK   => HPS_ENET_RX_CLK,
            HPS_ENET_RX_CTL   => HPS_ENET_RX_CTL,
            HPS_ENET_RX_DATA  => HPS_ENET_RX_DATA,
            HPS_ENET_TX_CLK   => HPS_ENET_TX_CLK,
            HPS_ENET_TX_CTL   => HPS_ENET_TX_CTL,
            HPS_ENET_TX_DATA  => HPS_ENET_TX_DATA,
            HPS_I2C_SCL       => HPS_I2C_SCL,
            HPS_I2C_SDA       => HPS_I2C_SDA,
            HPS_SD_CLK        => HPS_SD_CLK,
            HPS_SD_CMD        => HPS_SD_CMD,
            HPS_SD_DATA       => HPS_SD_DATA,
            HPS_UART_RX       => HPS_UART_RX,
            HPS_UART_TX       => HPS_UART_TX,
            HPS_LCM_SPIM_CLK  => HPS_LCM_SPIM_CLK,
            HPS_LCM_SPIM_MOSI => HPS_LCM_SPIM_MOSI,
            HPS_LCM_SPIM_SS   => HPS_LCM_SPIM_SS,
            HPS_LCM_RST_n     => HPS_LCM_RST_n,
            HPS_LCM_D_C       => HPS_LCM_D_C,
            HPS_LCM_BK        => HPS_LCM_BK,

            h2f_user0_clock => h2f_user0_clock,
            ninit_done      => ninit_done,

            -- lwhps2fpga: on the register file's 50 MHz clock (no CDC).
            -- Its reset is power-on-reset-delayed, NOT the raw button (see
            -- register_block.vhd's axi_bridge_reset port) - releasing this
            -- bridge hard macro's reset before the fabric clock driving it
            -- had settled left it permanently wedged.
            lwh2f_clock => CLOCK0_50,
            lwh2f_reset => lwh2f_bridge_reset,
            lwh2f_m2s   => lwh2f_m2s,
            lwh2f_s2m   => lwh2f_s2m,

            -- f2sdram and fpga2hps: the scope's DDR writer, out of reset
            -- with the LWH2F bridge. A reset held by a constant lets
            -- synthesis remove the buses' ready-latency FIFOs, and Quartus
            -- then refuses the design (fpga/hps/README.md)
            f2sdram_clock => CLOCK0_50,
            f2sdram_reset => lwh2f_bridge_reset,
            f2sdram_m2s   => f2sdram_m2s,
            f2sdram_s2m   => f2sdram_s2m,
            f2h_clock     => CLOCK0_50,
            f2h_reset     => lwh2f_bridge_reset,
            f2h_m2s       => f2h_m2s,
            f2h_s2m       => f2h_s2m
        );

    bridge_parity_reg : process (CLOCK0_50) is
    begin
        if rising_edge(CLOCK0_50) then
            bridge_parity <= parity(f2h_s2m) & parity(f2sdram_s2m);
        end if;
    end process bridge_parity_reg;

    ------------------------------------------------------------------
    -- H2F User0 clock test - see h2f_user0_clk_heartbeat.vhd
    ------------------------------------------------------------------
    u_h2f_user0_clk_heartbeat : component h2f_user0_clk_heartbeat
        port map (
            h2f_user0_clock => h2f_user0_clock,
            heartbeat_out   => H2F_CLK_TEST
        );

end architecture rtl;
