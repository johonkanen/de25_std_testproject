/*------------------------------------------------------------------------
 * hps_lwh2f_regs.c - minimal bare-metal test letting a human, typing over
 * HPS UART1, read/write the fpga_interconnect register file
 * (uart_register_block.vhd) through the HPS's lwhps2fpga (LWH2F)
 * lightweight bridge - the same registers the fabric UART already
 * reaches, now poked from the ARM cores instead.
 *
 * Startup sequence is identical to hps_uart1_test.c (see that file /
 * hps/baremetal_uart1_test/README.md for the full account): pin-mux
 * (fsbl_configuration()), clock-manager PLL bring-up (clkmgr_bringup.c),
 * then UART1 opened and its baud divisor reprogrammed against the
 * measured clock. No ATF, no U-Boot, no Linux, no SD card.
 *
 * *** LWH2F_BASE IS UNVERIFIED - READ THIS ***
 * Intel's Agilex 5 HPS Technical Reference Manual documents the physical
 * address the ARM cores use to reach the LWH2F bridge window, but that
 * manual was not available while writing this file. Exhaustive search of
 * every locally available source - baremetal-drivers (inc. its "bridge"
 * test, which turns out to be about QSPI/NAND reset control, not FPGA
 * bridges), arm-trusted-firmware, u-boot-socfpga, linux-socfpga's device
 * trees (which don't expose a DT node for it on ANY Intel SoCFPGA
 * generation), and both sibling repos this is adapted from - turned up
 * no documented address. LWH2F_BASE below is the address Cyclone V's
 * immediate successors (Arria 10, Stratix 10, Agilex 1/7) have used since
 * their L3-remap generation; Agilex 5 is a newer NOC-based design and may
 * not match. Startup self-tests register 1 (the constant ID, 0x0000DE25)
 * immediately and prints PASS/FAIL before accepting commands - if it
 * prints FAIL (or nothing at all), this address is wrong for this chip;
 * try another candidate and reprogram (`quartus_pgm`, nothing persistent
 * is touched, so this is always safely recoverable) rather than trusting
 * anything this program reads back.
 *----------------------------------------------------------------------*/
#include <stdint.h>

#include "clkmgr_bringup.h"
#include "fsbl_boot_help.h"
#include "hps_address_map.h"
#include "rstmgr.h"
#include "rstmgr_regs.h"
#include "uart.h"
#include "uart_regs.h"

extern int32_t stdout_uart_fd;

/* Physical base address of the LWH2F window as seen by the ARM cores -
 * UNVERIFIED for Agilex 5, see the file header. */
#define LWH2F_BASE 0xF9000000UL

/* axi_lwh2f_bridge.vhd decodes AXI address bits [19:4] as the register
 * number - each fpga_interconnect register is a 16-byte-aligned LWH2F
 * offset. */
static inline volatile uint32_t *lwh2f_reg(uint32_t n) {
    return (volatile uint32_t *)(LWH2F_BASE + ((uintptr_t)n << 4));
}

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

static void uart_set_divisor(uintptr_t base, uint32_t divisor) {
    uart_regs_t *u = (uart_regs_t *)base;
    u->LCR |= (uint32_t)(1UL << 7UL);
    u->RBR = divisor & 0xFFU;
    u->IER = (divisor >> 8) & 0xFFU;
    u->LCR &= (uint32_t)(~(1UL << 7UL));
}

static int32_t recv_char_blocking(int32_t fd) {
    uint8_t c;
    while (uart_recv(fd, (uintptr_t)&c, 1, 0) != 1U) {
        /* spin */
    }
    return (int32_t)c;
}

/* Read one line (up to CR or LF), echoing every byte back so a terminal
 * shows what was typed. Supports backspace (0x08 / 0x7F). Returns the
 * length, excluding the terminator. */
static size_t read_line(int32_t fd, char *buf, size_t max_len) {
    size_t len = 0;
    while (1) {
        int32_t c = recv_char_blocking(fd);
        if (c == '\r' || c == '\n') {
            (void)uart_write(fd, (uintptr_t)"\r\n", 2);
            buf[len] = '\0';
            return len;
        }
        if ((c == 0x08 || c == 0x7F) && len > 0) {
            len--;
            (void)uart_write(fd, (uintptr_t)"\x08 \x08", 3);
            continue;
        }
        if (len + 1 < max_len && c >= 0x20 && c < 0x7F) {
            buf[len++] = (char)c;
            (void)uart_write(fd, (uintptr_t)&c, 1);
        }
    }
}

/* Parses an unsigned integer: "0x..." / "0X..." as hex, otherwise
 * decimal. Returns the number of characters consumed, or 0 on error. */
