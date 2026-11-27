# MORA ↔ Linux PPC32 SysV bridge

## Scope

CMORA now exposes a register-call bridge API for big-endian Linux PPC32. It remains separate
from the native PEF runner: BlueBox still reports nativeExecutionUnavailable on ppc32 until
native section mapping, import-vector construction, and execution integration are implemented.
Toolbox behavior belongs in Graphite; this layer only transports ABI state and dispatches calls.

The C entry point is:

```c
MORAStatus mora_call(const MORATVector *vector, MORAInvocationFrame *frame,
                     MORADispatchFunction dispatch, void *context);
```

The host supplies a Classic PowerPC TVector, register arguments, a C ABI dispatcher, and an
opaque context. mora_import_thunk_address() returns the import entry address on the native
target and zero elsewhere. A synthetic native import TVector contains that code address
and the import symbol index in its TOC word. The dispatcher receives the symbol index,
captured register frame, and the supplied context, then fills returnGPR/returnGPR2/returnFPR.

All other targets return MORA_STATUS_UNAVAILABLE without entering guest code. Invalid null
arguments, null code addresses, and unaligned code addresses return MORA_STATUS_INVALID_ARGUMENT.
These checks do not validate that a nonnull native pointer refers to mapped memory.

## Frame contract

| MORAInvocationFrame field | Offset | Size |
| --- | --- | --- |
| gpr: r3–r10 | 0 | 32 |
| fpr: f1–f13 | 32 | 104 |
| callerSP | 136 | 4 |
| returnGPR | 140 | 4 |
| returnGPR2 | 144 | 4 |
| alignment padding | 148 | 4 |
| returnFPR | 152 | 8 |
| Total | 0 | 160 |

mora_offsets.h shares layout constants with the assembler. C static assertions check the
actual structure offsets and size, including native context offsets on PPC32. Swift tests
also check the imported layout. Host calls populate callerSP with the actual guest call
frame; import calls capture the guest caller's stack pointer.

The host-to-guest trampoline allocates a 16-byte-aligned, 256-byte stack frame. It reserves
the MORA linkage and homes for the captured register arguments, preserves host r2/r13/r31,
and saves f9–f13, which are volatile under MORA but nonvolatile under Linux SysV. It loads
the target code/TOC, argument registers, and captures integer and floating-point results.

The import trampoline captures guest arguments before restoring host r2/r13 from the active
entry context. It calls the provided C dispatcher and restores the guest context before
returning. The active-context pointer is addressed through a PC-relative GOT entry so it
can be recovered while r2 holds a guest TOC/symbol index rather than host TLS state.

## Entry ownership and restrictions

Native entries are serialized with a pthread mutex. A thread-local entry depth permits
same-thread nested calls without reacquiring the mutex; stacked entry contexts restore the
outer dispatcher and host registers on return. This is an initial serialization strategy,
not concurrent execution of multiple guests.

Dispatchers must return normally. Exceptions/unwinding across the boundary, longjmp,
signal-handler entry, thread migration, or invoking an import thunk outside an active
mora_call are unsupported. Native execution uses the calling thread's stack and provides
no instruction budget, memory-fault containment, or cancellation mechanism.

Additional stack-passed arguments, vector arguments, separate guest stacks, and general
cross-architecture calls remain pending. The frame contains register snapshots; it does
not infer argument types or rearrange arbitrary C/MORA signatures automatically.

## Validation

The current arm64 macOS Xcode build succeeds: 239 tests pass and two native-only tests are
skipped. Those tests contain MORA assembly fixtures for all captured GPR/FPR arguments,
TOC access, return registers, and native import dispatch with an opaque context.

The installed Apple clang has no PowerPC assembler backend: attempting to assemble with
`-target powerpc-unknown-linux-gnu` reports an unknown target triple. Therefore the native
assembly and Linux-only C implementation have not yet been cross-built or executed.
Passing host tests does not establish native bridge correctness.

On a Linux PPC32 toolchain, first assemble the bridge and fixtures, then run:

```sh
swift test --filter MORABridgeTests
```

Before integrating the native runner, also verify host nonvolatile register preservation,
nested guest callbacks, concurrent host entry serialization, and PIE/shared-library linking
on real hardware or a suitable PPC32 environment. The existing leaf fixture deliberately
clobbers f9–f13; add an explicit host-register sentinel harness for preservation checks.

## References

- [PowerPC SysV ABI supplement](https://refspecs.linuxbase.org/elf/elfspec_ppc.pdf)
- [Apple: Mac OS Runtime Architectures](https://dev.os9.ca/techpubs/mac/pdf/MacOS_RT_Architectures.pdf)
