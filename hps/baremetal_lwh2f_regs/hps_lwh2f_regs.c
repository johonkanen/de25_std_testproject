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
 * LWH2F_BASE: physical base address of the LWH2F bridge window as seen by
 * the ARM cores, 0x20000000 - per the Agilex 5 HPS Technical Reference
 * Manual (not locally available while this file was first drafted; an
 * earlier revision guessed 0xF9000000, the Stratix10/Agilex1 convention,
 * which hung the board on first read - see git history for that result).
 * Startup self-tests register 1 (the constant ID, 0x0000DE25) immediately
 * and prints PASS/FAIL before accepting commands.
 *----------------------------------------------------------------------*/
#include <stdint.h>

#include "clkmgr_bringup.h"
#include "fsbl_boot_help.h"
#include "hps_address_map.h"
#include "noc_firewall.h"
#include "rstmgr.h"
#include "rstmgr_regs.h"
#include "smmu.h"
#include "sysmgr.h"
#include "uart.h"
#include "uart_regs.h"

extern int32_t stdout_uart_fd;

/* Physical base address of the LWH2F window as seen by the ARM cores. */
#define LWH2F_BASE 0x20000000UL

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

#define RST_MGR_BRGMODRST_LWSOC2FPGA 0x00000002U
#define RST_MGR_HDSKREQ_LWSOC2FPGAFLUSHREQ 0x00000200U
#define RST_MGR_HDSKACK_LWSOC2FPGAFLUSHACK 0x00000200U
#define SYS_MGR_FPGA_BRIDGE_CTRL_LWSOC2FPGA_EN 0x00000002U

/* ~1ms-ish busy delay - no timer device opened in this minimal test, and
 * these are ATF's own settling margins, not tight protocol timing, so an
 * approximate/generous wait is fine. */
static void busy_delay(void) {
    for (volatile uint32_t i = 0; i < 300000U; i++) {
    }
}

static uint32_t rstmgr_get(int32_t rstmgr_handle, int32_t op) {
    uint32_t v = 0;
    (void)rstmgr_ioctl(rstmgr_handle, op, (uintptr_t)&v, sizeof(v));
    return v;
}

/* Bring the LWH2F bridge itself out of reset and enable it in the system
 * manager, using the sequence Intel's own arm-trusted-firmware uses for
 * Agilex 5 specifically (plat/intel/soc/common/soc/socfpga_reset_manager.c
 * socfpga_bridges_enable(), guarded #if PLATFORM_MODEL ==
 * PLAT_SOCFPGA_AGILEX5 - not the same, simpler protocol
 * baremetal-drivers' bridge_helper.cpp implements, which turns out to
 * match ATF's #else branch for older/non-Agilex5 SoCFPGA generations
 * instead). Found via freertos-socfpga
 * (github.com/Ignitarium-Software/freertos-socfpga)'s
 * samples/bridge/lwhps2fpga_bridge.c, which pointed at ATF's SMC handler
 * for its own enable_lwhps2fpga_bridge() call.
 *
 * Unlike the generic protocol (assert reset once, clear the ack/req
 * handshake, deassert), Agilex 5's is a full flush cycle: request the
 * handshake and WAIT FOR THE ACK TO ASSERT (not clear) before touching
 * reset at all, re-assert reset, clear the request, clear the ack
 * (write-1-to-clear), THEN deassert reset - only then enable in the
 * system manager. In the normal boot chain ATF does this before Linux/
 * U-Boot/FreeRTOS ever runs; running bare-metal with no ATF, nobody does
 * it unless we do. */
