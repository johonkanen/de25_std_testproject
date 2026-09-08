/*------------------------------------------------------------------------
 * clkmgr_bringup.c - Agilex 5 clock manager PLL bring-up, ported from
 * altera-fpga/arm-trusted-firmware (tag QPDS25.1.1_REL_GSRD_PR):
 *   plat/intel/soc/agilex5/soc/agilex5_clock_manager.c   (config_clkmgr_handoff,
 *       get_ref_clk, get_clk_freq, get_l3_main_free_clk, get_l4_sp_clk,
 *       get_uart_clk, and their static helpers)
 *   plat/intel/soc/agilex5/include/agilex5_clock_manager.h   (register map)
 *   plat/intel/soc/common/include/socfpga_handoff.h   (handoff struct)
 *   plat/intel/soc/agilex5/include/agilex5_system_manager.h  (scratch regs)
 *
 * Why this exists: the clkmgr is in "boot mode" out of reset - both PLLs
 * fully bypassed (confirmed against baremetal-drivers' own
 * test/simics/clkmgr/clkmgr_test.c expected-register dump: bypass=0xFF on
 * both PLL groups). uart_init() (src/uart/uart_internal.c) hardcodes its
 * baud divisor assuming a 100 MHz L4_SP clock, which is only true *after*
 * something brings the PLLs up - normally SPL/ATF, here nothing does, so
 * UART1 was transmitting real, correctly pin-muxed data at the wrong rate.
 *
 * The SDM writes a handoff blob - including a full, Quartus-precomputed
 * PLL configuration for this exact agilex_hps.ip - into a fixed OCRAM
 * address (PLAT_HANDOFF_OFFSET) as part of FPGA configuration. This is
 * the *same* mechanism fsbl_configuration() (helpers/fsbl_boot_help.c)
 * already reads for pin-mux; baremetal-drivers' own fsbl_handoff_t struct
 * is simply truncated before the clock section, so it never touches it.
 * This file does its own independent read of the same blob using the
 * *complete* struct layout, and applies the clock portion exactly as ATF
 * does - no derived or guessed register values anywhere in this file.
 *
 * Ported, not copied verbatim: ATF's mmio_*() (lib/mmio.h), logging
 * (ERROR/INFO/VERBOSE), and assert() are replaced with the equivalents
 * already used elsewhere in this project (plain volatile pointer access,
 * no logging, no assert). Register addresses, bit masks, and the
 * config_clkmgr_handoff() sequencing are unchanged from the source.
 *----------------------------------------------------------------------*/
#include <stdint.h>
#include <stddef.h>

#include "clkmgr_bringup.h"
#include "fsbl_boot_help.h"   /* PLAT_HANDOFF_OFFSET, b32_swap() */

/* ---- register access (replaces ATF's lib/mmio.h) ---- */
static inline uint32_t reg_read(uintptr_t addr) { return *(volatile uint32_t *)addr; }
static inline void reg_write(uintptr_t addr, uint32_t v) { *(volatile uint32_t *)addr = v; }
static inline void reg_set(uintptr_t addr, uint32_t bits) { reg_write(addr, reg_read(addr) | bits); }
static inline void reg_clr(uintptr_t addr, uint32_t bits) { reg_write(addr, reg_read(addr) & ~bits); }

#define BIT(n) (1U << (n))
#define GENMASK(h, l) ((0xFFFFFFFFU << (l)) & (0xFFFFFFFFU >> (31U - (h))))

/* ---- register map (agilex5_clock_manager.h, verbatim addresses) ---- */
#define CLKMGR_BASE          0x10D10000U
#define CLKMGR(_reg)         (CLKMGR_BASE + (CLKMGR_##_reg))
#define CLKMGR_CTRL          0x00U
#define CLKMGR_STAT          0x04U
#define CLKMGR_INTRCLR       0x14U

