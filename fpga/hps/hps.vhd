------------------------------------------------------------------------
-- hps - the HPS (hps/hps_subsystem.qsys, generated) with its AXI buses as
-- records (hps_axi_pkg.vhd): one record in and one out per bus, instead of
-- the generated component's 190-odd separate ports.
--
--   lwh2f    HPS -> fabric, AXI4 32 bit: the register file (register_block)
--   f2sdram  fabric -> DDR4, AXI4 256 bit, not cache coherent
--   f2h      fabric -> HPS (fpga2hps), ACE5-Lite 256 bit, through the CCU
--
-- Each bus has its own clock and reset input. The fabric-managed buses'
-- inputs default to idle, so a design that does not use one leaves it open
-- (its clock should then still run, and its reset stay asserted).
--
-- The pins (DDR4, HPS IO) stay separate signals: they are the top level's
-- pins. The component declaration below is the generated one
-- (build/fpga/hps/hps_subsystem/hps_subsystem_inst.vhd); regenerate and
-- compare it after any change to the .qsys or the HPS .ip.
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use work.hps_axi_pkg.all;

entity hps is
    port (
        -- ---- DDR4 (HPS EMIF) ----
        DDR4_REFCLK_p : in    std_logic;
        DDR4_A        : out   std_logic_vector(16 downto 0);
        DDR4_BA       : out   std_logic_vector(1 downto 0);
        DDR4_BG       : out   std_logic_vector(0 downto 0);
        DDR4_CK       : out   std_logic;
        DDR4_CK_n     : out   std_logic;
        DDR4_CKE      : out   std_logic;
        DDR4_ODT      : out   std_logic;
        DDR4_CS_n     : out   std_logic;
        DDR4_ACT_n    : out   std_logic;
        DDR4_PAR      : out   std_logic;
        DDR4_RESET_n  : out   std_logic;
        DDR4_ALERT_n  : in    std_logic;
        DDR4_DQ       : inout std_logic_vector(31 downto 0);
        DDR4_DQS      : inout std_logic_vector(3 downto 0);
        DDR4_DQS_n    : inout std_logic_vector(3 downto 0);
        DDR4_DBI_n    : inout std_logic_vector(3 downto 0);
        DDR4_RZQ      : in    std_logic;

        -- ---- HPS IO ----
        HPS_CLK_25        : in    std_logic;
        HPS_ENET_MDC      : out   std_logic;
        HPS_ENET_MDIO     : inout std_logic;
        HPS_ENET_RX_CLK   : in    std_logic;
        HPS_ENET_RX_CTL   : in    std_logic;
        HPS_ENET_RX_DATA  : in    std_logic_vector(3 downto 0);
        HPS_ENET_TX_CLK   : out   std_logic;
        HPS_ENET_TX_CTL   : out   std_logic;
        HPS_ENET_TX_DATA  : out   std_logic_vector(3 downto 0);
        HPS_I2C_SCL       : inout std_logic;
        HPS_I2C_SDA       : inout std_logic;
        HPS_SD_CLK        : out   std_logic;
        HPS_SD_CMD        : inout std_logic;
        HPS_SD_DATA       : inout std_logic_vector(3 downto 0);
        HPS_UART_RX       : in    std_logic;
        HPS_UART_TX       : out   std_logic;
        HPS_LCM_SPIM_CLK  : out   std_logic;
        HPS_LCM_SPIM_MOSI : out   std_logic;
        HPS_LCM_SPIM_SS   : out   std_logic;
        HPS_LCM_RST_n     : inout std_logic;
        HPS_LCM_D_C       : inout std_logic;
        HPS_LCM_BK        : inout std_logic;

        -- ---- clocks, resets, interrupts ----
        h2f_user0_clock : out std_logic;     -- 50 MHz, free running
        ninit_done      : out std_logic;     -- 0 once the device is in user mode
        f2h_irq0        : in  std_logic_vector(31 downto 0) := (others => '0');
        f2h_irq1        : in  std_logic_vector(31 downto 0) := (others => '0');

        -- ---- lwhps2fpga: the HPS manages ----
        lwh2f_clock : in  std_logic;
        lwh2f_reset : in  std_logic;         -- active high
        lwh2f_m2s   : out t_lwh2f_m2s;
        lwh2f_s2m   : in  t_lwh2f_s2m := c_lwh2f_s2m_idle;

        -- ---- f2sdram: the fabric manages, into the DDR ----
        f2sdram_clock : in  std_logic;
        f2sdram_reset : in  std_logic := '1';
        f2sdram_m2s   : in  t_axi256_m2s := c_axi256_m2s_idle;
        f2sdram_s2m   : out t_axi256_s2m;

        -- ---- fpga2hps: the fabric manages, through the CCU ----
        f2h_clock : in  std_logic;
        f2h_reset : in  std_logic := '1';
        f2h_m2s   : in  t_axi256_m2s := c_axi256_m2s_idle;
        f2h_s2m   : out t_axi256_s2m
    );
