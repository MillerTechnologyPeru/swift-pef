# Graphite changes required by BlueBox

## Objective

Keep Classic Mac OS behavior, state, validation rules, and result-code decisions in Graphite.
BlueBox should marshal guest arguments, perform checked memory access, load PEF fragments,
and invoke guest code. Native ppc32 execution and interpretation on other architectures must
use the same Graphite services.

This is an implementation handoff. API names below are proposals, not existing interfaces.
The inspected Graphite checkout is master at `7ab800a0dfa4a231ac18703e150227c2152b56aa`.

## Current baseline

The last committed integration passes 236 tests. BBEdit Lite stops at the unsupported
`EqualString` import after 12,494 instructions and 20 serviced imports. MacGzip still presents
its compatibility alert; MacZip stops at `InitMenus`.

An uncommitted BlueBox-local EqualString prototype temporarily advanced BBEdit to
`GetSharedLibrary` at 13,632 instructions. That prototype was removed: the string behavior
must be implemented and tested in Graphite before BlueBox adds its adapter. Those later
instruction counts are exploratory evidence, not the committed compatibility baseline.

Graphite already supplies PascalString/MacRoman, AppleEventDispatcher/Descriptor,
ClassicEventManager/ClassicEventQueue, FileSystem/Fork, resources, and QuickDraw. Extend
these implementations rather than creating parallel Toolbox behavior in BlueBox.

## 1. EqualString: next required feature

Add the complete Roman-script EqualString operation to GraphiteBase or a Text Utilities
module, using PascalString inputs and independent case/diacritic sensitivity options.

```swift
// Proposed public surface; final naming can follow Graphite conventions.
public enum TextUtilities {
    public static func equalString(
        _ first: PascalString,
        _ second: PascalString,
        caseSensitive: Bool,
        diacriticSensitive: Bool
    ) -> Bool
}
```

Required behavior:

- Follow the Macintosh filesystem comparison rules documented for EqualString. Do not
  substitute localized Unicode collation or IdenticalString semantics.
- Define and test the complete 256-byte Roman comparison behavior, including accented
  letters, ligatures, sharp-s, punctuation, and control bytes. Verify historical equivalences
  from authoritative specifications or independently obtained reference results.
- Preserve Pascal-string length semantics, including embedded NUL bytes and 255-byte inputs.
- Make all four sensitivity combinations deterministic across hosts. Avoid behavior that
  changes with the host locale or OS Unicode database.
- Keep non-Roman script support explicit; do not advertise script-manager completeness.

Graphite acceptance tests should cover ASCII and accented case pairs, diacritic pairs,
ligatures, unequal lengths, empty strings, embedded zeros, maximum lengths, and the full
byte mapping. Test known expected results, not only reflexivity or the implementation table.

The subsequent BlueBox change should only read two checked Pascal strings, decode the
low byte of each Boolean argument, call Graphite, and return Boolean 0/1. Add one interpreted
PEF test and rerun BBEdit. No folding tables should remain in BlueBox.

## 2. Code Fragment Manager services

Introduce a Graphite-owned connection/export service, with resolved symbol metadata supplied
by the PEF loader. Keep PEF parsing and relocation in PEFKit; avoid a dependency cycle between
Graphite and swift-pef.

Required operations:

- Register a prepared connection with its identity, library name, architecture, main symbol,
  ordered exports, and lifecycle state.
- FindSymbol, CountSymbols, and GetIndSymbol: exact symbol-name bytes, symbol classes,
  valid connection checks, documented indexing, and CFM result codes.
- GetSharedLibrary: distinguish lookup of a registered library from loading an unavailable
  library. Preserve architecture and load-flag checks, unresolved/weak import semantics,
  and reference counts. Never return success for a library with no registered implementation.
- Represent initialization and termination requests as host execution requests. Commit a
  connection's initialized state only after the host reports successful guest execution.
- CloseConnection and invalid/stale connection behavior.

Graphite should return a typed symbol address/identity supplied by the host, not invoke it
as a host function pointer. The host remains responsible for preparing PEF sections and
executing initializer/terminator TVectors.

Migrate lookup and connection rules from GuestFragmentSymbols and ToolboxRuntime into this
service. BlueBox should supply PEFKit's resolved exports and marshal outputs. Preserve the
existing section-relative, absolute, and re-export integration tests.

## 3. File Manager: injectable storage and transaction semantics

Graphite's current Fork initializer opens a host path. BlueBox currently duplicates a small
read-only catalog to expose logical application forks, including MacBinary-extracted bytes.
Provide a storage interface in Graphite that supports immutable snapshots as well as the
existing POSIX-backed implementation.

Graphite must own:

- Volumes, directory IDs, FSSpec lookup, name comparison, permissions, and reference numbers.
- Independent data/resource fork marks and open/close lifecycle.
- Synchronous reads and positioning, partial EOF, actual counts, and File Manager errors.
- Explicit policies for advanced I/O flags, write access, and asynchronous completion.
- A read operation that can be committed after host output succeeds, or an equivalent
  transaction API. Failed guest writes must not silently advance an open fork's mark.

Keep guest addresses opaque to the storage implementation. The host can supply a checked
output sink or acknowledge a prepared read. Provide an in-memory backend in Graphite's own
tests so permission, EOF, independent-mark, and reference-reuse behavior is tested there.

