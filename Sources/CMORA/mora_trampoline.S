#include "mora_offsets.h"
#if defined(__linux__) && (defined(__powerpc__) || defined(__ppc__)) && !defined(__powerpc64__) && __SIZEOF_POINTER__ == 4 && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
/*
 * mora_trampoline.S
 * PowerPC 32-bit Big-Endian (ppc32) ABI Bridge:
 *   Classic Mac OS 9 (MORA) <-> Linux System V ABI (Swift)
 */

    .text
    .align 2

/*
 * Guest-to-Host Thunk:
 * Guest PEF code loads r2 with `symbolIndex` from the synthetic TVector
 * and jumps via CTR to `mora_to_sysv_thunk`.
 */
    .hidden mora_to_sysv_thunk
    .globl mora_to_sysv_thunk
    .type mora_to_sysv_thunk, @function
mora_to_sysv_thunk:
    mflr    %r0
    stw     %r0, 8(%r1)             /* Save LR in MORA linkage area */
    mfcr    %r0
    stw     %r0, 4(%r1)             /* Save CR in MORA linkage area */

    /* Allocate SysV stack frame:
     * 16-byte SysV header + 160-byte invocation + saved guest registers/padding = 208 bytes */
    mr      %r11, %r1               /* Save guest caller SP in r11 */
    stwu    %r1, -208(%r1)

    /* Preserve SysV-reserved r13 and guest r2 (symbolIndex) */
    stw     %r13, 192(%r1)
    stw     %r2,  196(%r1)

    /* Populate MORAInvocationFrame at 16(%r1) */
    stw     %r3,  16(%r1)
    stw     %r4,  20(%r1)
    stw     %r5,  24(%r1)
    stw     %r6,  28(%r1)
    stw     %r7,  32(%r1)
    stw     %r8,  36(%r1)
    stw     %r9,  40(%r1)
    stw     %r10, 44(%r1)

    stfd    %f1,  48(%r1)
    stfd    %f2,  56(%r1)
    stfd    %f3,  64(%r1)
    stfd    %f4,  72(%r1)
    stfd    %f5,  80(%r1)
    stfd    %f6,  88(%r1)
    stfd    %f7,  96(%r1)
    stfd    %f8,  104(%r1)
    stfd    %f9,  112(%r1)
    stfd    %f10, 120(%r1)
    stfd    %f11, 128(%r1)
    stfd    %f12, 136(%r1)
    stfd    %f13, 144(%r1)

    stw     %r11, (16 + MORA_FRAME_CALLER_SP)(%r1)
    li      %r0, 0
    stw     %r0, (16 + MORA_FRAME_RETURN_GPR)(%r1)
    stw     %r0, (16 + MORA_FRAME_RETURN_GPR2)(%r1)
    stw     %r0, (16 + MORA_FRAME_RETURN_FPR)(%r1)
    stw     %r0, (20 + MORA_FRAME_RETURN_FPR)(%r1)

    /* Recover the serialized active entry without relying on guest r2/TLS. */
    bcl     20, 31, .Lcontext_pc
.Lcontext_pc:
    mflr    %r12
    addis   %r12, %r12, (.Lcontext_pointer-.Lcontext_pc)@ha
    lwz     %r12, (.Lcontext_pointer-.Lcontext_pc)@l(%r12)
    lwz     %r12, 0(%r12)
    lwz     %r2,  MORA_CONTEXT_HOST_R2(%r12)
    lwz     %r13, MORA_CONTEXT_HOST_R13(%r12)

    /* C ABI: dispatch(symbolIndex, &frame, userData). */
    lwz     %r3, 196(%r1)
    addi    %r4, %r1, 16
    lwz     %r5, MORA_CONTEXT_USER_DATA(%r12)
    lwz     %r12, MORA_CONTEXT_DISPATCH(%r12)
    mtctr   %r12
    bctrl

    /* Load return values from MORAInvocationFrame */
    lwz     %r3,  (16 + MORA_FRAME_RETURN_GPR)(%r1)          /* frame.returnGPR */
    lwz     %r4,  (16 + MORA_FRAME_RETURN_GPR2)(%r1)          /* frame.returnGPR2 */
    lfd     %f1,  (16 + MORA_FRAME_RETURN_FPR)(%r1)          /* frame.returnFPR */

    /* Restore guest r13, r2, SP, CR, LR */
    lwz     %r13, 192(%r1)
    lwz     %r2,  196(%r1)
    addi    %r1,  %r1, 208
    lwz     %r0,  4(%r1)
    mtcr    %r0
    lwz     %r0,  8(%r1)
    mtlr    %r0
    blr
    .size mora_to_sysv_thunk, .-mora_to_sysv_thunk