end entity hps;

architecture rtl of hps is

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
            emif_io96b_hps_0_mem_0_mem_dqs_t         : inout std_logic_vector(3 downto 0) := (others => 'X');
            emif_io96b_hps_0_mem_0_mem_dqs_c         : inout std_logic_vector(3 downto 0) := (others => 'X');
            emif_io96b_hps_0_mem_0_mem_alert_n       : in    std_logic := 'X';
            emif_io96b_hps_0_mem_0_mem_dbi_n         : inout std_logic_vector(3 downto 0) := (others => 'X');
            emif_io96b_hps_0_mem_ck_0_mem_ck_t       : out   std_logic_vector(0 downto 0);
            emif_io96b_hps_0_mem_ck_0_mem_ck_c       : out   std_logic_vector(0 downto 0);
            emif_io96b_hps_0_mem_reset_n_mem_reset_n : out   std_logic;
            emif_io96b_hps_0_oct_0_oct_rzqin         : in    std_logic := 'X';
            emif_io96b_hps_0_ref_clk_clk             : in    std_logic := 'X';
            hps_reset                                : out   std_logic;
            lwhps2fpga_axi_clock_clk                 : in    std_logic := 'X';
            lwhps2fpga_axi_reset_reset               : in    std_logic := 'X';
            f2sdram_axi_clock_clk                    : in    std_logic := 'X';
            f2sdram_axi_reset_reset                  : in    std_logic := 'X';
            f2sdram_araddr                           : in    std_logic_vector(31 downto 0) := (others => 'X');
            f2sdram_arburst                          : in    std_logic_vector(1 downto 0) := (others => 'X');
            f2sdram_arcache                          : in    std_logic_vector(3 downto 0) := (others => 'X');
            f2sdram_arid                             : in    std_logic_vector(4 downto 0) := (others => 'X');
            f2sdram_arlen                            : in    std_logic_vector(7 downto 0) := (others => 'X');
            f2sdram_arlock                           : in    std_logic := 'X';
            f2sdram_arprot                           : in    std_logic_vector(2 downto 0) := (others => 'X');
            f2sdram_arqos                            : in    std_logic_vector(3 downto 0) := (others => 'X');
            f2sdram_arready                          : out   std_logic;
            f2sdram_arsize                           : in    std_logic_vector(2 downto 0) := (others => 'X');
            f2sdram_arvalid                          : in    std_logic := 'X';
            f2sdram_awaddr                           : in    std_logic_vector(31 downto 0) := (others => 'X');
            f2sdram_awburst                          : in    std_logic_vector(1 downto 0) := (others => 'X');
            f2sdram_awcache                          : in    std_logic_vector(3 downto 0) := (others => 'X');
            f2sdram_awid                             : in    std_logic_vector(4 downto 0) := (others => 'X');
            f2sdram_awlen                            : in    std_logic_vector(7 downto 0) := (others => 'X');
            f2sdram_awlock                           : in    std_logic := 'X';
            f2sdram_awprot                           : in    std_logic_vector(2 downto 0) := (others => 'X');
            f2sdram_awqos                            : in    std_logic_vector(3 downto 0) := (others => 'X');
            f2sdram_awready                          : out   std_logic;
            f2sdram_awsize                           : in    std_logic_vector(2 downto 0) := (others => 'X');
            f2sdram_awvalid                          : in    std_logic := 'X';
            f2sdram_bid                              : out   std_logic_vector(4 downto 0);
            f2sdram_bready                           : in    std_logic := 'X';
            f2sdram_bresp                            : out   std_logic_vector(1 downto 0);
            f2sdram_bvalid                           : out   std_logic;
            f2sdram_rdata                            : out   std_logic_vector(255 downto 0);
            f2sdram_rid                              : out   std_logic_vector(4 downto 0);
            f2sdram_rlast                            : out   std_logic;
            f2sdram_rready                           : in    std_logic := 'X';
            f2sdram_rresp                            : out   std_logic_vector(1 downto 0);
            f2sdram_rvalid                           : out   std_logic;
            f2sdram_wdata                            : in    std_logic_vector(255 downto 0) := (others => 'X');
            f2sdram_wlast                            : in    std_logic := 'X';
            f2sdram_wready                           : out   std_logic;
            f2sdram_wstrb                            : in    std_logic_vector(31 downto 0) := (others => 'X');
            f2sdram_wvalid                           : in    std_logic := 'X';
            f2sdram_aruser                           : in    std_logic_vector(7 downto 0) := (others => 'X');
            f2sdram_awuser                           : in    std_logic_vector(7 downto 0) := (others => 'X');
            f2sdram_wuser                            : in    std_logic_vector(7 downto 0) := (others => 'X');
            f2sdram_buser                            : out   std_logic_vector(7 downto 0);
            f2sdram_arregion                         : in    std_logic_vector(3 downto 0) := (others => 'X');
            f2sdram_ruser                            : out   std_logic_vector(7 downto 0);
            f2sdram_awregion                         : in    std_logic_vector(3 downto 0) := (others => 'X');
            fpga2hps_clock_clk                       : in    std_logic := 'X';
            fpga2hps_reset_reset                     : in    std_logic := 'X';
            fpga2hps_awid                            : in    std_logic_vector(4 downto 0) := (others => 'X');
            fpga2hps_awaddr                          : in    std_logic_vector(31 downto 0) := (others => 'X');
            fpga2hps_awdomain                        : in    std_logic_vector(1 downto 0) := (others => 'X');
            fpga2hps_awsnoop                         : in    std_logic_vector(3 downto 0) := (others => 'X');
            fpga2hps_awlen                           : in    std_logic_vector(7 downto 0) := (others => 'X');
            fpga2hps_awsize                          : in    std_logic_vector(2 downto 0) := (others => 'X');
            fpga2hps_arsize                          : in    std_logic_vector(2 downto 0) := (others => 'X');
            fpga2hps_awburst                         : in    std_logic_vector(1 downto 0) := (others => 'X');
            fpga2hps_awlock                          : in    std_logic := 'X';
            fpga2hps_awcache                         : in    std_logic_vector(3 downto 0) := (others => 'X');
            fpga2hps_awprot                          : in    std_logic_vector(2 downto 0) := (others => 'X');
            fpga2hps_awqos                           : in    std_logic_vector(3 downto 0) := (others => 'X');
            fpga2hps_awvalid                         : in    std_logic := 'X';
            fpga2hps_awready                         : out   std_logic;
            fpga2hps_wdata                           : in    std_logic_vector(255 downto 0) := (others => 'X');
            fpga2hps_wstrb                           : in    std_logic_vector(31 downto 0) := (others => 'X');
            fpga2hps_wlast                           : in    std_logic := 'X';
            fpga2hps_wvalid                          : in    std_logic := 'X';
            fpga2hps_wready                          : out   std_logic;
            fpga2hps_awstashnid                      : in    std_logic_vector(10 downto 0) := (others => 'X');
            fpga2hps_awstashniden                    : in    std_logic := 'X';
            fpga2hps_awstashlpid                     : in    std_logic_vector(4 downto 0) := (others => 'X');
            fpga2hps_awstashlpiden                   : in    std_logic := 'X';
            fpga2hps_awatop                          : in    std_logic_vector(5 downto 0) := (others => 'X');
            fpga2hps_bid                             : out   std_logic_vector(4 downto 0);
            fpga2hps_bresp                           : out   std_logic_vector(1 downto 0);
            fpga2hps_bvalid                          : out   std_logic;
            fpga2hps_bready                          : in    std_logic := 'X';
            fpga2hps_arid                            : in    std_logic_vector(4 downto 0) := (others => 'X');
            fpga2hps_araddr                          : in    std_logic_vector(31 downto 0) := (others => 'X');
            fpga2hps_ardomain                        : in    std_logic_vector(1 downto 0) := (others => 'X');
            fpga2hps_arsnoop                         : in    std_logic_vector(3 downto 0) := (others => 'X');
            fpga2hps_arlen                           : in    std_logic_vector(7 downto 0) := (others => 'X');
            fpga2hps_arburst                         : in    std_logic_vector(1 downto 0) := (others => 'X');
            fpga2hps_arlock                          : in    std_logic := 'X';
            fpga2hps_arcache                         : in    std_logic_vector(3 downto 0) := (others => 'X');
            fpga2hps_arprot                          : in    std_logic_vector(2 downto 0) := (others => 'X');
            fpga2hps_arqos                           : in    std_logic_vector(3 downto 0) := (others => 'X');
            fpga2hps_arvalid                         : in    std_logic := 'X';
            fpga2hps_arready                         : out   std_logic;
            fpga2hps_rid                             : out   std_logic_vector(4 downto 0);
            fpga2hps_rdata                           : out   std_logic_vector(255 downto 0);
            fpga2hps_rresp                           : out   std_logic_vector(1 downto 0);
            fpga2hps_rlast                           : out   std_logic;
            fpga2hps_rvalid                          : out   std_logic;
            fpga2hps_rready                          : in    std_logic := 'X';
            fpga2hps_aruser                          : in    std_logic_vector(7 downto 0) := (others => 'X');
            fpga2hps_awuser                          : in    std_logic_vector(7 downto 0) := (others => 'X');
            fpga2hps_arregion                        : in    std_logic_vector(3 downto 0) := (others => 'X');
            fpga2hps_awregion                        : in    std_logic_vector(3 downto 0) := (others => 'X');
            fpga2hps_wuser                           : in    std_logic_vector(7 downto 0) := (others => 'X');
            fpga2hps_buser                           : out   std_logic_vector(7 downto 0);
            fpga2hps_ruser                           : out   std_logic_vector(7 downto 0);
            lwhps2fpga_awid                          : out   std_logic_vector(3 downto 0);
            lwhps2fpga_awaddr                        : out   std_logic_vector(28 downto 0);
            lwhps2fpga_awlen                         : out   std_logic_vector(7 downto 0);
            lwhps2fpga_awsize                        : out   std_logic_vector(2 downto 0);
            lwhps2fpga_awburst                       : out   std_logic_vector(1 downto 0);
            lwhps2fpga_awlock                        : out   std_logic;
            lwhps2fpga_awcache                       : out   std_logic_vector(3 downto 0);
            lwhps2fpga_awprot                        : out   std_logic_vector(2 downto 0);
            lwhps2fpga_awvalid                       : out   std_logic;
            lwhps2fpga_awready                       : in    std_logic := 'X';
            lwhps2fpga_wdata                         : out   std_logic_vector(31 downto 0);
            lwhps2fpga_wstrb                         : out   std_logic_vector(3 downto 0);
            lwhps2fpga_wlast                         : out   std_logic;
            lwhps2fpga_wvalid                        : out   std_logic;
            lwhps2fpga_wready                        : in    std_logic := 'X';
            lwhps2fpga_bid                           : in    std_logic_vector(3 downto 0) := (others => 'X');
            lwhps2fpga_bresp                         : in    std_logic_vector(1 downto 0) := (others => 'X');
            lwhps2fpga_bvalid                        : in    std_logic := 'X';
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
            lwhps2fpga_arready                       : in    std_logic := 'X';
            lwhps2fpga_rid                           : in    std_logic_vector(3 downto 0) := (others => 'X');
            lwhps2fpga_rdata                         : in    std_logic_vector(31 downto 0) := (others => 'X');
            lwhps2fpga_rresp                         : in    std_logic_vector(1 downto 0) := (others => 'X');
            lwhps2fpga_rlast                         : in    std_logic := 'X';
            lwhps2fpga_rvalid                        : in    std_logic := 'X';
            lwhps2fpga_rready                        : out   std_logic;
            h2f_user0_clock_clk                      : out   std_logic;
            hps_io_hps_osc_clk                       : in    std_logic := 'X';
            hps_io_sdmmc_data0                       : inout std_logic := 'X';
            hps_io_sdmmc_data1                       : inout std_logic := 'X';
            hps_io_sdmmc_cclk                        : out   std_logic;
            hps_io_sdmmc_data2                       : inout std_logic := 'X';
            hps_io_sdmmc_data3                       : inout std_logic := 'X';
            hps_io_sdmmc_cmd                         : inout std_logic := 'X';
            hps_io_emac0_tx_clk                      : out   std_logic;
            hps_io_emac0_tx_ctl                      : out   std_logic;
            hps_io_emac0_rx_clk                      : in    std_logic := 'X';
            hps_io_emac0_rx_ctl                      : in    std_logic := 'X';
            hps_io_emac0_txd0                        : out   std_logic;
            hps_io_emac0_txd1                        : out   std_logic;
            hps_io_emac0_rxd0                        : in    std_logic := 'X';
            hps_io_emac0_rxd1                        : in    std_logic := 'X';
            hps_io_emac0_txd2                        : out   std_logic;
            hps_io_emac0_txd3                        : out   std_logic;
            hps_io_emac0_rxd2                        : in    std_logic := 'X';
            hps_io_emac0_rxd3                        : in    std_logic := 'X';
            hps_io_mdio0_mdio                        : inout std_logic := 'X';
            hps_io_mdio0_mdc                         : out   std_logic;
            hps_io_spim0_clk                         : out   std_logic;
            hps_io_spim0_mosi                        : out   std_logic;
            hps_io_spim0_ss0_n                       : out   std_logic;
            hps_io_uart1_tx                          : out   std_logic;
            hps_io_uart1_rx                          : in    std_logic := 'X';
            hps_io_i2c1_sda                          : inout std_logic := 'X';
            hps_io_i2c1_scl                          : inout std_logic := 'X';
            hps_io_gpio34                            : inout std_logic := 'X';
            hps_io_gpio35                            : inout std_logic := 'X';
            hps_io_gpio42                            : inout std_logic := 'X';
            fpga2hps_interrupt_irq1_irq              : in    std_logic_vector(31 downto 0) := (others => 'X');
            fpga2hps_interrupt_irq0_irq              : in    std_logic_vector(31 downto 0) := (others => 'X');
            ninit_done_ninit_done                    : out   std_logic
        );
    end component hps_subsystem;