#define CLKMGR_MAINPLL_BASE  0x10D10024U
#define CLKMGR_MAINPLL(_reg) (CLKMGR_MAINPLL_BASE + (CLKMGR_MAINPLL_##_reg))
#define CLKMGR_MAINPLL_NOCCLK    0x1CU
#define CLKMGR_MAINPLL_NOCDIV    0x20U
#define CLKMGR_MAINPLL_PLLGLOB   0x24U
#define CLKMGR_MAINPLL_FDBCK     0x28U
#define CLKMGR_MAINPLL_MEM       0x2CU
#define CLKMGR_MAINPLL_MEMSTAT   0x30U
#define CLKMGR_MAINPLL_VCOCALIB  0x34U
#define CLKMGR_MAINPLL_PLLC0     0x38U
#define CLKMGR_MAINPLL_PLLC1     0x3CU
#define CLKMGR_MAINPLL_PLLC2     0x40U
#define CLKMGR_MAINPLL_PLLC3     0x44U
#define CLKMGR_MAINPLL_PLLM      0x48U
#define CLKMGR_MAINPLL_LOSTLOCK  0x54U
#define CLKMGR_MAINPLL_BYPASS    0x0CU

#define CLKMGR_PERPLL_BASE   0x10D1007CU
#define CLKMGR_PERPLL(_reg)  (CLKMGR_PERPLL_BASE + (CLKMGR_PERPLL_##_reg))
#define CLKMGR_PERPLL_EMACCTL    0x18U
#define CLKMGR_PERPLL_GPIODIV    0x1CU
#define CLKMGR_PERPLL_PLLGLOB    0x20U
#define CLKMGR_PERPLL_FDBCK      0x24U
#define CLKMGR_PERPLL_MEM        0x28U
#define CLKMGR_PERPLL_MEMSTAT    0x2CU
#define CLKMGR_PERPLL_VCOCALIB   0x30U
#define CLKMGR_PERPLL_PLLC0      0x34U
#define CLKMGR_PERPLL_PLLC1      0x38U
#define CLKMGR_PERPLL_PLLC2      0x3CU
#define CLKMGR_PERPLL_PLLC3      0x40U
#define CLKMGR_PERPLL_PLLM       0x44U
#define CLKMGR_PERPLL_LOSTLOCK   0x50U
#define CLKMGR_PERPLL_BYPASS     0x0CU

#define CLKMGR_ALTERA_BASE   0x10D100D0U
#define CLKMGR_ALTERA(_reg)  (CLKMGR_ALTERA_BASE + (CLKMGR_ALTERA_##_reg))
#define CLKMGR_ALTERA_EMACACTR    0x04U
#define CLKMGR_ALTERA_EMACBCTR    0x08U
#define CLKMGR_ALTERA_EMACPTPCTR  0x0CU
#define CLKMGR_ALTERA_GPIODBCTR   0x10U
#define CLKMGR_ALTERA_S2FUSER0CTR 0x18U
#define CLKMGR_ALTERA_S2FUSER1CTR 0x1CU
#define CLKMGR_ALTERA_PSIREFCTR   0x20U
#define CLKMGR_ALTERA_EXTCNTRST   0x24U
#define CLKMGR_ALTERA_USB31CTR    0x28U
#define CLKMGR_ALTERA_DSUCTR      0x2CU
#define CLKMGR_ALTERA_CORE01CTR   0x30U
#define CLKMGR_ALTERA_CORE23CTR   0x34U
#define CLKMGR_ALTERA_CORE2CTR    0x38U
#define CLKMGR_ALTERA_CORE3CTR    0x3CU

#define SOCFPGA_SYSMGR_REG_BASE           0x10D12000U
#define SOCFPGA_SYSMGR(_reg)               (SOCFPGA_SYSMGR_REG_BASE + (SOCFPGA_SYSMGR_##_reg))
#define SOCFPGA_SYSMGR_BOOT_SCRATCH_COLD_1 0x204U
#define SOCFPGA_SYSMGR_BOOT_SCRATCH_COLD_2 0x208U

#define CLKMGR_STAT_MAINPLL_LOCKED  BIT(8)
#define CLKMGR_STAT_PERPLL_LOCKED   BIT(16)
#define CLKMGR_STAT_ALLPLL_LOCKED_MASK (CLKMGR_STAT_MAINPLL_LOCKED | CLKMGR_STAT_PERPLL_LOCKED)
#define CLKMGR_STAT_BUSY(x) (((x) & 0x1U) >> 0)
#define CLKMGR_INTRCLR_MAINLOCKLOST BIT(2)
#define CLKMGR_INTRCLR_PERLOCKLOST  BIT(3)

#define CLKMGR_CTRL_BOOTMODE  BIT(0)

#define CLKMGR_MAINPLL_PLLGLOB_PD_N  BIT(0)
#define CLKMGR_MAINPLL_PLLGLOB_RST_N BIT(1)
#define CLKMGR_PERPLL_PLLGLOB_PD_N   BIT(0)
#define CLKMGR_PERPLL_PLLGLOB_RST_N  BIT(1)
#define CLKMGR_MAINPLL_PLLCX_EN  BIT(27)
#define CLKMGR_PERPLL_PLLCX_EN   BIT(27)

