#ifndef CMORA_LOWMEM_H
#define CMORA_LOWMEM_H

#include <stdint.h>

#define LOWMEM_BASE_ADDRESS 0x00000000u
#define LOWMEM_PAGE_SIZE    0x00002000u

// Key Classic Mac OS Low-Memory Global Offsets
#define LM_TICKS_OFFSET      0x016Au // UInt32: 60.15 Hz tick counter
#define LM_TIME_OFFSET       0x020Cu // UInt32: Seconds since Jan 1, 1904
#define LM_CURRENT_A5_OFFSET 0x0904u // UInt32: Current A5 world pointer
#define LM_MEM_TOP_OFFSET    0x0108u // UInt32: Top of logical RAM

#endif // CMORA_LOWMEM_H