begin

    u_hps_subsystem : component hps_subsystem
        port map (
            emif_io96b_hps_0_mem_0_mem_cke(0)        => DDR4_CKE,
            emif_io96b_hps_0_mem_0_mem_odt(0)        => DDR4_ODT,
            emif_io96b_hps_0_mem_0_mem_cs_n(0)       => DDR4_CS_n,
            emif_io96b_hps_0_mem_0_mem_a             => DDR4_A,
            emif_io96b_hps_0_mem_0_mem_ba            => DDR4_BA,
            emif_io96b_hps_0_mem_0_mem_bg            => DDR4_BG,
            emif_io96b_hps_0_mem_0_mem_act_n         => DDR4_ACT_n,
            emif_io96b_hps_0_mem_0_mem_par           => DDR4_PAR,
            emif_io96b_hps_0_mem_0_mem_dq            => DDR4_DQ,
            emif_io96b_hps_0_mem_0_mem_dqs_t         => DDR4_DQS,
            emif_io96b_hps_0_mem_0_mem_dqs_c         => DDR4_DQS_n,
            emif_io96b_hps_0_mem_0_mem_alert_n       => DDR4_ALERT_n,
            emif_io96b_hps_0_mem_0_mem_dbi_n         => DDR4_DBI_n,
            emif_io96b_hps_0_mem_ck_0_mem_ck_t(0)    => DDR4_CK,
            emif_io96b_hps_0_mem_ck_0_mem_ck_c(0)    => DDR4_CK_n,
            emif_io96b_hps_0_mem_reset_n_mem_reset_n => DDR4_RESET_n,
            emif_io96b_hps_0_oct_0_oct_rzqin         => DDR4_RZQ,
            emif_io96b_hps_0_ref_clk_clk             => DDR4_REFCLK_p,

            hps_reset                                => open,

            hps_io_hps_osc_clk                       => HPS_CLK_25,
            hps_io_sdmmc_data0                       => HPS_SD_DATA(0),
            hps_io_sdmmc_data1                       => HPS_SD_DATA(1),
            hps_io_sdmmc_cclk                        => HPS_SD_CLK,
            hps_io_sdmmc_data2                       => HPS_SD_DATA(2),
            hps_io_sdmmc_data3                       => HPS_SD_DATA(3),
            hps_io_sdmmc_cmd                         => HPS_SD_CMD,
            hps_io_emac0_tx_clk                      => HPS_ENET_TX_CLK,
            hps_io_emac0_tx_ctl                      => HPS_ENET_TX_CTL,
            hps_io_emac0_rx_clk                      => HPS_ENET_RX_CLK,
            hps_io_emac0_rx_ctl                      => HPS_ENET_RX_CTL,
            hps_io_emac0_txd0                        => HPS_ENET_TX_DATA(0),
            hps_io_emac0_txd1                        => HPS_ENET_TX_DATA(1),
            hps_io_emac0_rxd0                        => HPS_ENET_RX_DATA(0),
            hps_io_emac0_rxd1                        => HPS_ENET_RX_DATA(1),
            hps_io_emac0_txd2                        => HPS_ENET_TX_DATA(2),
            hps_io_emac0_txd3                        => HPS_ENET_TX_DATA(3),
            hps_io_emac0_rxd2                        => HPS_ENET_RX_DATA(2),
            hps_io_emac0_rxd3                        => HPS_ENET_RX_DATA(3),
            hps_io_mdio0_mdio                        => HPS_ENET_MDIO,
            hps_io_mdio0_mdc                         => HPS_ENET_MDC,
            hps_io_uart1_tx                          => HPS_UART_TX,
            hps_io_uart1_rx                          => HPS_UART_RX,
            hps_io_i2c1_sda                          => HPS_I2C_SDA,
            hps_io_i2c1_scl                          => HPS_I2C_SCL,
            -- LCD (Terasic GHRD: GPIO1 IO10 = RST_n, IO11 = D/C, IO18 = backlight)
            hps_io_spim0_clk                         => HPS_LCM_SPIM_CLK,
            hps_io_spim0_mosi                        => HPS_LCM_SPIM_MOSI,
            hps_io_spim0_ss0_n                       => HPS_LCM_SPIM_SS,
            hps_io_gpio34                            => HPS_LCM_RST_n,
            hps_io_gpio35                            => HPS_LCM_D_C,
            hps_io_gpio42                            => HPS_LCM_BK,

            fpga2hps_interrupt_irq0_irq              => f2h_irq0,
            fpga2hps_interrupt_irq1_irq              => f2h_irq1,
            ninit_done_ninit_done                    => ninit_done,
            h2f_user0_clock_clk                      => h2f_user0_clock,

            lwhps2fpga_axi_clock_clk                 => lwh2f_clock,
            lwhps2fpga_axi_reset_reset               => lwh2f_reset,
            f2sdram_axi_clock_clk                    => f2sdram_clock,
            f2sdram_axi_reset_reset                  => f2sdram_reset,
            fpga2hps_clock_clk                       => f2h_clock,
            fpga2hps_reset_reset                     => f2h_reset,

            -- the AXI buses, field by field
            f2sdram_araddr                           => f2sdram_m2s.araddr,
            f2sdram_arburst                          => f2sdram_m2s.arburst,
            f2sdram_arcache                          => f2sdram_m2s.arcache,
            f2sdram_arid                             => f2sdram_m2s.arid,
            f2sdram_arlen                            => f2sdram_m2s.arlen,
            f2sdram_arlock                           => f2sdram_m2s.arlock,
            f2sdram_arprot                           => f2sdram_m2s.arprot,
            f2sdram_arqos                            => f2sdram_m2s.arqos,
            f2sdram_arready                          => f2sdram_s2m.arready,
            f2sdram_arsize                           => f2sdram_m2s.arsize,
            f2sdram_arvalid                          => f2sdram_m2s.arvalid,
            f2sdram_awaddr                           => f2sdram_m2s.awaddr,
            f2sdram_awburst                          => f2sdram_m2s.awburst,
            f2sdram_awcache                          => f2sdram_m2s.awcache,
            f2sdram_awid                             => f2sdram_m2s.awid,
            f2sdram_awlen                            => f2sdram_m2s.awlen,
            f2sdram_awlock                           => f2sdram_m2s.awlock,
            f2sdram_awprot                           => f2sdram_m2s.awprot,
            f2sdram_awqos                            => f2sdram_m2s.awqos,
            f2sdram_awready                          => f2sdram_s2m.awready,
            f2sdram_awsize                           => f2sdram_m2s.awsize,
            f2sdram_awvalid                          => f2sdram_m2s.awvalid,
            f2sdram_bid                              => f2sdram_s2m.bid,
            f2sdram_bready                           => f2sdram_m2s.bready,
            f2sdram_bresp                            => f2sdram_s2m.bresp,
            f2sdram_bvalid                           => f2sdram_s2m.bvalid,
            f2sdram_rdata                            => f2sdram_s2m.rdata,
            f2sdram_rid                              => f2sdram_s2m.rid,
            f2sdram_rlast                            => f2sdram_s2m.rlast,
            f2sdram_rready                           => f2sdram_m2s.rready,
            f2sdram_rresp                            => f2sdram_s2m.rresp,
            f2sdram_rvalid                           => f2sdram_s2m.rvalid,
            f2sdram_wdata                            => f2sdram_m2s.wdata,
            f2sdram_wlast                            => f2sdram_m2s.wlast,
            f2sdram_wready                           => f2sdram_s2m.wready,
            f2sdram_wstrb                            => f2sdram_m2s.wstrb,
            f2sdram_wvalid                           => f2sdram_m2s.wvalid,
            f2sdram_aruser                           => f2sdram_m2s.aruser,
            f2sdram_awuser                           => f2sdram_m2s.awuser,
            f2sdram_wuser                            => f2sdram_m2s.wuser,
            f2sdram_buser                            => f2sdram_s2m.buser,
            f2sdram_arregion                         => f2sdram_m2s.arregion,
            f2sdram_ruser                            => f2sdram_s2m.ruser,
            f2sdram_awregion                         => f2sdram_m2s.awregion,
            fpga2hps_awid                            => f2h_m2s.awid,
            fpga2hps_awaddr                          => f2h_m2s.awaddr,
            fpga2hps_awdomain                        => f2h_m2s.awdomain,
            fpga2hps_awsnoop                         => f2h_m2s.awsnoop,
            fpga2hps_awlen                           => f2h_m2s.awlen,
            fpga2hps_awsize                          => f2h_m2s.awsize,
            fpga2hps_arsize                          => f2h_m2s.arsize,
            fpga2hps_awburst                         => f2h_m2s.awburst,
            fpga2hps_awlock                          => f2h_m2s.awlock,
            fpga2hps_awcache                         => f2h_m2s.awcache,
            fpga2hps_awprot                          => f2h_m2s.awprot,
            fpga2hps_awqos                           => f2h_m2s.awqos,
            fpga2hps_awvalid                         => f2h_m2s.awvalid,
            fpga2hps_awready                         => f2h_s2m.awready,
            fpga2hps_wdata                           => f2h_m2s.wdata,
            fpga2hps_wstrb                           => f2h_m2s.wstrb,
            fpga2hps_wlast                           => f2h_m2s.wlast,
            fpga2hps_wvalid                          => f2h_m2s.wvalid,
            fpga2hps_wready                          => f2h_s2m.wready,
            fpga2hps_awstashnid                      => f2h_m2s.awstashnid,
            fpga2hps_awstashniden                    => f2h_m2s.awstashniden,
            fpga2hps_awstashlpid                     => f2h_m2s.awstashlpid,
            fpga2hps_awstashlpiden                   => f2h_m2s.awstashlpiden,
            fpga2hps_awatop                          => f2h_m2s.awatop,
            fpga2hps_bid                             => f2h_s2m.bid,
            fpga2hps_bresp                           => f2h_s2m.bresp,
            fpga2hps_bvalid                          => f2h_s2m.bvalid,
            fpga2hps_bready                          => f2h_m2s.bready,
            fpga2hps_arid                            => f2h_m2s.arid,
            fpga2hps_araddr                          => f2h_m2s.araddr,
            fpga2hps_ardomain                        => f2h_m2s.ardomain,
            fpga2hps_arsnoop                         => f2h_m2s.arsnoop,
            fpga2hps_arlen                           => f2h_m2s.arlen,
            fpga2hps_arburst                         => f2h_m2s.arburst,
            fpga2hps_arlock                          => f2h_m2s.arlock,
            fpga2hps_arcache                         => f2h_m2s.arcache,
            fpga2hps_arprot                          => f2h_m2s.arprot,
            fpga2hps_arqos                           => f2h_m2s.arqos,
            fpga2hps_arvalid                         => f2h_m2s.arvalid,
            fpga2hps_arready                         => f2h_s2m.arready,
            fpga2hps_rid                             => f2h_s2m.rid,
            fpga2hps_rdata                           => f2h_s2m.rdata,
            fpga2hps_rresp                           => f2h_s2m.rresp,
            fpga2hps_rlast                           => f2h_s2m.rlast,
            fpga2hps_rvalid                          => f2h_s2m.rvalid,
            fpga2hps_rready                          => f2h_m2s.rready,
            fpga2hps_aruser                          => f2h_m2s.aruser,
            fpga2hps_awuser                          => f2h_m2s.awuser,
            fpga2hps_arregion                        => f2h_m2s.arregion,
            fpga2hps_awregion                        => f2h_m2s.awregion,
            fpga2hps_wuser                           => f2h_m2s.wuser,
            fpga2hps_buser                           => f2h_s2m.buser,
            fpga2hps_ruser                           => f2h_s2m.ruser,
            lwhps2fpga_awid                          => lwh2f_m2s.awid,
            lwhps2fpga_awaddr                        => lwh2f_m2s.awaddr,
            lwhps2fpga_awlen                         => lwh2f_m2s.awlen,
            lwhps2fpga_awsize                        => lwh2f_m2s.awsize,
            lwhps2fpga_awburst                       => lwh2f_m2s.awburst,
            lwhps2fpga_awlock                        => lwh2f_m2s.awlock,
            lwhps2fpga_awcache                       => lwh2f_m2s.awcache,
            lwhps2fpga_awprot                        => lwh2f_m2s.awprot,
            lwhps2fpga_awvalid                       => lwh2f_m2s.awvalid,
            lwhps2fpga_awready                       => lwh2f_s2m.awready,
            lwhps2fpga_wdata                         => lwh2f_m2s.wdata,
            lwhps2fpga_wstrb                         => lwh2f_m2s.wstrb,
            lwhps2fpga_wlast                         => lwh2f_m2s.wlast,
            lwhps2fpga_wvalid                        => lwh2f_m2s.wvalid,
            lwhps2fpga_wready                        => lwh2f_s2m.wready,
            lwhps2fpga_bid                           => lwh2f_s2m.bid,
            lwhps2fpga_bresp                         => lwh2f_s2m.bresp,
            lwhps2fpga_bvalid                        => lwh2f_s2m.bvalid,
            lwhps2fpga_bready                        => lwh2f_m2s.bready,
            lwhps2fpga_arid                          => lwh2f_m2s.arid,
            lwhps2fpga_araddr                        => lwh2f_m2s.araddr,
            lwhps2fpga_arlen                         => lwh2f_m2s.arlen,
            lwhps2fpga_arsize                        => lwh2f_m2s.arsize,
            lwhps2fpga_arburst                       => lwh2f_m2s.arburst,
            lwhps2fpga_arlock                        => lwh2f_m2s.arlock,
            lwhps2fpga_arcache                       => lwh2f_m2s.arcache,
            lwhps2fpga_arprot                        => lwh2f_m2s.arprot,
            lwhps2fpga_arvalid                       => lwh2f_m2s.arvalid,
            lwhps2fpga_arready                       => lwh2f_s2m.arready,
            lwhps2fpga_rid                           => lwh2f_s2m.rid,
            lwhps2fpga_rdata                         => lwh2f_s2m.rdata,
            lwhps2fpga_rresp                         => lwh2f_s2m.rresp,
            lwhps2fpga_rlast                         => lwh2f_s2m.rlast,
            lwhps2fpga_rvalid                        => lwh2f_s2m.rvalid,
            lwhps2fpga_rready                        => lwh2f_m2s.rready
        );

end architecture rtl;