#define CLKMGR_XPLL_LOSTLOCK_BYPASSCLEAR      BIT(0)
#define CLKMGR_XPLLGLOB_CLR_LOSTLOCK_BYPASS   BIT(29)

#define CLKMGR_MAINPLL_BYPASS_ALL 0xF6U
#define CLKMGR_PERPLL_BYPASS_ALL  0xEFU
#define CLKMGR_ALTERA_EXTCNTRST_ALLCNTRST 0x3FFFU  /* bits 0-9,10-13 per header; superset write is safe */

#define CLKMGR_MAINPLL_TYPE 0
#define CLKMGR_PERPLL_TYPE  1
#define CLKMGR_MAX_RETRY_COUNT 1000U

#define CLKMGR_MEM_REQ        BIT(24)
#define CLKMGR_MEM_WR         BIT(25)
#define CLKMGR_MEM_ERR        BIT(26)
#define CLKMGR_MEM_WDAT_OFFSET 16U
#define CLKMGR_MEM_ADDR_MASK  GENMASK(15, 0)
#define CLKMGR_MEM_ADDR_START 0x00004000U

#define CLKMGR_PLLCFG_SRC_SYNC_MODE       0x27U
#define CLKMGR_PLLCFG_OVRSHOOT_FREQ_LOCK  0xB3U
#define CLKMGR_PLLCFG_LOCK_SETTLE_TIME    0xE6U
#define CLKMGR_PLLCFG_DUTYCYCLE_CLKSLICE0 0x03U
#define CLKMGR_PLLCFG_DUTYCYCLE_CLKSLICE1 0x07U

#define CLKMGR_PLLM_MDIV_MASK        GENMASK(9, 0)
#define CLKMGR_PLLGLOB_AREFCLKDIV_MASK GENMASK(11, 8)
#define CLKMGR_PLLGLOB_AREFCLKDIV_OFFSET 8U
#define CLKMGR_PLLGLOB_DREFCLKDIV_MASK  GENMASK(13, 12)
#define CLKMGR_PLLGLOB_DREFCLKDIV_OFFSET 12U
#define CLKMGR_PLLGLOB_REFCLKDIV_MASK   GENMASK(13, 8)
#define CLKMGR_PLLGLOB_REFCLKDIV_OFFSET 8U
#define CLKMGR_VCOCALIB_MSCNT_MASK   GENMASK(23, 16)
#define CLKMGR_VCOCALIB_MSCNT_OFFSET 16U
#define CLKMGR_VCOCALIB_HSCNT_MASK   GENMASK(9, 0)
#define CLKMGR_VCOCALIB_MSCNT_CONST  100U
#define CLKMGR_VCOCALIB_HSCNT_CONST  4U

#define CLKMGR_PLLGLOB_PSRC(x) (((x) & 0x00030000U) >> 16)
#define CLKMGR_PLLGLOB_PSRC_EOSC1  0x0U
#define CLKMGR_PLLGLOB_PSRC_INTOSC 0x1U
#define CLKMGR_PLLGLOB_PSRC_F2S    0x2U
#define CLKMGR_PLLM_MDIV(x) ((x) & 0x000003FFU)
#define CLKMGR_INTOSC_HZ 460000000U

#define CLKMGR_CLKSRC_MASK   GENMASK(18, 16)
#define CLKMGR_CLKSRC_OFFSET 16U
#define CLKMGR_CLKSRC_MAIN   0U
#define CLKMGR_CLKSRC_PER    1U
#define CLKMGR_CLKSRC_OSC1   2U
#define CLKMGR_CLKSRC_INTOSC 3U
#define CLKMGR_CLKSRC_FPGA   4U
#define GET_CLKMGR_CLKSRC(x) (((x) & CLKMGR_CLKSRC_MASK) >> CLKMGR_CLKSRC_OFFSET)
#define CLKMGR_PLLCX_DIV_MSK GENMASK(10, 0)

#define CLKMGR_MAINPLL_NOCDIV_L4SP_MASK   GENMASK(7, 6)
#define CLKMGR_MAINPLL_NOCDIV_L4SP_OFFSET 6U
#define GET_CLKMGR_MAINPLL_NOCDIV_L4SP(x) (((x) & CLKMGR_MAINPLL_NOCDIV_L4SP_MASK) >> CLKMGR_MAINPLL_NOCDIV_L4SP_OFFSET)

