#if defined(__powerpc__) || defined(__ppc__)
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
    .globl mora_to_sysv_thunk
    .type mora_to_sysv_thunk, @function
mora_to_sysv_thunk:
    mflr    %r0
    stw     %r0, 8(%r1)             /* Save LR in MORA linkage area */
    mfcr    %r0
    stw     %r0, 4(%r1)             /* Save CR in MORA linkage area */

    /* Allocate SysV stack frame:
     * 16 bytes header + 168 bytes MORAInvocationFrame + 16 bytes NV regs = 208 bytes */
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

    stw     %r11, 152(%r1)          /* frame.callerSP */

    /* Restore host SysV r2 / r13 from global host context */
    lis     %r12, bluebox_host_r2@ha
    lwz     %r2,  bluebox_host_r2@l(%r12)
    lis     %r12, bluebox_host_r13@ha
    lwz     %r13, bluebox_host_r13@l(%r12)

    /* Call swift_dispatch_cfm_call(symbolIndex, &frame) */
    lwz     %r3,  196(%r1)          /* arg0: symbolIndex */
    addi    %r4,  %r1, 16           /* arg1: &frame */
    bl      swift_dispatch_cfm_call

    /* Load return values from MORAInvocationFrame */
    lwz     %r3,  156(%r1)          /* frame.returnGPR */
    lwz     %r4,  160(%r1)          /* frame.returnGPR2 */
    lfd     %f1,  168(%r1)          /* frame.returnFPR */

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
 * void sysv_to_mora_call(const MORATVector *tvector, MORAInvocationFrame *frame)
 */
    .globl sysv_to_mora_call
    .type sysv_to_mora_call, @function
sysv_to_mora_call:
    mflr    %r0
    stw     %r0, 4(%r1)

    /* Allocate 80-byte frame: 24 MORA linkage + 32 param save + 24 host save */
    stwu    %r1, -80(%r1)
    stw     %r2,  56(%r1)
    stw     %r13, 60(%r1)
    stw     %r31, 64(%r1)

    mr      %r31, %r4               /* r31 = frame pointer */

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
    stw     %r3,  140(%r31)         /* frame.returnGPR */
    stw     %r4,  144(%r31)         /* frame.returnGPR2 */
    stfd    %f1,  152(%r31)         /* frame.returnFPR */

    /* Restore host registers */
    lwz     %r2,  56(%r1)
    lwz     %r13, 60(%r1)
    lwz     %r31, 64(%r1)
    addi    %r1,  %r1, 80
    lwz     %r0,  4(%r1)
    mtlr    %r0
    blr
    .size sysv_to_mora_call, .-sysv_to_mora_call

    .bss
    .align 2
    .globl bluebox_host_r2
bluebox_host_r2:
    .long 0
    .globl bluebox_host_r13
bluebox_host_r13:
    .long 0

#endif /* __powerpc__ */
