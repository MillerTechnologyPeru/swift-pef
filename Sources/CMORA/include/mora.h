#ifndef CMORA_MORA_H
#define CMORA_MORA_H

#include <stdint.h>
#include "mora_offsets.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Classic Mac OS PowerPC Transition Vector (8 bytes)
typedef struct MORATVector {
    uint32_t codeAddress;
    uint32_t tocAddress;
} MORATVector;

/// Register snapshot passed between mora_to_sysv_thunk / sysv_to_mora_call and Swift
typedef struct MORAInvocationFrame {
    uint32_t gpr[8];        // r3 .. r10
    double   fpr[13];       // f1 .. f13
    uint32_t callerSP;      // Guest r1 (for stack-passed arguments beyond r10 / f13)
    uint32_t returnGPR;     // r3 return value
    uint32_t returnGPR2;    // r4 secondary return value
    double   returnFPR;     // f1 floating-point return value
} MORAInvocationFrame;

typedef void (*MORADispatchFunction)(uint32_t symbolIndex, MORAInvocationFrame *frame, void *context);

typedef enum MORAStatus {
    MORA_STATUS_SUCCESS = 0,
    MORA_STATUS_UNAVAILABLE = 1,
    MORA_STATUS_INVALID_ARGUMENT = 2,
    MORA_STATUS_HOST_ERROR = 3
} MORAStatus;

/// Nonzero only on big-endian Linux PPC32. Returns zero on all other targets.
uintptr_t mora_import_thunk_address(void);

/// Invoke register-only MORA arguments on the calling thread's stack.
/// Native entries are serialized; same-thread nested callbacks are supported.
/// The dispatcher must return normally: no unwinding, longjmp, or signal-handler entry.
/// callerSP is output, identifying the MORA linkage/argument area used for this call.
/// Additional stack arguments, vector arguments, and fault containment are not provided.
MORAStatus mora_call(const MORATVector *tvector, MORAInvocationFrame *frame,
                     MORADispatchFunction dispatch, void *context);

// Classic Mac OS Toolbox structs require 2-byte (mac68k) alignment
#pragma pack(push, 2)

typedef struct MacPoint {
    int16_t v;
    int16_t h;
} MacPoint;

typedef struct MacRect {
    int16_t top;
    int16_t left;
    int16_t bottom;
    int16_t right;
} MacRect;

typedef struct MacEventRecord {
    uint16_t what;
    uint32_t message;
    uint32_t when;
    MacPoint where;
    uint16_t modifiers;
} MacEventRecord;

typedef struct MacFSSpec {
    int16_t vRefNum;
    int32_t parID;
    uint8_t name[64]; // Str63 Pascal string
} MacFSSpec;

#pragma pack(pop)

#ifdef __cplusplus
}
#endif

#endif // CMORA_MORA_H