static size_t parse_uint(const char *s, uint32_t *out) {
    const char *p = s;
    uint32_t base = 10;
    uint32_t v = 0;
    size_t n = 0;

    if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
        base = 16;
        p += 2;
    }
    while (*p != '\0') {
        uint32_t digit;
        if (*p >= '0' && *p <= '9') {
            digit = (uint32_t)(*p - '0');
        } else if (base == 16 && *p >= 'a' && *p <= 'f') {
            digit = (uint32_t)(*p - 'a' + 10);
        } else if (base == 16 && *p >= 'A' && *p <= 'F') {
            digit = (uint32_t)(*p - 'A' + 10);
        } else {
            break;
        }
        v = v * base + digit;
        p++;
        n++;
    }
    if (n == 0) {
        return 0;
    }
    *out = v;
    return (size_t)(p - s);
}

static void skip_spaces(const char **p) {
    while (**p == ' ') {
        (*p)++;
    }
}

static void print_help(int32_t fd) {
    send_str(fd, "\r\ncommands:\r\n"
                 "  r <reg>          - read fpga_interconnect register <reg>\r\n"
                 "  w <reg> <value>  - write <value> to register <reg>\r\n"
                 "  ?                - this help\r\n"
                 "register map (see uart_register_block.vhd):\r\n"
                 "  1 id (RO)  2 git hash (RO)  3 loopback (RW)  4 read counter (RO)\r\n"
                 "  5 LED reg (RW)  6 SW (RO)  7 KEY (RO)  8 uptime counter (RO)\r\n"
                 "values/registers: decimal, or 0x-prefixed hex\r\n\r\n");
}

int main(void) {
    if (stdout_uart_fd > 0) {
        (void)uart_close(stdout_uart_fd);
    }

    int32_t fsbl_rc = fsbl_configuration();
    (void)fsbl_rc;

    uint32_t uart_clk_hz = 0;
    int32_t clk_rc = clkmgr_bringup(&uart_clk_hz);
    (void)clk_rc;

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
        while (1) {
        }
    }

    if (uart_clk_hz > 0U) {
        uint32_t divisor = uart_clk_hz / (115200U * 16U);
        if (divisor == 0U) {
            divisor = 1U;
        }
        uart_set_divisor((uintptr_t)uart1, divisor);
    }

    send_str(uart1, "\r\n\r\n=== de25_std_testproject HPS LWH2F register test ===\r\n");
    send_str(uart1, "reads/writes uart_register_block.vhd's registers over lwhps2fpga\r\n");
    send_str(uart1, "LWH2F_BASE = 0x");
    send_hex_u32(uart1, (uint32_t)LWH2F_BASE);
    send_str(uart1, "  -  UNVERIFIED for Agilex 5, see this file's header\r\n");

    /* self-test: register 1 is the constant id, 0x0000DE25 */
    uint32_t id = *lwh2f_reg(1);
    send_str(uart1, "self-test: register 1 (id) = 0x");
    send_hex_u32(uart1, id);
    if (id == 0x0000DE25U) {
        send_str(uart1, "  -> PASS, LWH2F_BASE is correct\r\n");
    } else {
        send_str(uart1, "  -> FAIL (expected 0x0000DE25) - LWH2F_BASE is wrong for this chip;\r\n"
                        "     do not trust reads/writes below, try another candidate address.\r\n");
    }

    print_help(uart1);

    char line[64];
    while (1) {
        send_str(uart1, "> ");
        size_t len = read_line(uart1, line, sizeof(line));
        const char *p = line;
        skip_spaces(&p);

        if (len == 0) {
            continue;
        }
        if (*p == '?') {
            print_help(uart1);
            continue;
        }
        if (*p == 'r' && (p[1] == ' ' || p[1] == '\0')) {
            p++;
            skip_spaces(&p);
            uint32_t reg;
            if (parse_uint(p, &reg) == 0U) {
                send_str(uart1, "usage: r <reg>\r\n");
                continue;
            }
            uint32_t value = *lwh2f_reg(reg);
            send_str(uart1, "reg ");
            send_hex_u32(uart1, reg);
            send_str(uart1, " = 0x");
            send_hex_u32(uart1, value);
            send_str(uart1, "\r\n");
            continue;
        }
        if (*p == 'w' && (p[1] == ' ' || p[1] == '\0')) {
            p++;
            skip_spaces(&p);
            uint32_t reg;
            size_t n = parse_uint(p, &reg);
            if (n == 0U) {
                send_str(uart1, "usage: w <reg> <value>\r\n");
                continue;
            }
            p += n;
            skip_spaces(&p);
            uint32_t value;
            if (parse_uint(p, &value) == 0U) {
                send_str(uart1, "usage: w <reg> <value>\r\n");
                continue;
            }
            *lwh2f_reg(reg) = value;
            send_str(uart1, "wrote 0x");
            send_hex_u32(uart1, value);
            send_str(uart1, " to reg ");
            send_hex_u32(uart1, reg);
            send_str(uart1, "\r\n");
            continue;
        }
        send_str(uart1, "unknown command - '?' for help\r\n");
    }

    return 0; /* unreachable */
}
