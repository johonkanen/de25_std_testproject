------------------------------------------------------------------------
-- de25_soc_top - DE25-Standard (Agilex 5) SoC bring-up.
--
--   * hps_subsystem : Agilex 5 HPS + HPS-EMIF DDR4, EMAC0 (RGMII+MDIO),
--                     SD/MMC, UART1 console, I2C1.  H2F / F2SDRAM / the
--                     F2H ACE5-Lite port are disabled; the F2H interrupts
--                     stay enabled but are tied to 0 (unused).
--   * uart_register_block : the fpga_interconnect register file, reachable
--                     over BOTH the fabric UART (GPIO_D[0]/[1]) and the
--                     HPS's lwhps2fpga (LWH2F) AXI4 bridge - see
--                     uart_register_block.vhd and axi_lwh2f_bridge.vhd.
--
-- hps_subsystem is a Platform Designer system (hps/hps_subsystem.qsys +
-- its per-instance .ip files) instantiated directly as a VHDL component -
-- see hps/README.md.  Pin / IO-standard assignments for the HPS and DDR4
-- pins come from the DE25 GHRD (hps/hps_pins.tcl).
--
-- lwhps2fpga runs on CLOCK0_50 (see lwhps2fpga_axi_clock_clk below), the
-- same clock as the register file and the fabric UART - no clock-domain
-- crossing needed between the two masters and the registers they share.
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
        uart_rxd      : in    std_logic;                     -- GPIO_D[0]  (PIN_BK31)
        uart_txd      : out   std_logic;                     -- GPIO_D[1]  (PIN_BE43)

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

    component uart_register_block is
        generic (
            g_clock_divider : natural := 434;
            g_por_cycles    : natural := 1_048_575
        );
        port (
            core_clock   : in  std_logic;
            CPU_RESET_n  : in  std_logic;
            SW           : in  std_logic_vector(9 downto 0);
            KEY          : in  std_logic_vector(3 downto 0);
            LEDR         : out std_logic_vector(9 downto 0);
            uart_rxd     : in  std_logic;
            uart_txd     : out std_logic;

            axi_awid    : in  std_logic_vector(3 downto 0)  := (others => '0');
            axi_awaddr  : in  std_logic_vector(28 downto 0) := (others => '0');
            axi_awvalid : in  std_logic := '0';
            axi_awready : out std_logic;
            axi_wdata   : in  std_logic_vector(31 downto 0) := (others => '0');
            axi_wstrb   : in  std_logic_vector(3 downto 0)  := (others => '0');
            axi_wvalid  : in  std_logic := '0';
            axi_wready  : out std_logic;
            axi_bid     : out std_logic_vector(3 downto 0);
            axi_bresp   : out std_logic_vector(1 downto 0);
            axi_bvalid  : out std_logic;
            axi_bready  : in  std_logic := '0';
            axi_arid    : in  std_logic_vector(3 downto 0)  := (others => '0');
            axi_araddr  : in  std_logic_vector(28 downto 0) := (others => '0');
            axi_arvalid : in  std_logic := '0';
            axi_arready : out std_logic;
            axi_rid     : out std_logic_vector(3 downto 0);
            axi_rdata   : out std_logic_vector(31 downto 0);
            axi_rresp   : out std_logic_vector(1 downto 0);
            axi_rlast   : out std_logic;
            axi_rvalid  : out std_logic;
            axi_rready  : in  std_logic := '0';

            axi_bridge_reset : out std_logic
        );
    end component uart_register_block;

    -- generated by qsys-generate from hps/hps_subsystem.qsys - see
    -- hps/hps_subsystem/hps_subsystem_inst.vhd for the source of this
    -- declaration (regenerate and diff if the .qsys ever changes).
    component hps_subsystem is
        port (
            emif_io96b_hps_0_mem_0_mem_cke           : out   std_logic_vector(0 downto 0);
            emif_io96b_hps_0_mem_0_mem_odt           : out   std_logic_vector(0 downto 0);
            emif_io96b_hps_0_mem_0_mem_cs_n          : out   std_logic_vector(0 downto 0);
            emif_io96b_hps_0_mem_0_mem_a             : out   std_logic_vector(16 downto 0);
            emif_io96b_hps_0_mem_0_mem_ba            : out   std_logic_vector(1 downto 0);
            emif_io96b_hps_0_mem_0_mem_bg            : out   std_logic_vector(0 downto 0);
            emif_io96b_hps_0_mem_0_mem_act_n         : out   std_logic;
            emif_io96b_hps_0_mem_0_mem_par           : out   std_logic;
            emif_io96b_hps_0_mem_0_mem_dq            : inout std_logic_vector(31 downto 0) := (others => 'X');
            emif_io96b_hps_0_mem_0_mem_dqs_t         : inout std_logic_vector(3 downto 0)  := (others => 'X');
            emif_io96b_hps_0_mem_0_mem_dqs_c         : inout std_logic_vector(3 downto 0)  := (others => 'X');
            emif_io96b_hps_0_mem_0_mem_alert_n       : in    std_logic                     := 'X';
            emif_io96b_hps_0_mem_0_mem_dbi_n         : inout std_logic_vector(3 downto 0)  := (others => 'X');
            emif_io96b_hps_0_mem_ck_0_mem_ck_t       : out   std_logic_vector(0 downto 0);
            emif_io96b_hps_0_mem_ck_0_mem_ck_c       : out   std_logic_vector(0 downto 0);
            emif_io96b_hps_0_mem_reset_n_mem_reset_n : out   std_logic;
            emif_io96b_hps_0_oct_0_oct_rzqin         : in    std_logic                     := 'X';
            emif_io96b_hps_0_ref_clk_clk             : in    std_logic                     := 'X';
            hps_reset                                : out   std_logic;
            lwhps2fpga_axi_clock_clk                 : in    std_logic                     := 'X';
            lwhps2fpga_axi_reset_reset                : in    std_logic                     := 'X';
            lwhps2fpga_awid                          : out   std_logic_vector(3 downto 0);
            lwhps2fpga_awaddr                        : out   std_logic_vector(28 downto 0);
            lwhps2fpga_awlen                         : out   std_logic_vector(7 downto 0);
            lwhps2fpga_awsize                        : out   std_logic_vector(2 downto 0);
            lwhps2fpga_awburst                       : out   std_logic_vector(1 downto 0);
            lwhps2fpga_awlock                        : out   std_logic;
            lwhps2fpga_awcache                       : out   std_logic_vector(3 downto 0);
            lwhps2fpga_awprot                        : out   std_logic_vector(2 downto 0);
            lwhps2fpga_awvalid                       : out   std_logic;
            lwhps2fpga_awready                       : in    std_logic                     := 'X';
            lwhps2fpga_wdata                         : out   std_logic_vector(31 downto 0);
            lwhps2fpga_wstrb                         : out   std_logic_vector(3 downto 0);
            lwhps2fpga_wlast                         : out   std_logic;
            lwhps2fpga_wvalid                        : out   std_logic;
            lwhps2fpga_wready                        : in    std_logic                     := 'X';
            lwhps2fpga_bid                           : in    std_logic_vector(3 downto 0)  := (others => 'X');
            lwhps2fpga_bresp                         : in    std_logic_vector(1 downto 0)  := (others => 'X');
            lwhps2fpga_bvalid                        : in    std_logic                     := 'X';
            lwhps2fpga_bready                        : out   std_logic;
            lwhps2fpga_arid                          : out   std_logic_vector(3 downto 0);
            lwhps2fpga_araddr                        : out   std_logic_vector(28 downto 0);
            lwhps2fpga_arlen                         : out   std_logic_vector(7 downto 0);
            lwhps2fpga_arsize                        : out   std_logic_vector(2 downto 0);
            lwhps2fpga_arburst                       : out   std_logic_vector(1 downto 0);
            lwhps2fpga_arlock                        : out   std_logic;
            lwhps2fpga_arcache                       : out   std_logic_vector(3 downto 0);
            lwhps2fpga_arprot                        : out   std_logic_vector(2 downto 0);
            lwhps2fpga_arvalid                       : out   std_logic;
            lwhps2fpga_arready                       : in    std_logic                     := 'X';
            lwhps2fpga_rid                           : in    std_logic_vector(3 downto 0)  := (others => 'X');
            lwhps2fpga_rdata                         : in    std_logic_vector(31 downto 0) := (others => 'X');
            lwhps2fpga_rresp                         : in    std_logic_vector(1 downto 0)  := (others => 'X');
            lwhps2fpga_rlast                         : in    std_logic                     := 'X';
            lwhps2fpga_rvalid                        : in    std_logic                     := 'X';
            lwhps2fpga_rready                        : out   std_logic;
            hps_io_hps_osc_clk                       : in    std_logic                     := 'X';
            hps_io_sdmmc_data0                       : inout std_logic                     := 'X';
            hps_io_sdmmc_data1                       : inout std_logic                     := 'X';
            hps_io_sdmmc_cclk                        : out   std_logic;
            hps_io_sdmmc_data2                       : inout std_logic                     := 'X';
            hps_io_sdmmc_data3                       : inout std_logic                     := 'X';
            hps_io_sdmmc_cmd                         : inout std_logic                     := 'X';
            hps_io_emac0_tx_clk                      : out   std_logic;
            hps_io_emac0_tx_ctl                      : out   std_logic;
            hps_io_emac0_rx_clk                      : in    std_logic                     := 'X';
            hps_io_emac0_rx_ctl                      : in    std_logic                     := 'X';
            hps_io_emac0_txd0                        : out   std_logic;
            hps_io_emac0_txd1                        : out   std_logic;
            hps_io_emac0_rxd0                        : in    std_logic                     := 'X';
            hps_io_emac0_rxd1                        : in    std_logic                     := 'X';
            hps_io_emac0_txd2                        : out   std_logic;
            hps_io_emac0_txd3                        : out   std_logic;
            hps_io_emac0_rxd2                        : in    std_logic                     := 'X';
            hps_io_emac0_rxd3                        : in    std_logic                     := 'X';
            hps_io_mdio0_mdio                        : inout std_logic                     := 'X';
            hps_io_mdio0_mdc                         : out   std_logic;
            hps_io_uart1_tx                          : out   std_logic;
            hps_io_uart1_rx                          : in    std_logic                     := 'X';
            hps_io_i2c1_sda                          : inout std_logic                     := 'X';
            hps_io_i2c1_scl                          : inout std_logic                     := 'X';
            fpga2hps_interrupt_irq1_irq              : in    std_logic_vector(31 downto 0) := (others => 'X');
            fpga2hps_interrupt_irq0_irq              : in    std_logic_vector(31 downto 0) := (others => 'X');
            ninit_done_ninit_done                    : out   std_logic
        );
    end component hps_subsystem;

    signal ninit_done : std_logic;

    -- lwhps2fpga AXI4, hps_subsystem <-> uart_register_block
    signal lwh2f_awid    : std_logic_vector(3 downto 0);
    signal lwh2f_awaddr  : std_logic_vector(28 downto 0);
    signal lwh2f_awvalid : std_logic;
    signal lwh2f_awready : std_logic;
    signal lwh2f_wdata   : std_logic_vector(31 downto 0);
    signal lwh2f_wstrb   : std_logic_vector(3 downto 0);
    signal lwh2f_wvalid  : std_logic;
    signal lwh2f_wready  : std_logic;
    signal lwh2f_bid     : std_logic_vector(3 downto 0);
    signal lwh2f_bresp   : std_logic_vector(1 downto 0);
    signal lwh2f_bvalid  : std_logic;
    signal lwh2f_bready  : std_logic;
    signal lwh2f_arid    : std_logic_vector(3 downto 0);
    signal lwh2f_araddr  : std_logic_vector(28 downto 0);
    signal lwh2f_arvalid : std_logic;
    signal lwh2f_arready : std_logic;
    signal lwh2f_rid     : std_logic_vector(3 downto 0);
    signal lwh2f_rdata   : std_logic_vector(31 downto 0);
    signal lwh2f_rresp   : std_logic_vector(1 downto 0);
    signal lwh2f_rlast   : std_logic;
    signal lwh2f_rvalid  : std_logic;
    signal lwh2f_rready  : std_logic;

    -- power-on-reset-delayed reset for the HPS's own lwhps2fpga bridge
    -- hard macro (lwhps2fpga_axi_reset_reset below) - see
    -- uart_register_block.vhd's axi_bridge_reset port.
    signal lwh2f_bridge_reset : std_logic;