/* ---- handoff struct (socfpga_handoff.h, PLAT_SOCFPGA_AGILEX5 branch) ----
 * Field order/types/array-sizes must match exactly for correct byte
 * offsets - this is what makes the raw OCRAM read below line up. */
typedef struct {
    uint32_t header_magic;
    uint32_t header_device;
    uint32_t _pad_0x08_0x10[2];

    uint32_t pinmux_sel_magic;
    uint32_t pinmux_sel_length;
    uint32_t _pad_0x18_0x20[2];
    uint32_t pinmux_sel_array[96];

    uint32_t pinmux_io_magic;
    uint32_t pinmux_io_length;
    uint32_t _pad_0x1a8_0x1b0[2];
    uint32_t pinmux_io_array[96];

    uint32_t pinmux_fpga_magic;
    uint32_t pinmux_fpga_length;
    uint32_t _pad_0x338_0x340[2];
    uint32_t pinmux_fpga_array[44];

    uint32_t pinmux_delay_magic;
    uint32_t pinmux_delay_length;
    uint32_t _pad_0x3f8_0x400[2];
    uint32_t pinmux_iodelay_array[96];

    uint32_t clock_magic;
    uint32_t clock_length;
    uint32_t _pad_0x588_0x590[2];

    uint32_t main_pll_nocclk;
    uint32_t main_pll_nocdiv;
    uint32_t main_pll_pllglob;
    uint32_t main_pll_fdbck;
    uint32_t main_pll_pllc0;
    uint32_t main_pll_pllc1;
    uint32_t main_pll_pllc2;
    uint32_t main_pll_pllc3;
    uint32_t main_pll_pllm;

    uint32_t per_pll_emacctl;
    uint32_t per_pll_gpiodiv;
    uint32_t per_pll_pllglob;
    uint32_t per_pll_fdbck;
    uint32_t per_pll_pllc0;
    uint32_t per_pll_pllc1;
    uint32_t per_pll_pllc2;
    uint32_t per_pll_pllc3;
    uint32_t per_pll_pllm;

    uint32_t alt_emacactr;
    uint32_t alt_emacbctr;
    uint32_t alt_emacptpctr;
    uint32_t alt_gpiodbctr;
    uint32_t alt_s2fuser0ctr;
    uint32_t alt_s2fuser1ctr;
    uint32_t alt_psirefctr;
    uint32_t alt_usb31ctr;
    uint32_t alt_dsuctr;
    uint32_t alt_core01ctr;
    uint32_t alt_core23ctr;
    uint32_t alt_core2ctr;
    uint32_t alt_core3ctr;
    uint32_t hps_osc_clk_hz;
    uint32_t fpga_clk_hz;
    uint32_t _pad_0x604_0x610[3];
} agx5_handoff_t;

static agx5_handoff_t g_hoff;

static void read_and_swap_handoff(void) {
    const uint32_t *raw = (const uint32_t *)PLAT_HANDOFF_OFFSET;
    uint32_t *dst = (uint32_t *)&g_hoff;
    size_t n = sizeof(agx5_handoff_t) / sizeof(uint32_t);
    for (size_t i = 0; i < n; i++) {
        dst[i] = raw[i];
    }
    for (size_t i = 0; i < n; i++) {
        (void)b32_swap(&dst[i]);
    }
}

/* ---- ported from agilex5_clock_manager.c ---- */

typedef struct {
    uint32_t addr;
    uint32_t data;
    uint32_t mask;
} pll_cfg_t;

static const pll_cfg_t pll_cfg_set[] = {
    { CLKMGR_PLLCFG_SRC_SYNC_MODE,       BIT(7), BIT(7) },
    { CLKMGR_PLLCFG_OVRSHOOT_FREQ_LOCK,  BIT(0), BIT(0) },
    { CLKMGR_PLLCFG_LOCK_SETTLE_TIME,    BIT(0), BIT(0) },
    { CLKMGR_PLLCFG_DUTYCYCLE_CLKSLICE0, 0x4AU, GENMASK(6, 0) },
    { CLKMGR_PLLCFG_DUTYCYCLE_CLKSLICE1, 0x4AU, GENMASK(6, 0) },
};