static void lwh2f_bridge_enable(int32_t rstmgr_handle, int32_t sysmgr_handle, int32_t dbg_fd) {
    uint32_t param = 0;

    uint32_t brgmodrst = rstmgr_get(rstmgr_handle, (int32_t)IOCTL_RSTMGR_GET_BRGMODRST);
    send_str(dbg_fd, "brgmodrst = 0x");
    send_hex_u32(dbg_fd, brgmodrst);
    send_str(dbg_fd, "\r\n");
    if (!(brgmodrst & RST_MGR_BRGMODRST_LWSOC2FPGA)) {
        send_str(dbg_fd, "LWSOC2FPGA already out of reset\r\n");
        return;
    }

    /* 1. Request the handshake (set, not clear) */
    param = rstmgr_get(rstmgr_handle, (int32_t)IOCTL_RSTMGR_GET_HDSKREQ);
    param |= RST_MGR_HDSKREQ_LWSOC2FPGAFLUSHREQ;
    (void)rstmgr_ioctl(rstmgr_handle, (int32_t)IOCTL_RSTMGR_SET_HDSKREQ, (uintptr_t)&param, sizeof(param));
    busy_delay();

    /* 2. Poll HDSKACK until it ASSERTS (not clears) */
    uint32_t i, ack = 0;
    for (i = 0; i < 3000000U; i++) {
        ack = rstmgr_get(rstmgr_handle, (int32_t)IOCTL_RSTMGR_GET_HDSKACK);
        if (ack & RST_MGR_HDSKACK_LWSOC2FPGAFLUSHACK) {
            break;
        }
    }
    send_str(dbg_fd, "hdskack assert poll: ");
    send_str(dbg_fd, (i < 3000000U) ? "asserted, iters=0x" : "TIMED OUT, iters=0x");
    send_hex_u32(dbg_fd, i);
    send_str(dbg_fd, " ack=0x");
    send_hex_u32(dbg_fd, ack);
    send_str(dbg_fd, "\r\n");
    busy_delay();

    /* 3. Assert reset (again, explicitly) */
    param = rstmgr_get(rstmgr_handle, (int32_t)IOCTL_RSTMGR_GET_BRGMODRST);
    param |= RST_MGR_BRGMODRST_LWSOC2FPGA;
    (void)rstmgr_ioctl(rstmgr_handle, (int32_t)IOCTL_RSTMGR_SET_BRGMODRST, (uintptr_t)&param, sizeof(param));
    busy_delay();

    /* 4. Clear the handshake request */
    param = rstmgr_get(rstmgr_handle, (int32_t)IOCTL_RSTMGR_GET_HDSKREQ);
    param &= ~RST_MGR_HDSKREQ_LWSOC2FPGAFLUSHREQ;
    (void)rstmgr_ioctl(rstmgr_handle, (int32_t)IOCTL_RSTMGR_SET_HDSKREQ, (uintptr_t)&param, sizeof(param));
    busy_delay();

    /* 5. Clear the ack (write-1-to-clear) */
    param = RST_MGR_HDSKACK_LWSOC2FPGAFLUSHACK;
    (void)rstmgr_ioctl(rstmgr_handle, (int32_t)IOCTL_RSTMGR_SET_HDSKACK, (uintptr_t)&param, sizeof(param));
    busy_delay();

    /* 6. Deassert reset */
    param = rstmgr_get(rstmgr_handle, (int32_t)IOCTL_RSTMGR_GET_BRGMODRST);
    param &= ~RST_MGR_BRGMODRST_LWSOC2FPGA;
    (void)rstmgr_ioctl(rstmgr_handle, (int32_t)IOCTL_RSTMGR_SET_BRGMODRST, (uintptr_t)&param, sizeof(param));
    param = rstmgr_get(rstmgr_handle, (int32_t)IOCTL_RSTMGR_GET_BRGMODRST);
    send_str(dbg_fd, "brgmodrst after deassert = 0x");
    send_hex_u32(dbg_fd, param);
    send_str(dbg_fd, "\r\n");

    /* 7. Enable the bridge in the system manager */
    (void)sysmgr_ioctl(sysmgr_handle, (int32_t)IOCTL_SYSMGR_GET_FPGA_BRIDGE_CTRL, (uintptr_t)&param, sizeof(param));
    send_str(dbg_fd, "fpga_bridge_ctrl before = 0x");
    send_hex_u32(dbg_fd, param);
    param |= SYS_MGR_FPGA_BRIDGE_CTRL_LWSOC2FPGA_EN;
    (void)sysmgr_ioctl(sysmgr_handle, (int32_t)IOCTL_SYSMGR_SET_FPGA_BRIDGE_CTRL, (uintptr_t)&param, sizeof(param));
    (void)sysmgr_ioctl(sysmgr_handle, (int32_t)IOCTL_SYSMGR_GET_FPGA_BRIDGE_CTRL, (uintptr_t)&param, sizeof(param));
    send_str(dbg_fd, " after = 0x");
    send_hex_u32(dbg_fd, param);
    send_str(dbg_fd, "\r\n");
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
    send_str(uart1, "\r\n");

    if (rstmgr_handle >= 0) {
        int32_t sysmgr_handle = sysmgr_open("/dev/sysmgr", 0);
        if (sysmgr_handle >= 0) {
            lwh2f_bridge_enable(rstmgr_handle, sysmgr_handle, uart1);
            (void)sysmgr_close(sysmgr_handle);
        } else {
            send_str(uart1, "sysmgr_open failed\r\n");
        }
        (void)rstmgr_close(rstmgr_handle);
    } else {
        send_str(uart1, "rstmgr_open failed\r\n");
    }

    /* NOC firewall: bridge_enable() only takes the bridge out of reset and
     * flags it enabled in the system manager - a *separate* per-master
     * security/permission register (noc_firewall0's LWSOC2FPGA SCR, same
     * one as hps_address_map.h's SOCFPGA_L4_LWHPS2FPA_SCR_BASE) gates
     * which masters may actually use it. Reset default locks this down;
     * in the normal boot chain ATF's security setup opens it before
     * anything else runs. Mirrors this driver's own noc_firewall test
     * (test/simics/noc_firewall/noc_firewall_test.c), which sets the same
     * bit for every bridge it exercises. */
    int32_t noc_fw_handle = noc_firewall_open("/dev/noc_firewall0", 0);
    if (noc_fw_handle >= 0) {
        uint32_t scr = 0;
        (void)noc_firewall_ioctl(noc_fw_handle, (int32_t)IOCTL_NOC_FIREWALL_GET_LWSOC2FPGA, (uintptr_t)&scr,
                                  sizeof(scr));
        send_str(uart1, "lwsoc2fpga SCR before = 0x");
        send_hex_u32(uart1, scr);
        scr = 0x1U;
        (void)noc_firewall_ioctl(noc_fw_handle, (int32_t)IOCTL_NOC_FIREWALL_SET_LWSOC2FPGA, (uintptr_t)&scr,
                                  sizeof(scr));
        (void)noc_firewall_ioctl(noc_fw_handle, (int32_t)IOCTL_NOC_FIREWALL_GET_LWSOC2FPGA, (uintptr_t)&scr,
                                  sizeof(scr));
        send_str(uart1, " after = 0x");
        send_hex_u32(uart1, scr);
        send_str(uart1, "\r\n");
        (void)noc_firewall_close(noc_fw_handle);
    } else {
        send_str(uart1, "noc_firewall_open failed\r\n");
    }

    /* Diagnostic only (read-only, no behaviour change yet): per
     * baremetal-drivers' own test/simics/bridge/bridge_test.c, "if SMMU
     * is enabled, then MBOX_HPS_FPGA_CONFIG_COMP isolates the connection
     * between HPS and FPGA" - i.e. there may be a required SDM mailbox
     * handshake, on top of everything above, before the SMMU lets HPS<->
     * FPGA traffic through at all. Check SMMU status first so a mailbox
     * implementation attempt isn't wasted if SMMU is already disabled
     * (in which case, per that same reference test's own logic, this
     * isn't the blocker). */
    int32_t smmu_handle = smmu_open("/dev/smmu0", 0);
    if (smmu_handle >= 0) {
        uint32_t smmu_iidr = 0, smmu_cr0 = 0;
        (void)smmu_ioctl(smmu_handle, (uint32_t)IOCTL_SMMU_IIDR_GET, (uintptr_t)&smmu_iidr, sizeof(smmu_iidr));
        (void)smmu_ioctl(smmu_handle, (uint32_t)IOCTL_SMMU_CR0_GET, (uintptr_t)&smmu_cr0, sizeof(smmu_cr0));
        send_str(uart1, "smmu IIDR = 0x");
        send_hex_u32(uart1, smmu_iidr);
        send_str(uart1, " CR0 = 0x");
        send_hex_u32(uart1, smmu_cr0);
        send_str(uart1, (smmu_cr0 & 0x1U) ? "  -> SMMU_EN set\r\n" : "  -> SMMU_EN clear\r\n");
        (void)smmu_close(smmu_handle);
    } else {
        send_str(uart1, "smmu_open failed\r\n");
    }

    /* self-test: register 1 is the constant id, 0x0000DE25 */
    uint32_t id = *lwh2f_reg(1);
    send_str(uart1, "self-test: register 1 (id) = 0x");
    send_hex_u32(uart1, id);
    if (id == 0x0000DE25U) {
        send_str(uart1, "  -> PASS\r\n");
    } else {
        send_str(uart1, "  -> FAIL (expected 0x0000DE25) - do not trust reads/writes below.\r\n");
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