Expose reusable packed-record codecs for FSSpec and IOParam if these records are part of
Graphite's public ABI layer. Codecs must specify byte order and two-byte alignment; the
IOParam long at byte 46 must not require aligned host loads. BlueBox only reads/writes the
resulting byte buffers and handles memory faults.

Migrate GuestFileManager policy and parameter-block result generation out of BlueBox.
Keep adapter tests for invalid addresses, partial output faults, and interpreted FSRead/PBReadSync.

## 4. AppleEvents and event retrieval

Extend the existing Graphite dispatcher rather than maintaining a second event system.

- Provide handler selection and an invocation request usable with opaque guest UPPs and
  refcons, followed by completion with the guest's signed OSErr and reply changes.
- Own launch-event lifecycle, handler fallback, borrowing/ownership of descriptors, nested
  delivery policy, parameter mutation, coercion, and reply/error semantics.
- Define canonical conversion of descriptor scalar values between host and Classic guest
  byte order. BlueBox should not special-case individual event attributes.
- Support opaque descriptor identities with generation/lifetime validation so a disposed
  and reused guest Handle cannot revive an old descriptor.
- Integrate launch events with ClassicEventManager, including EventAvail, GetNextEvent,
  and WaitNextEvent behavior through a host event source.
- Correct ClassicEventQueue's mask matching for high-level events: event kind 23 uses
  highLevelEventMask `0x0400`, rather than a direct shift by the event kind. Verify other
  special event masks against Apple's definitions too.

Preserve the existing initial oapp integration test, Toolbox calls from inside its handler,
negative OSErr propagation, shared instruction limits, descriptor cleanup, and fault reporting.
Keep `evnt` unadvertised until the supported AppleEvent surface warrants that capability.

## 5. Memory Manager and Mixed Mode

Provide Graphite-owned allocation/handle policy over an injected guest-address allocator.
That includes size/error rules, master-pointer lifetime, resource ownership, and generation
tracking. BlueBox supplies the backing address ranges and checked copying primitives.

Move Mixed Mode record encoding/validation into a shared Graphite ABI service. Represent
the decoded target, ISA, procedure information, and selector behavior as data. Define support
for version-seven descriptors, prepared/relative targets, and multi-record selection explicitly.
Do not silently reinterpret an unsupported 68k routine as PowerPC code.

BlueBox retains CPU invocation and ABI entry/exit handling. Its interpreter and native MORA
path must consume the same decoded invocation request. Instruction limits and guest-register
preservation belong to the execution backend, not Toolbox policy.

## Migration map

| Current BlueBox responsibility | Required Graphite owner | Remaining BlueBox work |
| --- | --- | --- |
| EqualString comparison | Text Utilities | Checked Pascal-string reads and Boolean ABI |
| GuestFragmentSymbols | CFM connection/export service | Supply PEFKit-resolved metadata |
| GuestFileManager | FileSystem with injectable fork storage | Register logical forks and marshal calls |
| IOParam result/count/position rules | File Manager operation results and ABI codec | Checked guest reads/writes |
| Descriptor ownership and scalar conversion | AppleEvents descriptor service | Translate opaque guest identities |
| Launch-event state and delivery rules | AppleEvents and ClassicEventManager | Execute requested guest callbacks |
| GuestHeap allocation/handle policy | Memory Manager with injected allocator | Reserve/map guest address space |
| RoutineDescriptor format and selection | Mixed Mode ABI service | Invoke the decoded native/interpreted target |
| Headless window/menu/dialog semantics | Existing Graphite managers | Supply headless host facilities and surfaces |

## Delivery order and verification

1. Implement and test EqualString in Graphite; update the dependency and add the thin adapter.
2. Implement the CFM registry/GetSharedLibrary surface exposed by the next BBEdit stop.
3. Add snapshot fork storage and move the existing File Manager policy into Graphite.
4. Consolidate AppleEvent/event lifecycle and byte-order conversion.
5. Consolidate heap/handle and Mixed Mode policy, then remove duplicate BlueBox implementations.

For each stage, Graphite tests verify Toolbox semantics. BlueBox tests verify guest byte
layout, checked memory, execution handoff, and real-application behavior. Record actual
remaining unsupported imports; do not report a diagnostic stop as a successful app launch.
Keep one commit per changed file.

The interpreter must compile for every architecture except `arch(powerpc)` (ppc32). Shared
reports and invocation types must not depend on EmulatedPPCBackend. Native ppc32 execution
still requires the MORA runner integration; excluding the interpreter does not complete it.

## References

- [Apple: sorting and equality routines](https://dev.os9.ca/techpubs/mac/Text/Text-287.html)
- [Apple: FindSymbol](https://dev.os9.ca/techpubs/mac/PPCSoftware/PPCSoftware-58.html)
- [Apple: CFM summary and initialization block](https://dev.os9.ca/techpubs/mac/PPCSoftware/PPCSoftware-66.html)
- [Apple: File Manager](https://dev.os9.ca/techpubs/mac/pdf/Files/Intro_to_Files.pdf)
- [Apple: Device Manager packed I/O structures](https://dev.os9.ca/techpubs/mac/Devices/Devices-52.html)
- [Apple: responding to AppleEvents](https://dev.os9.ca/techpubs/mac/pdf/Interapplication_Communication/Responding_to_AEs.pdf)
- [Apple: Mixed Mode summary](https://leopard-adc.pepas.com/documentation/mac/PPCSoftware/PPCSoftware-39.html)