static int32_t wait_fsm(void) {
    uint32_t data;
    uint32_t count = 0;
    do {
        if (count >= CLKMGR_MAX_RETRY_COUNT) {
            return -1;
        }
        data = reg_read(CLKMGR(STAT));
        count++;
    } while (CLKMGR_STAT_BUSY(data) != 0U);
    return 0;
}

static int32_t wait_pll_lock(uint32_t mask) {
    uint32_t data;
    uint32_t count = 0;
    uint32_t retry = 0;
    do {
        if (count >= CLKMGR_MAX_RETRY_COUNT) {
            return -1;
        }
        data = reg_read(CLKMGR(STAT)) & mask;
        if (data == mask) {
            retry++;
        } else {
            retry = 0;
        }
        if (retry >= 5U) {
            break;
        }
        count++;
    } while (1);
    return 0;
}

static uint32_t calc_pll_vcocalibration(uint32_t pllm, uint32_t pllglob) {
    uint32_t mdiv, refclkdiv, drefclkdiv, mscnt, hscnt, vcocalib;

    mdiv = pllm & CLKMGR_PLLM_MDIV_MASK;
    drefclkdiv = (pllglob & CLKMGR_PLLGLOB_DREFCLKDIV_MASK) >> CLKMGR_PLLGLOB_DREFCLKDIV_OFFSET;
    refclkdiv = (pllglob & CLKMGR_PLLGLOB_REFCLKDIV_MASK) >> CLKMGR_PLLGLOB_REFCLKDIV_OFFSET;
    mscnt = CLKMGR_VCOCALIB_MSCNT_CONST / (mdiv * BIT(drefclkdiv));
    if (mscnt == 0U) {
        mscnt = 1U;
    }
    hscnt = (mdiv * mscnt * BIT(drefclkdiv) / refclkdiv) - CLKMGR_VCOCALIB_HSCNT_CONST;
    vcocalib = (hscnt & CLKMGR_VCOCALIB_HSCNT_MASK) |
               ((mscnt << CLKMGR_VCOCALIB_MSCNT_OFFSET) & CLKMGR_VCOCALIB_MSCNT_MASK);
    return vcocalib;
}

static int32_t pll_source_sync_wait(uint32_t pll_type, uint32_t retry_count) {
    uint32_t count = 0;
    uint32_t req_status = (pll_type == CLKMGR_MAINPLL_TYPE) ? reg_read(CLKMGR_MAINPLL(MEM))
                                                             : reg_read(CLKMGR_PERPLL(MEM));
    while ((count < retry_count) && ((req_status & CLKMGR_MEM_REQ) != 0U)) {
        req_status = (pll_type == CLKMGR_MAINPLL_TYPE) ? reg_read(CLKMGR_MAINPLL(MEM))
                                                        : reg_read(CLKMGR_PERPLL(MEM));
        count++;
    }
    if (count >= retry_count) {
        return -1;
    }
    return 0;
}

static int32_t pll_source_sync_config(uint32_t pll_type, uint32_t addr_offset,
                                       uint32_t wdat, uint32_t retry_count) {
    uint32_t addr = (addr_offset | CLKMGR_MEM_ADDR_START) & CLKMGR_MEM_ADDR_MASK;
    uint32_t val = CLKMGR_MEM_REQ | CLKMGR_MEM_WR | (wdat << CLKMGR_MEM_WDAT_OFFSET) | addr;
    if (pll_type == CLKMGR_MAINPLL_TYPE) {
        reg_write(CLKMGR_MAINPLL(MEM), val);
    } else {
        reg_write(CLKMGR_PERPLL(MEM), val);
    }
    return pll_source_sync_wait(pll_type, retry_count);
}

static int32_t pll_source_sync_read(uint32_t pll_type, uint32_t addr_offset,
                                     uint32_t *rdata, uint32_t retry_count) {
    uint32_t addr = (addr_offset | CLKMGR_MEM_ADDR_START) & CLKMGR_MEM_ADDR_MASK;
    uint32_t val = (CLKMGR_MEM_REQ & ~CLKMGR_MEM_WR) | addr;
    if (pll_type == CLKMGR_MAINPLL_TYPE) {
        reg_write(CLKMGR_MAINPLL(MEM), val);
    } else {
        reg_write(CLKMGR_PERPLL(MEM), val);
    }
    *rdata = 0;
    if (pll_source_sync_wait(pll_type, retry_count) != 0) {
        return -1;
    }
    *rdata = (pll_type == CLKMGR_MAINPLL_TYPE) ? reg_read(CLKMGR_MAINPLL(MEMSTAT))
                                                : reg_read(CLKMGR_PERPLL(MEMSTAT));
    return 0;
}

