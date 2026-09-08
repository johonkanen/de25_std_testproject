#ifndef CLKMGR_BRINGUP_H
#define CLKMGR_BRINGUP_H

#include <stdint.h>

/* Bring up the Agilex 5 clock manager PLLs from the SDM-provided handoff
 * data (ported from altera-fpga/arm-trusted-firmware's
 * plat/intel/soc/agilex5/soc/agilex5_clock_manager.c config_clkmgr_handoff()
 * - see hps/baremetal_lwh2f_regs/README.md). Returns 0 on success (PLLs locked), <0 on
 * a wait_fsm()/wait_pll_lock() timeout. On success, *out_uart_clk_hz is set
 * to the resulting L4_SP clock (the reference UART1's baud divisor must be
 * computed against) via the same register-readback math as ATF's
 * clkmgr_get_rate(CLKMGR_UART_CLK_ID). */
int32_t clkmgr_bringup(uint32_t *out_uart_clk_hz);

#endif