begin

    ------------------------------------------------------------------
    -- fabric UART + LWH2F register block (see uart_register_block.vhd)
    ------------------------------------------------------------------
    u_registers : component uart_register_block
        port map (
            core_clock   => CLOCK0_50,
            CPU_RESET_n  => CPU_RESET_n,
            SW           => SW,
            KEY          => KEY,
            LEDR         => LEDR,
            uart_rxd     => uart_rxd,
            uart_txd     => uart_txd,

            axi_awid    => lwh2f_awid,
            axi_awaddr  => lwh2f_awaddr,
            axi_awvalid => lwh2f_awvalid,
            axi_awready => lwh2f_awready,
            axi_wdata   => lwh2f_wdata,
            axi_wstrb   => lwh2f_wstrb,
            axi_wvalid  => lwh2f_wvalid,
            axi_wready  => lwh2f_wready,
            axi_bid     => lwh2f_bid,
            axi_bresp   => lwh2f_bresp,
            axi_bvalid  => lwh2f_bvalid,
            axi_bready  => lwh2f_bready,
            axi_arid    => lwh2f_arid,
            axi_araddr  => lwh2f_araddr,
            axi_arvalid => lwh2f_arvalid,
            axi_arready => lwh2f_arready,
            axi_rid     => lwh2f_rid,
            axi_rdata   => lwh2f_rdata,
            axi_rresp   => lwh2f_rresp,
            axi_rlast   => lwh2f_rlast,
            axi_rvalid  => lwh2f_rvalid,
            axi_rready  => lwh2f_rready,

            axi_bridge_reset => lwh2f_bridge_reset
        );

    ------------------------------------------------------------------
    -- HPS + HPS-EMIF DDR4 (see hps/hps_subsystem.qsys, GENERATED)
    ------------------------------------------------------------------
    u_hps : component hps_subsystem
        port map (
            emif_io96b_hps_0_mem_0_mem_cke(0)        => DDR4_CKE,
            emif_io96b_hps_0_mem_0_mem_odt(0)         => DDR4_ODT,
            emif_io96b_hps_0_mem_0_mem_cs_n(0)        => DDR4_CS_n,
            emif_io96b_hps_0_mem_0_mem_a              => DDR4_A,
            emif_io96b_hps_0_mem_0_mem_ba             => DDR4_BA,
            emif_io96b_hps_0_mem_0_mem_bg             => DDR4_BG,
            emif_io96b_hps_0_mem_0_mem_act_n          => DDR4_ACT_n,
            emif_io96b_hps_0_mem_0_mem_par            => DDR4_PAR,
            emif_io96b_hps_0_mem_0_mem_dq             => DDR4_DQ,
            emif_io96b_hps_0_mem_0_mem_dqs_t          => DDR4_DQS,
            emif_io96b_hps_0_mem_0_mem_dqs_c          => DDR4_DQS_n,
            emif_io96b_hps_0_mem_0_mem_alert_n        => DDR4_ALERT_n,
            emif_io96b_hps_0_mem_0_mem_dbi_n          => DDR4_DBI_n,
            emif_io96b_hps_0_mem_ck_0_mem_ck_t(0)     => DDR4_CK,
            emif_io96b_hps_0_mem_ck_0_mem_ck_c(0)     => DDR4_CK_n,
            emif_io96b_hps_0_mem_reset_n_mem_reset_n  => DDR4_RESET_n,
            emif_io96b_hps_0_oct_0_oct_rzqin          => DDR4_RZQ,
            emif_io96b_hps_0_ref_clk_clk              => DDR4_REFCLK_p,

            hps_reset                                 => open,

            -- lwhps2fpga: wired straight into uart_register_block, on the
            -- same 50 MHz clock as the register file (no CDC needed).
            lwhps2fpga_axi_clock_clk                  => CLOCK0_50,
            -- power-on-reset-delayed, NOT the raw button (see
            -- uart_register_block.vhd's axi_bridge_reset port) - releasing
            -- this bridge hard macro's reset before the FPGA fabric clock
            -- driving it has settled left it permanently wedged.
            lwhps2fpga_axi_reset_reset                => lwh2f_bridge_reset,
            lwhps2fpga_awid                           => lwh2f_awid,
            lwhps2fpga_awaddr                         => lwh2f_awaddr,
            lwhps2fpga_awvalid                        => lwh2f_awvalid,
            lwhps2fpga_awready                        => lwh2f_awready,
            lwhps2fpga_wdata                          => lwh2f_wdata,
            lwhps2fpga_wstrb                          => lwh2f_wstrb,
            lwhps2fpga_wvalid                         => lwh2f_wvalid,
            lwhps2fpga_wready                         => lwh2f_wready,
            lwhps2fpga_bid                            => lwh2f_bid,
            lwhps2fpga_bresp                          => lwh2f_bresp,
            lwhps2fpga_bvalid                         => lwh2f_bvalid,
            lwhps2fpga_bready                         => lwh2f_bready,
            lwhps2fpga_arid                           => lwh2f_arid,
            lwhps2fpga_araddr                         => lwh2f_araddr,
            lwhps2fpga_arvalid                        => lwh2f_arvalid,
            lwhps2fpga_arready                        => lwh2f_arready,
            lwhps2fpga_rid                            => lwh2f_rid,
            lwhps2fpga_rdata                          => lwh2f_rdata,
            lwhps2fpga_rresp                          => lwh2f_rresp,
            lwhps2fpga_rlast                          => lwh2f_rlast,
            lwhps2fpga_rvalid                         => lwh2f_rvalid,
            lwhps2fpga_rready                         => lwh2f_rready,
            -- AXI4 burst fields the bridge doesn't use (single-beat only)
            lwhps2fpga_awlen                          => open,
            lwhps2fpga_awsize                         => open,
            lwhps2fpga_awburst                        => open,
            lwhps2fpga_awlock                         => open,
            lwhps2fpga_awcache                        => open,
            lwhps2fpga_awprot                         => open,
            lwhps2fpga_arlen                          => open,
            lwhps2fpga_arsize                         => open,
            lwhps2fpga_arburst                        => open,
            lwhps2fpga_arlock                         => open,
            lwhps2fpga_arcache                        => open,
            lwhps2fpga_arprot                         => open,

            hps_io_hps_osc_clk                        => HPS_CLK_25,
            hps_io_sdmmc_data0                        => HPS_SD_DATA(0),
            hps_io_sdmmc_data1                        => HPS_SD_DATA(1),
            hps_io_sdmmc_cclk                         => HPS_SD_CLK,
            hps_io_sdmmc_data2                        => HPS_SD_DATA(2),
            hps_io_sdmmc_data3                        => HPS_SD_DATA(3),
            hps_io_sdmmc_cmd                          => HPS_SD_CMD,
            hps_io_emac0_tx_clk                       => HPS_ENET_TX_CLK,
            hps_io_emac0_tx_ctl                       => HPS_ENET_TX_CTL,
            hps_io_emac0_rx_clk                       => HPS_ENET_RX_CLK,
            hps_io_emac0_rx_ctl                       => HPS_ENET_RX_CTL,
            hps_io_emac0_txd0                         => HPS_ENET_TX_DATA(0),
            hps_io_emac0_txd1                         => HPS_ENET_TX_DATA(1),
            hps_io_emac0_rxd0                         => HPS_ENET_RX_DATA(0),
            hps_io_emac0_rxd1                         => HPS_ENET_RX_DATA(1),
            hps_io_emac0_txd2                         => HPS_ENET_TX_DATA(2),
            hps_io_emac0_txd3                         => HPS_ENET_TX_DATA(3),
            hps_io_emac0_rxd2                         => HPS_ENET_RX_DATA(2),
            hps_io_emac0_rxd3                         => HPS_ENET_RX_DATA(3),
            hps_io_mdio0_mdio                         => HPS_ENET_MDIO,
            hps_io_mdio0_mdc                          => HPS_ENET_MDC,
            hps_io_uart1_tx                           => HPS_UART_TX,
            hps_io_uart1_rx                           => HPS_UART_RX,
            hps_io_i2c1_sda                           => HPS_I2C_SDA,
            hps_io_i2c1_scl                           => HPS_I2C_SCL,

            -- F2H interrupts: left enabled (sibling-style) but unused
            fpga2hps_interrupt_irq0_irq                => (others => '0'),
            fpga2hps_interrupt_irq1_irq                => (others => '0'),

            ninit_done_ninit_done                     => ninit_done
        );

end architecture rtl;