static void config_pll_pd_state(uint32_t pll_type) {
    uint32_t rdata;
    for (size_t i = 0; i < sizeof(pll_cfg_set) / sizeof(pll_cfg_set[0]); i++) {
        (void)pll_source_sync_read(pll_type, pll_cfg_set[i].addr, &rdata, CLKMGR_MAX_RETRY_COUNT);
        (void)pll_source_sync_config(pll_type, pll_cfg_set[i].addr,
                                      (rdata & ~pll_cfg_set[i].mask) | pll_cfg_set[i].data,
                                      CLKMGR_MAX_RETRY_COUNT);
    }
}

static int32_t config_clkmgr_handoff(const agx5_handoff_t *hoff) {
    int32_t ret;
    uint32_t mainpll_vcocalib, perpll_vcocalib;

    reg_set(CLKMGR(CTRL), CLKMGR_CTRL_BOOTMODE);

    reg_set(CLKMGR_MAINPLL(BYPASS), CLKMGR_MAINPLL_BYPASS_ALL);
    ret = wait_fsm();
    if (ret != 0) return ret;

    reg_set(CLKMGR_PERPLL(BYPASS), CLKMGR_PERPLL_BYPASS_ALL);
    ret = wait_fsm();
    if (ret != 0) return ret;

    reg_clr(CLKMGR_MAINPLL(PLLGLOB), CLKMGR_MAINPLL_PLLGLOB_PD_N | CLKMGR_MAINPLL_PLLGLOB_RST_N);
    reg_clr(CLKMGR_PERPLL(PLLGLOB), CLKMGR_PERPLL_PLLGLOB_PD_N | CLKMGR_PERPLL_PLLGLOB_RST_N);

    mainpll_vcocalib = calc_pll_vcocalibration(hoff->main_pll_pllm, hoff->main_pll_pllglob);
    reg_write(CLKMGR_MAINPLL(PLLGLOB), hoff->main_pll_pllglob & ~CLKMGR_MAINPLL_PLLGLOB_RST_N);
    reg_write(CLKMGR_MAINPLL(FDBCK), hoff->main_pll_fdbck);
    reg_write(CLKMGR_MAINPLL(VCOCALIB), mainpll_vcocalib);
    reg_write(CLKMGR_MAINPLL(PLLC0), hoff->main_pll_pllc0);
    reg_write(CLKMGR_MAINPLL(PLLC1), hoff->main_pll_pllc1);
    reg_write(CLKMGR_MAINPLL(PLLC2), hoff->main_pll_pllc2);
    reg_write(CLKMGR_MAINPLL(PLLC3), hoff->main_pll_pllc3);
    reg_write(CLKMGR_MAINPLL(PLLM), hoff->main_pll_pllm);
    reg_write(CLKMGR_MAINPLL(NOCCLK), hoff->main_pll_nocclk);
    reg_write(CLKMGR_MAINPLL(NOCDIV), hoff->main_pll_nocdiv);

    perpll_vcocalib = calc_pll_vcocalibration(hoff->per_pll_pllm, hoff->per_pll_pllglob);
    reg_write(CLKMGR_PERPLL(PLLGLOB), hoff->per_pll_pllglob & ~CLKMGR_PERPLL_PLLGLOB_RST_N);
    reg_write(CLKMGR_PERPLL(FDBCK), hoff->per_pll_fdbck);
    reg_write(CLKMGR_PERPLL(VCOCALIB), perpll_vcocalib);
    reg_write(CLKMGR_PERPLL(PLLC0), hoff->per_pll_pllc0);
    reg_write(CLKMGR_PERPLL(PLLC1), hoff->per_pll_pllc1);
    reg_write(CLKMGR_PERPLL(PLLC2), hoff->per_pll_pllc2);
    reg_write(CLKMGR_PERPLL(PLLC3), hoff->per_pll_pllc3);
    reg_write(CLKMGR_PERPLL(PLLM), hoff->per_pll_pllm);
    reg_write(CLKMGR_PERPLL(EMACCTL), hoff->per_pll_emacctl);
    reg_write(CLKMGR_PERPLL(GPIODIV), hoff->per_pll_gpiodiv);

    reg_write(CLKMGR_ALTERA(EMACACTR), hoff->alt_emacactr);
    reg_write(CLKMGR_ALTERA(EMACBCTR), hoff->alt_emacbctr);
    reg_write(CLKMGR_ALTERA(EMACPTPCTR), hoff->alt_emacptpctr);
    reg_write(CLKMGR_ALTERA(GPIODBCTR), hoff->alt_gpiodbctr);
    reg_write(CLKMGR_ALTERA(S2FUSER0CTR), hoff->alt_s2fuser0ctr);
    reg_write(CLKMGR_ALTERA(S2FUSER1CTR), hoff->alt_s2fuser1ctr);
    reg_write(CLKMGR_ALTERA(PSIREFCTR), hoff->alt_psirefctr);
    reg_write(CLKMGR_ALTERA(USB31CTR), hoff->alt_usb31ctr);
    reg_write(CLKMGR_ALTERA(DSUCTR), hoff->alt_dsuctr);
    reg_write(CLKMGR_ALTERA(CORE01CTR), hoff->alt_core01ctr);
    reg_write(CLKMGR_ALTERA(CORE23CTR), hoff->alt_core23ctr);
    reg_write(CLKMGR_ALTERA(CORE2CTR), hoff->alt_core2ctr);
    reg_write(CLKMGR_ALTERA(CORE3CTR), hoff->alt_core3ctr);

    reg_set(CLKMGR_MAINPLL(PLLGLOB), CLKMGR_MAINPLL_PLLGLOB_PD_N | CLKMGR_MAINPLL_PLLGLOB_RST_N);
    reg_set(CLKMGR_PERPLL(PLLGLOB), CLKMGR_PERPLL_PLLGLOB_PD_N | CLKMGR_PERPLL_PLLGLOB_RST_N);

    config_pll_pd_state(CLKMGR_MAINPLL_TYPE);
    config_pll_pd_state(CLKMGR_PERPLL_TYPE);

    reg_set(CLKMGR_MAINPLL(PLLC0), CLKMGR_MAINPLL_PLLCX_EN);
    reg_set(CLKMGR_MAINPLL(PLLC1), CLKMGR_MAINPLL_PLLCX_EN);
    reg_set(CLKMGR_MAINPLL(PLLC2), CLKMGR_MAINPLL_PLLCX_EN);
    reg_set(CLKMGR_MAINPLL(PLLC3), CLKMGR_MAINPLL_PLLCX_EN);
    reg_set(CLKMGR_PERPLL(PLLC0), CLKMGR_PERPLL_PLLCX_EN);
    reg_set(CLKMGR_PERPLL(PLLC1), CLKMGR_PERPLL_PLLCX_EN);
    reg_set(CLKMGR_PERPLL(PLLC2), CLKMGR_PERPLL_PLLCX_EN);
    reg_set(CLKMGR_PERPLL(PLLC3), CLKMGR_PERPLL_PLLCX_EN);

    ret = wait_pll_lock(CLKMGR_STAT_ALLPLL_LOCKED_MASK);
    if (ret != 0) return ret;

    reg_set(CLKMGR_MAINPLL(LOSTLOCK), CLKMGR_XPLL_LOSTLOCK_BYPASSCLEAR);
    reg_set(CLKMGR_PERPLL(LOSTLOCK), CLKMGR_XPLL_LOSTLOCK_BYPASSCLEAR);
    reg_set(CLKMGR_MAINPLL(PLLGLOB), CLKMGR_XPLLGLOB_CLR_LOSTLOCK_BYPASS);
    reg_set(CLKMGR_PERPLL(PLLGLOB), CLKMGR_XPLLGLOB_CLR_LOSTLOCK_BYPASS);

    reg_write(SOCFPGA_SYSMGR(BOOT_SCRATCH_COLD_1), hoff->hps_osc_clk_hz);
    reg_write(SOCFPGA_SYSMGR(BOOT_SCRATCH_COLD_2), hoff->fpga_clk_hz);

    reg_clr(CLKMGR_MAINPLL(BYPASS), CLKMGR_MAINPLL_BYPASS_ALL);
    ret = wait_fsm();
    if (ret != 0) return ret;

    reg_clr(CLKMGR_PERPLL(BYPASS), CLKMGR_PERPLL_BYPASS_ALL);
    ret = wait_fsm();
    if (ret != 0) return ret;

    reg_write(CLKMGR(INTRCLR), CLKMGR_INTRCLR_MAINLOCKLOST | CLKMGR_INTRCLR_PERLOCKLOST);
    reg_clr(CLKMGR_ALTERA(EXTCNTRST), CLKMGR_ALTERA_EXTCNTRST_ALLCNTRST);
    reg_clr(CLKMGR(CTRL), CLKMGR_CTRL_BOOTMODE);

    return 0;
}