/*
 * Host-to-Guest Call:
 * void mora_sysv_to_guest(const MORATVector *, MORAInvocationFrame *, MORABridgeContext *)
 */
    .hidden mora_sysv_to_guest
    .globl mora_sysv_to_guest
    .type mora_sysv_to_guest, @function
mora_sysv_to_guest:
    mflr    %r0
    stw     %r0, 4(%r1)

    /* 24-byte linkage + 136-byte register argument homes + host saves, aligned to 16. */
    stwu    %r1, -256(%r1)
    stw     %r2, 160(%r1)
    stw     %r13, 164(%r1)
    stw     %r31, 168(%r1)

    /* MORA may clobber f9-f13; Linux SysV requires their preservation. */
    stfd    %f9, 176(%r1)
    stfd    %f10, 184(%r1)
    stfd    %f11, 192(%r1)
    stfd    %f12, 200(%r1)
    stfd    %f13, 208(%r1)
    stw     %r2, MORA_CONTEXT_HOST_R2(%r5)
    stw     %r13, MORA_CONTEXT_HOST_R13(%r5)

    mr      %r31, %r4               /* r31 = frame pointer */
    stw     %r1, MORA_FRAME_CALLER_SP(%r31)

    /* Load guest codeAddress -> CTR and guest tocAddress -> r2 */
    lwz     %r12, 0(%r3)
    lwz     %r2,  4(%r3)
    mtctr   %r12

    /* Load guest GPRs & FPRs from frame */
    lwz     %r3,  0(%r31)
    lwz     %r4,  4(%r31)
    lwz     %r5,  8(%r31)
    lwz     %r6,  12(%r31)
    lwz     %r7,  16(%r31)
    lwz     %r8,  20(%r31)
    lwz     %r9,  24(%r31)
    lwz     %r10, 28(%r31)

    lfd     %f1,  32(%r31)
    lfd     %f2,  40(%r31)
    lfd     %f3,  48(%r31)
    lfd     %f4,  56(%r31)
    lfd     %f5,  64(%r31)
    lfd     %f6,  72(%r31)
    lfd     %f7,  80(%r31)
    lfd     %f8,  88(%r31)
    lfd     %f9,  96(%r31)
    lfd     %f10, 104(%r31)
    lfd     %f11, 112(%r31)
    lfd     %f12, 120(%r31)
    lfd     %f13, 128(%r31)

    bctrl

    /* Save guest return values back into frame */
    stw     %r3,  MORA_FRAME_RETURN_GPR(%r31)         /* frame.returnGPR */
    stw     %r4,  MORA_FRAME_RETURN_GPR2(%r31)         /* frame.returnGPR2 */
    stfd    %f1,  MORA_FRAME_RETURN_FPR(%r31)         /* frame.returnFPR */

    /* Restore host-only nonvolatile floating-point registers. */
    lfd     %f9, 176(%r1)
    lfd     %f10, 184(%r1)
    lfd     %f11, 192(%r1)
    lfd     %f12, 200(%r1)
    lfd     %f13, 208(%r1)

    /* Restore host registers */
    lwz     %r2, 160(%r1)
    lwz     %r13, 164(%r1)
    lwz     %r31, 168(%r1)
    addi    %r1,  %r1, 256
    lwz     %r0,  4(%r1)
    mtlr    %r0
    blr
    .size mora_sysv_to_guest, .-mora_sysv_to_guest

    .section .got2,"aw"
    .align 2
.Lcontext_pointer:
    .long mora_active_context

    .section .note.GNU-stack,"",@progbits

#endif /* big-endian Linux PPC32 */
