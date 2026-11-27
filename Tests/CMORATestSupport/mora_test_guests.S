#if defined(__linux__) && (defined(__powerpc__) || defined(__ppc__)) && !defined(__powerpc64__) && __SIZEOF_POINTER__ == 4 && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
    .text
    .align 2
    .globl mora_test_leaf
    .type mora_test_leaf,@function
mora_test_leaf:
    add 3,3,4
    add 3,3,5
    add 3,3,6
    add 3,3,7
    add 3,3,8
    add 3,3,9
    add 3,3,10
    lwz 11,0(2)
    add 3,3,11
    xori 4,3,0x1234
    fadd 1,1,2
    fadd 1,1,3
    fadd 1,1,4
    fadd 1,1,5
    fadd 1,1,6
    fadd 1,1,7
    fadd 1,1,8
    fadd 1,1,9
    fadd 1,1,10
    fadd 1,1,11
    fadd 1,1,12
    fadd 1,1,13
    /* These registers are volatile to MORA, nonvolatile to Linux SysV. */
    fmr 9,1
    fmr 10,1
    fmr 11,1
    fmr 12,1
    fmr 13,1
    blr
    .size mora_test_leaf,.-mora_test_leaf

    .globl mora_test_import
    .type mora_test_import,@function
mora_test_import:
    mflr 0
    stw 0,8(1)
    stwu 1,-64(1)
    stw 2,20(1)
    lwz 12,0(2)
    lwz 2,4(2)
    mtctr 12
    bctrl
    lwz 2,20(1)
    addi 1,1,64
    lwz 0,8(1)
    mtlr 0
    blr
    .size mora_test_import,.-mora_test_import
    .section .note.GNU-stack,"",@progbits
#endif