/* ---- readback: compute the resulting UART (L4_SP) clock, Hz ---- */

static uint32_t get_ref_clk(uint32_t pllglob_reg, uint32_t pllm_reg) {
    uint32_t arefclkdiv, ref_clk, mdiv, pllglob_val, pllm_val;

    pllglob_val = reg_read(pllglob_reg);
    pllm_val = reg_read(pllm_reg);

    switch (CLKMGR_PLLGLOB_PSRC(pllglob_val)) {
        case CLKMGR_PLLGLOB_PSRC_EOSC1:
            ref_clk = reg_read(SOCFPGA_SYSMGR(BOOT_SCRATCH_COLD_1));
            break;
        case CLKMGR_PLLGLOB_PSRC_INTOSC:
            ref_clk = CLKMGR_INTOSC_HZ;
            break;
        case CLKMGR_PLLGLOB_PSRC_F2S:
            ref_clk = reg_read(SOCFPGA_SYSMGR(BOOT_SCRATCH_COLD_2));
            break;
        default:
            ref_clk = 0;
            break;
    }

    arefclkdiv = (pllglob_val & CLKMGR_PLLGLOB_AREFCLKDIV_MASK) >> CLKMGR_PLLGLOB_AREFCLKDIV_OFFSET;
    if (arefclkdiv == 0U) arefclkdiv = 1U;
    ref_clk /= arefclkdiv;

    mdiv = CLKMGR_PLLM_MDIV(pllm_val);
    ref_clk *= mdiv;

    return ref_clk;
}

