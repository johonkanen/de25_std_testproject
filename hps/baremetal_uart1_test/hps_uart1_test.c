/*------------------------------------------------------------------------
 * hps_uart1_test.c - minimal bare-metal test for the DE25-Standard HPS UART1
 * (the instance wired to the physical HPS_UART_TX/RX pins), proving live
 * communication with the HPS ARM cores without any bootloader or OS.
 *
 * Runs straight out of HPS OCRAM: the SDM loads this binary as part of
 * FPGA configuration (embedded via `quartus_pfg -o hps_path=...`) and
 * releases the HPS reset right into it. No ATF, no U-Boot, no Linux -
 * this is the very first and only thing that runs on the ARM cores.
 *
 * v2: calls fsbl_configuration() before touching UART1, applying the
 * SDM-provided pin-mux handoff. Result: real, correctly pin-muxed signal
 * on the wire, but garbled at every baud rate tried - the clkmgr is still
 * in "boot mode" (both PLLs bypassed), and uart_init() hardcodes its baud
 * divisor assuming a 100 MHz L4_SP clock that boot mode doesn't provide.
 *
 * v3: adds clkmgr_bringup() (clkmgr_bringup.c, ported from
 * altera-fpga/arm-trusted-firmware's agilex5_clock_manager.c - see that
 * file's header and hps/baremetal_uart1_test/README.md) to bring the PLLs up from the
 * same handoff blob, then reads back the *actual* resulting UART clock
 * and reprograms UART1's baud divisor against it directly - bypassing
 * uart_baud_rate_divisor_set()'s IOCTL, which has a byte-order bug
 * relative to uart_init()'s own (correct) use of the same registers.
 *
 * Protocol, all over /dev/uart1 @ 115200 8N1:
 *   - sends a banner on start: fsbl_configuration()/clkmgr_bringup() return
 *     codes, the pin-mux values actually applied for IOB15/IOB16, the
 *     measured UART clock, and the divisor programmed from it
 *   - echoes every byte it receives straight back
 *   - prints a periodic heartbeat line so a listener can tell the program
 *     is alive even when nothing is being sent to it
 *
 * Built against github.com/altera-fpga/baremetal-drivers (which provides
 * the C runtime startup, linker script, and uart/rstmgr/fsbl_boot_help
 * drivers) - see hps/baremetal_uart1_test/README.md for the toolchain and build
 * instructions.
 *----------------------------------------------------------------------*/
#include <stdint.h>

#include "clkmgr_bringup.h"
#include "fsbl_boot_help.h"
#include "hps_address_map.h"
#include "rstmgr.h"
#include "rstmgr_regs.h"
#include "uart.h"
#include "uart_regs.h"

/* Opened automatically for stdout during C-runtime startup (mylibc.cpp's
 * _fstat, called from _cpu_init_hook) - always UART0, which is not wired
 * to any pin on this board. We don't use it. */
extern int32_t stdout_uart_fd;

static void send_str(int32_t fd, const char *s) {
    size_t len = 0;
    while (s[len] != '\0') {
        len++;
    }
    (void)uart_write(fd, (uintptr_t)s, len);
}

static void send_hex_u32(int32_t fd, uint32_t v) {
    static const char digits[] = "0123456789ABCDEF";
    char buf[8];
    for (int i = 7; i >= 0; i--) {
        buf[i] = digits[v & 0xFU];
        v >>= 4;
    }
    (void)uart_write(fd, (uintptr_t)buf, sizeof(buf));
}

static void send_dec_u32(int32_t fd, uint32_t v) {
    char buf[10];
    int i = 10;
    if (v == 0U) {
        (void)uart_write(fd, (uintptr_t)"0", 1);
        return;
    }
    while (v > 0U && i > 0) {
        buf[--i] = (char)('0' + (v % 10U));
        v /= 10U;
    }
    (void)uart_write(fd, (uintptr_t)&buf[i], (size_t)(10 - i));
}

/* Directly reprogram UART1's baud divisor, mirroring uart_init()'s own
 * register usage (src/uart/uart_internal.c): RBR (offset 0x00) is DLL
 * (low byte) and IER (offset 0x04) is DLLM (high byte) with DLAB set.
 * uart_baud_rate_divisor_set()'s IOCTL disagrees with this - it writes
 * IER=low/RBR=high, the opposite of what uart_init() itself does on the
 * exact same registers - so it is not used here. */
