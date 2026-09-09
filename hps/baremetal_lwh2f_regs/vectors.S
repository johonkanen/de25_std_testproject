/* Minimal AArch64 exception vector table + common handler, EL3 only.
 *
 * Nothing in this project's bare-metal startup path (the toolchain's
 * default crt0, fsbl_boot_help.c, clkmgr_bringup.c) ever sets VBAR_EL3 -
 * it stays at its power-on-reset value of 0x0. That means any real
 * exception (e.g. a synchronous external abort from an AXI transaction
 * that never gets a response) vectors into whatever bytes happen to sit
 * at a fixed offset from address 0x0 - this program's own already-loaded
 * code/data, not a real handler - rather than hanging on one blocking
 * instruction the way it looks like from the UART's silence. This table
 * lets us actually see what happened (ESR/FAR/ELR) instead of guessing.
 *
 * Only entries for "Current EL with SPx" are meaningfully wired (the ones
 * that fire for exceptions taken while already running at EL3, which is
 * the only case relevant here); the rest just fall through to the same
 * common handler so nothing is silently unhandled.
 */
    .section .text
    .align 11                      /* 2^11 = 0x800, VBAR alignment */
    .global vector_table_el3
vector_table_el3:
    /* Current EL with SP0 */
    .align 7
    b   el3_common_handler
    .align 7
    b   el3_common_handler
    .align 7
    b   el3_common_handler
    .align 7
    b   el3_common_handler
    /* Current EL with SPx - the one that actually fires here */
    .align 7
    b   el3_common_handler         /* Synchronous */
    .align 7
    b   el3_common_handler         /* IRQ */
    .align 7
    b   el3_common_handler         /* FIQ */
    .align 7
    b   el3_common_handler         /* SError */
    /* Lower EL, AArch64 */
    .align 7
    b   el3_common_handler
    .align 7
    b   el3_common_handler
    .align 7
    b   el3_common_handler
    .align 7
    b   el3_common_handler
    /* Lower EL, AArch32 */
    .align 7
    b   el3_common_handler
    .align 7
    b   el3_common_handler
    .align 7
    b   el3_common_handler
    .align 7
    b   el3_common_handler

    .align 4
el3_common_handler:
    /* SP is whatever crt0 set up for main() - untouched by taking this
     * exception (SPx form), so it's safe to keep using it for a plain C
     * call here. We're not attempting to resume - just report and halt. */
    mrs     x0, esr_el3
    mrs     x1, far_el3
    mrs     x2, elr_el3
    bl      exception_report
1:  wfi
    b       1b

    .global vbar_el3_install
vbar_el3_install:
    adr     x0, vector_table_el3
    msr     vbar_el3, x0
    isb
    ret

    .global read_current_el
read_current_el:
    mrs     x0, CurrentEL
    lsr     x0, x0, #2
    ret