static uint32_t get_clk_freq(uint32_t psrc_reg, uint32_t mainpllc_reg, uint32_t perpllc_reg) {
    uint32_t clock = 0;
    uint32_t clk_psrc = reg_read(psrc_reg);
    uint32_t div;

    switch (GET_CLKMGR_CLKSRC(clk_psrc)) {
        case CLKMGR_CLKSRC_MAIN:
            clock = get_ref_clk(CLKMGR_MAINPLL(PLLGLOB), CLKMGR_MAINPLL(PLLM));
            div = reg_read(mainpllc_reg) & CLKMGR_PLLCX_DIV_MSK;
            if (div != 0U) clock /= div;
            break;
        case CLKMGR_CLKSRC_PER:
            clock = get_ref_clk(CLKMGR_PERPLL(PLLGLOB), CLKMGR_PERPLL(PLLM));
            div = reg_read(perpllc_reg) & CLKMGR_PLLCX_DIV_MSK;
            if (div != 0U) clock /= div;
            break;
        case CLKMGR_CLKSRC_OSC1:
            clock = reg_read(SOCFPGA_SYSMGR(BOOT_SCRATCH_COLD_1));
            break;
        case CLKMGR_CLKSRC_INTOSC:
            clock = CLKMGR_INTOSC_HZ;
            break;
        case CLKMGR_CLKSRC_FPGA:
            clock = reg_read(SOCFPGA_SYSMGR(BOOT_SCRATCH_COLD_2));
            break;
        default:
            clock = 0;
            break;
    }
    return clock;
}

static uint32_t get_l3_main_free_clk(void) {
    return get_clk_freq(CLKMGR_MAINPLL(NOCCLK), CLKMGR_MAINPLL(PLLC3), CLKMGR_PERPLL(PLLC1));
}

static uint32_t get_l4_sp_clk(void) {
    uint32_t l3 = get_l3_main_free_clk();
    uint32_t nocdiv_l4sp = BIT(GET_CLKMGR_MAINPLL_NOCDIV_L4SP(reg_read(CLKMGR_MAINPLL(NOCDIV))));
    return l3 / nocdiv_l4sp;
}

int32_t clkmgr_bringup(uint32_t *out_uart_clk_hz) {
    read_and_swap_handoff();
    int32_t rc = config_clkmgr_handoff(&g_hoff);
    if (out_uart_clk_hz != NULL) {
        *out_uart_clk_hz = (rc == 0) ? get_l4_sp_clk() : 0U;
    }
    return rc;
}