static void uart_set_divisor(uintptr_t base, uint32_t divisor) {
    uart_regs_t *u = (uart_regs_t *)base;
    u->LCR |= (uint32_t)(1UL << 7UL);
    u->RBR = divisor & 0xFFU;
    u->IER = (divisor >> 8) & 0xFFU;
    u->LCR &= (uint32_t)(~(1UL << 7UL));
}

int main(void) {
    if (stdout_uart_fd > 0) {
        (void)uart_close(stdout_uart_fd);
    }

    /* Apply the SDM-provided pin-mux handoff (see file header). Must run
     * before anything touches a peripheral pin. */
    int32_t fsbl_rc = fsbl_configuration();
    const fsbl_handoff_t *hoff = (const fsbl_handoff_t *)handoff_array;
    uint32_t iob15_sel = hoff->pinmux_sel_array[2 * 38 + 1];   /* UART1 TX */
    uint32_t iob16_sel = hoff->pinmux_sel_array[2 * 39 + 1];   /* UART1 RX */

    /* Bring the clkmgr PLLs up from the same handoff blob (independent
     * read - see clkmgr_bringup.c) and read back the resulting UART
     * (L4_SP) clock. */
    uint32_t uart_clk_hz = 0;
    int32_t clk_rc = clkmgr_bringup(&uart_clk_hz);

    /* Release UART0/UART1 from peripheral reset. In the normal boot chain
     * this is done by ATF/SPL before anything else runs; here we are the
     * first and only thing that runs, so we have to do it ourselves. */
    int32_t rstmgr_handle = rstmgr_open("/dev/rstmgr", 0);
    if (rstmgr_handle >= 0) {
        hps_rstmgr_regs_t regs;
        (void)rstmgr_ioctl(rstmgr_handle, (int32_t)IOCTL_RSTMGR_READ, (uintptr_t)(&regs), sizeof(regs));
        regs.per1modrst &= ~((uint32_t)0x00030000);
        (void)rstmgr_ioctl(rstmgr_handle, (int32_t)IOCTL_RSTMGR_WRITE, (uintptr_t)(&regs), sizeof(regs));
        (void)rstmgr_close(rstmgr_handle);
    }

    int32_t uart1 = uart_open("/dev/uart1", 0);
    if (uart1 < 0) {
        /* Nothing more we can do without a working UART - spin so a JTAG
         * debugger can still attach and see we got this far. */
        while (1) {
        }
    }

    /* uart_open() -> uart_init() just programmed a divisor assuming a
     * 100 MHz clock. Override it with one computed from the clock we
     * actually measured. */
    uint32_t divisor = 0;
    if (uart_clk_hz > 0U) {
        divisor = uart_clk_hz / (115200U * 16U);
        if (divisor == 0U) {
            divisor = 1U;
        }
        uart_set_divisor((uintptr_t)uart1, divisor);
    }

    send_str(uart1, "\r\n\r\n=== de25_std_testproject HPS bare-metal UART1 test (v3) ===\r\n");
    send_str(uart1, "no ATF, no U-Boot, no Linux - running straight out of HPS OCRAM\r\n");
    send_str(uart1, "fsbl_configuration() rc = 0x");
    send_hex_u32(uart1, (uint32_t)fsbl_rc);
    send_str(uart1, "\r\nhandoff header_magic = 0x");
    send_hex_u32(uart1, hoff->header_magic);
    send_str(uart1, "\r\nIOB15 (UART1 TX) pinmux sel = 0x");
    send_hex_u32(uart1, iob15_sel);
    send_str(uart1, "\r\nIOB16 (UART1 RX) pinmux sel = 0x");
    send_hex_u32(uart1, iob16_sel);
    send_str(uart1, "\r\nclkmgr_bringup() rc = 0x");
    send_hex_u32(uart1, (uint32_t)clk_rc);
    send_str(uart1, "\r\nmeasured UART (L4_SP) clock = ");
    send_dec_u32(uart1, uart_clk_hz);
    send_str(uart1, " Hz\r\ndivisor programmed = ");
    send_dec_u32(uart1, divisor);
    send_str(uart1, "\r\ntype anything: it echoes back\r\n\r\n");

    uint32_t heartbeat = 0;
    while (1) {
        uint8_t c;
        size_t got = uart_recv(uart1, (uintptr_t)&c, 1, 0);
        if (got == 1U) {
            (void)uart_write(uart1, (uintptr_t)&c, 1);
        } else {
            heartbeat++;
            if ((heartbeat & 0x3FFU) == 0U) {
                send_str(uart1, "heartbeat 0x");
                send_hex_u32(uart1, heartbeat);
                send_str(uart1, "\r\n");
            }
        }
    }

    return 0; /* unreachable */
}
