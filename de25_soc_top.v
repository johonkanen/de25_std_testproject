// ============================================================================
// de25_soc_top - DE25-Standard (Agilex 5) SoC bring-up.
//
//   * hps_min : Agilex 5 HPS + HPS-EMIF DDR4, EMAC0 (RGMII+MDIO), SD/MMC,
//               UART1 console, USB0, I2C1, SPIM0.  Every FPGA<->HPS bridge
//               is DISABLED - the HPS is a standalone Linux host, so this
//               build needs its own device tree / bootloader handoff
//               (the stock Terasic GHRD image assumes the bridges).
//   * de25_uart_top : the fabric UART + fpga_interconnect register block,
//               unchanged, on GPIO_D[0]/[1] with an external USB-serial
//               adapter.  Runs independently of the HPS.
//
// Pin / IO-standard assignments for the HPS and DDR4 pins come from the
// DE25 GHRD (see hps/hps_ddr4_pins.qsf, pulled into build_de25_soc.tcl).
// ============================================================================
module de25_soc_top (
    // ---- fabric side ----
    input              CLOCK0_50,      // 50 MHz  (PIN_CH128)
    input              CPU_RESET_n,    // active low (PIN_BM78)
    input      [ 9:0]  SW,
    input      [ 3:0]  KEY,
    output     [ 9:0]  LEDR,
    input              uart_rxd,       // GPIO_D[0]  (PIN_BK31)
    output             uart_txd,       // GPIO_D[1]  (PIN_BE43)

    // ---- HPS ----
    input              HPS_CLK_25,
    output             HPS_ENET_MDC,
    inout              HPS_ENET_MDIO,
    input              HPS_ENET_RX_CLK,
    input              HPS_ENET_RX_CTL,
    input      [ 3:0]  HPS_ENET_RX_DATA,
    output             HPS_ENET_TX_CLK,
    output             HPS_ENET_TX_CTL,
    output     [ 3:0]  HPS_ENET_TX_DATA,
    inout      [ 1:0]  HPS_GPIO,
    inout              HPS_GSENSOR_INT,
    inout              HPS_I2C_SCL,
    inout              HPS_I2C_SDA,
    inout              HPS_KEY,
    inout              HPS_LCM_BK,
    inout              HPS_LCM_D_C,
    inout              HPS_LCM_RST_n,
    output             HPS_LCM_SPIM_CLK,
    output             HPS_LCM_SPIM_MOSI,
    output             HPS_LCM_SPIM_SS,
    inout              HPS_LED,
    output             HPS_SD_CLK,
    inout              HPS_SD_CMD,
    inout      [ 3:0]  HPS_SD_DATA,
    input              HPS_UART_RX,
    output             HPS_UART_TX,
    input              HPS_USB_CLK,
    inout      [ 7:0]  HPS_USB_DATA,
    input              HPS_USB_DIR,
    input              HPS_USB_NXT,
    output             HPS_USB_STP,

    // ---- HPS DDR4 (EMIF) ----
    input              DDR4_REFCLK_p,
    output     [16:0]  DDR4_A,
    output     [ 1:0]  DDR4_BA,
    output     [ 0:0]  DDR4_BG,
    output             DDR4_CK,
    output             DDR4_CK_n,
    output             DDR4_CKE,
    inout      [ 3:0]  DDR4_DQS,
    inout      [ 3:0]  DDR4_DQS_n,
    inout      [31:0]  DDR4_DQ,
    inout      [ 3:0]  DDR4_DBI_n,
    output             DDR4_CS_n,
    output             DDR4_RESET_n,
    output             DDR4_ODT,
    output             DDR4_PAR,
    input              DDR4_ALERT_n,
    output             DDR4_ACT_n,
    input              DDR4_RZQ
);

    // ------------------------------------------------------------------
    // fabric UART + register block (see de25_uart_top.vhd) - stands alone
    // ------------------------------------------------------------------
    de25_uart_top u_fabric (
        .CLOCK0_50   (CLOCK0_50),
        .CPU_RESET_n (CPU_RESET_n),
        .SW          (SW),
        .KEY         (KEY),
        .LEDR        (LEDR),
        .uart_rxd    (uart_rxd),
        .uart_txd    (uart_txd)
    );

    // ------------------------------------------------------------------
    // HPS + HPS-EMIF DDR4 (see hps/hps_min.v, GENERATED)
    // ------------------------------------------------------------------
    hps_min u_hps_min (
        .h2f_reset_reset () ,
        .emac0_app_rst_reset_n () ,
        .hps_io_hps_osc_clk (HPS_CLK_25) ,
        .hps_io_sdmmc_data0 (HPS_SD_DATA[0]) ,
        .hps_io_sdmmc_data1 (HPS_SD_DATA[1]) ,
        .hps_io_sdmmc_cclk (HPS_SD_CLK) ,
        .hps_io_sdmmc_data2 (HPS_SD_DATA[2]) ,
        .hps_io_sdmmc_data3 (HPS_SD_DATA[3]) ,
        .hps_io_sdmmc_cmd (HPS_SD_CMD) ,
        .hps_io_usb0_clk (HPS_USB_CLK) ,
        .hps_io_usb0_stp (HPS_USB_STP) ,
        .hps_io_usb0_dir (HPS_USB_DIR) ,
        .hps_io_usb0_data0 (HPS_USB_DATA[0]) ,
        .hps_io_usb0_data1 (HPS_USB_DATA[1]) ,
        .hps_io_usb0_nxt (HPS_USB_NXT) ,
        .hps_io_usb0_data2 (HPS_USB_DATA[2]) ,
        .hps_io_usb0_data3 (HPS_USB_DATA[3]) ,
        .hps_io_usb0_data4 (HPS_USB_DATA[4]) ,
        .hps_io_usb0_data5 (HPS_USB_DATA[5]) ,
        .hps_io_usb0_data6 (HPS_USB_DATA[6]) ,
        .hps_io_usb0_data7 (HPS_USB_DATA[7]) ,
        .hps_io_emac0_tx_clk (HPS_ENET_TX_CLK) ,
        .hps_io_emac0_tx_ctl (HPS_ENET_TX_CTL) ,
        .hps_io_emac0_rx_clk (HPS_ENET_RX_CLK) ,
        .hps_io_emac0_rx_ctl (HPS_ENET_RX_CTL) ,
        .hps_io_emac0_txd0 (HPS_ENET_TX_DATA[0]) ,
        .hps_io_emac0_txd1 (HPS_ENET_TX_DATA[1]) ,
        .hps_io_emac0_rxd0 (HPS_ENET_RX_DATA[0]) ,
        .hps_io_emac0_rxd1 (HPS_ENET_RX_DATA[1]) ,
        .hps_io_emac0_txd2 (HPS_ENET_TX_DATA[2]) ,
        .hps_io_emac0_txd3 (HPS_ENET_TX_DATA[3]) ,
        .hps_io_emac0_rxd2 (HPS_ENET_RX_DATA[2]) ,
        .hps_io_emac0_rxd3 (HPS_ENET_RX_DATA[3]) ,
        .hps_io_mdio0_mdio (HPS_ENET_MDIO) ,
        .hps_io_mdio0_mdc (HPS_ENET_MDC) ,
        .hps_io_spim0_clk (HPS_LCM_SPIM_CLK) ,
        .hps_io_spim0_mosi (HPS_LCM_SPIM_MOSI) ,
        .hps_io_spim0_ss0_n (HPS_LCM_SPIM_SS) ,
        .hps_io_uart1_tx (HPS_UART_TX) ,
        .hps_io_uart1_rx (HPS_UART_RX) ,
        .hps_io_i2c1_sda (HPS_I2C_SDA) ,
        .hps_io_i2c1_scl (HPS_I2C_SCL) ,
        .hps_io_gpio28 (HPS_GSENSOR_INT) ,
        .hps_io_gpio32 (HPS_GPIO[0]) ,
        .hps_io_gpio33 (HPS_GPIO[1]) ,
        .hps_io_gpio34 (HPS_LCM_RST_n) ,
        .hps_io_gpio35 (HPS_LCM_D_C) ,
        .hps_io_gpio40 (HPS_KEY) ,
        .hps_io_gpio41 (HPS_LED) ,
        .hps_io_gpio42 (HPS_LCM_BK) ,
        .mem_0_cke (DDR4_CKE) ,
        .mem_0_odt (DDR4_ODT) ,
        .mem_0_cs_n (DDR4_CS_n) ,
        .mem_0_a (DDR4_A) ,
        .mem_0_ba (DDR4_BA) ,
        .mem_0_bg (DDR4_BG) ,
        .mem_0_act_n (DDR4_ACT_n) ,
        .mem_0_par (DDR4_PAR) ,
        .mem_0_dq (DDR4_DQ) ,
        .mem_0_dqs_t (DDR4_DQS) ,
        .mem_0_dqs_c (DDR4_DQS_n) ,
        .mem_0_alert_n (DDR4_ALERT_n) ,
        .mem_0_dbi_n (DDR4_DBI_n) ,
        .mem_0_ck_t (DDR4_CK) ,
        .mem_0_ck_c (DDR4_CK_n) ,
        .mem_0_reset_n (DDR4_RESET_n) ,
        .oct_rzqin_0 (DDR4_RZQ) ,
        .ref_clk (DDR4_REFCLK_p)
    );

endmodule
