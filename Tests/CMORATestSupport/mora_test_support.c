#include "mora_test_support.h"
#if defined(__linux__) && (defined(__powerpc__) || defined(__ppc__)) && !defined(__powerpc64__) && __SIZEOF_POINTER__ == 4 && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
extern void mora_test_leaf(void);
extern void mora_test_import(void);
uintptr_t mora_test_leaf_address(void) { return (uintptr_t)&mora_test_leaf; }
uintptr_t mora_test_import_address(void) { return (uintptr_t)&mora_test_import; }
#else
uintptr_t mora_test_leaf_address(void) { return 0; }
uintptr_t mora_test_import_address(void) { return 0; }
#endif
