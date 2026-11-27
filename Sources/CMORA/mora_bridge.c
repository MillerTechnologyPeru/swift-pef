#include "mora.h"
#include <stddef.h>

_Static_assert(sizeof(MORATVector) == 8, "MORA TVector size");
_Static_assert(offsetof(MORATVector, tocAddress) == 4, "MORA TVector TOC");
_Static_assert(offsetof(MORAInvocationFrame, gpr) == MORA_FRAME_GPR, "MORA GPR offset");
_Static_assert(offsetof(MORAInvocationFrame, fpr) == MORA_FRAME_FPR, "MORA FPR offset");
_Static_assert(offsetof(MORAInvocationFrame, callerSP) == MORA_FRAME_CALLER_SP, "MORA SP offset");
_Static_assert(offsetof(MORAInvocationFrame, returnGPR) == MORA_FRAME_RETURN_GPR, "MORA result offset");
_Static_assert(offsetof(MORAInvocationFrame, returnGPR2) == MORA_FRAME_RETURN_GPR2, "MORA second result offset");
_Static_assert(offsetof(MORAInvocationFrame, returnFPR) == MORA_FRAME_RETURN_FPR, "MORA FP result offset");
_Static_assert(sizeof(MORAInvocationFrame) == MORA_FRAME_SIZE, "MORA invocation size");

#if defined(__linux__) && (defined(__powerpc__) || defined(__ppc__)) && !defined(__powerpc64__) && __SIZEOF_POINTER__ == 4 && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
#include <pthread.h>

typedef struct MORABridgeContext {
    struct MORABridgeContext *previous;
    MORADispatchFunction dispatch;
    void *userData;
    uint32_t hostR2;
    uint32_t hostR13;
} MORABridgeContext;

_Static_assert(sizeof(void *) == 4, "Native bridge requires PPC32 pointers");
_Static_assert(offsetof(MORABridgeContext, dispatch) == MORA_CONTEXT_DISPATCH, "Dispatcher offset");
_Static_assert(offsetof(MORABridgeContext, userData) == MORA_CONTEXT_USER_DATA, "Context offset");
_Static_assert(offsetof(MORABridgeContext, hostR2) == MORA_CONTEXT_HOST_R2, "Host r2 offset");
_Static_assert(offsetof(MORABridgeContext, hostR13) == MORA_CONTEXT_HOST_R13, "Host r13 offset");

/* Absolute addressing lets the import thunk recover host TLS before calling C. */
__attribute__((visibility("hidden"))) MORABridgeContext *mora_active_context;
static pthread_mutex_t entryMutex = PTHREAD_MUTEX_INITIALIZER;
static _Thread_local unsigned int entryDepth;

extern void mora_to_sysv_thunk(void);
extern void mora_sysv_to_guest(const MORATVector *, MORAInvocationFrame *, MORABridgeContext *);

uintptr_t mora_import_thunk_address(void) { return (uintptr_t)&mora_to_sysv_thunk; }

MORAStatus mora_call(const MORATVector *vector, MORAInvocationFrame *frame,
                     MORADispatchFunction dispatch, void *userData) {
    if (!vector || !frame || !dispatch || !vector->codeAddress || (vector->codeAddress & 3)) {
        return MORA_STATUS_INVALID_ARGUMENT;
    }
    if (entryDepth == 0 && pthread_mutex_lock(&entryMutex) != 0) { return MORA_STATUS_HOST_ERROR; }
    ++entryDepth;
    MORABridgeContext context = { mora_active_context, dispatch, userData, 0, 0 };
    mora_active_context = &context;
    mora_sysv_to_guest(vector, frame, &context);
    mora_active_context = context.previous;
    --entryDepth;
    if (entryDepth == 0 && pthread_mutex_unlock(&entryMutex) != 0) { return MORA_STATUS_HOST_ERROR; }
    return MORA_STATUS_SUCCESS;
}

#else

uintptr_t mora_import_thunk_address(void) { return 0; }

MORAStatus mora_call(const MORATVector *vector, MORAInvocationFrame *frame,
                     MORADispatchFunction dispatch, void *context) {
    (void)context;
    if (!vector || !frame || !dispatch || !vector->codeAddress || (vector->codeAddress & 3)) {
        return MORA_STATUS_INVALID_ARGUMENT;
    }
    return MORA_STATUS_UNAVAILABLE;
}

#endif
