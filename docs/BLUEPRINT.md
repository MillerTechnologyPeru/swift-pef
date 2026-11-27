# Architecture & Implementation Blueprint (`swift-pef`)

## Current PEFKit implementation

The library now provides:

- `PEFContainer.prepare`: validates caller-supplied section allocations, unpacks and zero-fills
  every instantiated section, applies relocations, and returns main/init/term entry addresses.
  It handles nonzero preferred section addresses and checks guest range alignment/overlap.
- `PEFLoaderSection.resolveImports`: resolves library metadata and symbols through host callbacks,
  checks complete/disjoint library ownership, and implements weak-library/weak-symbol rules.
- `PEFContainer`: validates section layout, retrieves section bytes/names, materializes initialized
  data and zero-fill, and checks loader section references.
- `PEFLoaderSection`: validates import/export tables, bounded loader strings and relocation
  streams; resolves section-relative, absolute (-2), and re-exported import (-3) symbols.
- `PEFRelocator`: executes all standard relocation families, including small/large repeats,
  using 32-bit section adjustments and resolved import addresses. Repeats cannot nest, must
  begin at instruction boundaries, and share a configurable operation budget.
- `ResourceFork`: validates maps, reference lists, Pascal names and length-prefixed payloads.
- `AppleDoubleReader` and `MacBinaryReader`: expose borrowed resource/data forks. MacBinary
  II/III headers are CRC checked and secondary headers honor 128-byte alignment.
- `XattrResourceReader`: reads into caller-owned storage through the CResourceIO platform shim.

Parsing and relocation operate without Foundation or internal buffer allocations. All returned
views require their caller-owned storage to remain alive and unchanged. Relocation can leave
partial fixups on error; discard the destination on failure. The default relocation budget is
1,000,000 operations, including writes and repeated instructions; callers may choose another limit.

Preparation flow:
1. Keep the source bytes alive and create a `PEFContainer`.
2. Obtain its optional `loaderSection()`. Allocate an import-address buffer with
   `totalImportedSymbolCount` words and call `resolveImports`. The library callback returns
   an opaque host registry ID or nil; the symbol callback returns a guest address or nil.
   A present weak library still must supply every required symbol.
3. Allocate one `PEFSectionAllocation` per instantiated section, in section order, using its
   `totalLength` and alignment. Keep guest ranges disjoint. The host pointer and guest address
   can differ; PEFKit does not map host virtual memory.
4. Provide one scratch word per section and call `prepare` with the resolved imports.
   All writable buffers must be disjoint from each other and from the source.
5. Use the returned guest entry-record addresses in the execution backend. PEFKit does not
   execute initialization/termination routines, enforce library version compatibility, or
   schedule library initialization; those are the host CFM runtime's responsibility.
   Export addresses remain available through `PEFLoaderSection.address(of:sectionAddresses:importedAddresses:)`.

Reference specifications:

- [Apple, Mac OS Runtime Architectures, PEF Structure](https://dev.os9.ca/techpubs/mac/runtimehtml/RTArch-89.html)
- [Apple, Resource File Format](https://dev.os9.ca/techpubs/mac/MoreToolbox/MoreToolbox-99.html)
- [Apple, AppleSingle/AppleDouble Developer's Note](https://nulib.com/library/AppleSingle_AppleDouble.pdf)
- [MacBinary original I/II/III specifications, preserved mirror](https://github.com/mietek/theunarchiver/wiki/MacBinarySpecs)

Validation includes synthetic format fixtures, native macOS xattr tests, and 30 local real-file
cases: preparation/export lookup/entry-vector relocation for 15 PowerPC PEF payloads and resource
parsing for their 15 AppleDouble sidecars. Payloads include MacGzip 1.1.3, MacZip 1.06, BBEdit Lite's
Classic and Carbon variants, and eleven BBEdit plug-ins. The full suite passes 187 cases.
Real-file tests use placeholder import addresses and never execute guest code. They use
`.build/fixtures` by default, allow `PEF_FIXTURES_DIR` to override the directory, and are disabled
when `manifest.json` is absent. Download provenance and hashes remain in the local manifest.
BlueBox now maps prepared sections into guest memory, initializes r1/r2 from a stack and the
entry TVector, and runs PPC32Core with a bounded instruction count and memory permissions.
Execution tests cover returns, loops, unsupported opcodes/imports, invalid entry addresses,
and memory faults. The Educate Quotes plug-in executes 15 instructions before an unmapped read;
the CLI runs MacGzip for 1,513 instructions, servicing nineteen Toolbox calls before stopping
at `InterfaceLib:StopAlert`. This is an error-reporting path rather than a successful launch;
the application's `evnt` Gestalt probe remains unsupported.
The initial per-run dispatcher bridges Graphite clocks and cursor state and implements
FlushEvents mask/stop-mask queue filtering. Host input delivery, cursor presentation, and
further QuickDraw operations still need integration. `InitGraf` writes the public globals
relative to the caller's `thePort` pointer, supports the InterfaceLib `qd` data import, and
uses a shared guest/Graphite 640×480 monochrome framebuffer. Tests cover packed field offsets,
big-endian encoding, application-owned globals, read-only destinations, and shared pixels.
Font initialization keeps a per-run Graphite registry and loads its built-in fallback once.
Font ID/default-size queries and checked Pascal font-name writes are bridged; tests cover
registry isolation, repeat initialization, unknown names, rejected destinations, and guest
readback. Host font discovery, resource-font loading, and text rendering shims remain pending.
Window Manager initialization creates a headless Graphite screen port and a guest-packed
108-byte GrafPort with valid visible/clip-region master pointers and rectangular region records.
GetWMgrPort returns its guest address; FrontWindow handles the initial empty window list.
Tests verify field offsets, guest region-handle dereferencing, repeat initialization, and
rejected output pointers. Window creation, desktop painting, and native presentation remain pending.
Menu initialization owns an empty list and draws a 20-pixel monochrome bar through Graphite
into the shared screen. DrawMenuBar, ClearMenuBar, and GetMBarHeight cover that initial state.
Tests check bar pixels and separator, desktop/current-port preservation, repeat initialization,
per-run isolation, redraw behavior, and the guest height-query call. Resource menus, menu
tracking, and menu color resources remain pending.
TextEdit initialization creates a guest master pointer for an empty private scrap, with
initial length and handle queries. Tests verify repeated initialization, per-run isolation,
failed writes, uninitialized queries, and guest dereferencing of the empty handle. TextEdit
records, editing, hooks, scrap resizing, and system clipboard transfer remain pending.
Dialog initialization records the guest resume pointer and establishes empty parameter
strings and the system font. SetDialogFont/SetDAFont and ParamText update per-run state.
ParamText copies all four checked Pascal strings before publishing the new values; import
faults now distinguish reads from writes. Tests cover valid/invalid guest calls, truncated
strings, MacRoman bytes, font aliases, and state isolation. Dialog creation, modal handling,
alert audio, and guest resume callback execution remain pending.
A fixed 16 MiB guest application zone backs first-fit pointer/handle allocations, logical
size queries, clearing, disposal, free-memory/error queries, and master-pointer pools in
64-entry blocks. MaxApplZone uses the already expanded zone. Free ranges coalesce; master
pointers remain stable. Tests cover exhaustion, zero-size allocations, master-pool growth,
reuse, invalid block kinds, failed-write rollback, guest pointer/handle access, and signed
MemError results. Resizing, compaction, purging, locking, callbacks, and system zones remain
pending. CPU memory permissions cover the whole heap mapping, not allocation lifetimes.
Gestalt bridges Graphite's selector table with an explicit guest profile: sysv=0x0900,
sysa=PowerPC, ram/lram=the 16 MiB budget, and qd=original monochrome QuickDraw. The compatibility
version does not imply complete API coverage. Unknown selectors return -5551 and leave the
response untouched; known responses use checked big-endian writes. Tests cover guest calls,
signed errors, invalid destinations, and the absence of host/optional-manager claims.
Application loading owns both forks, selecting native resource attributes before AppleDouble
sidecars for raw PEFs and preserving both MacBinary forks. Graphite reads the attached fork
and STR# lists for GetIndString; ResError exposes errors without confusing them with CPU faults.
Tests cover each fork source, native precedence, malformed sidecars/lists, absent resources,
signed resource IDs, indexes, MacRoman bytes, output bounds, guest readback, and MacGzip's
real fork. Resource chains, file switching, and writes remain pending.
Pascal/C conversion bridges include p2cstr/P2CStr, c2pstr/C2PStr, the copying variants, and
CopyPascalStringToC/CopyCStringToPascal. They snapshot source bytes for overlap, retain
MacRoman bytes, cap C-to-Pascal output at 255 bytes, and report checked read/write faults.
Tests cover argument order, pointer returns, aliases, overlap, terminators, empty/maximum
lengths, unmapped or read-only destinations, truncated input, address wraparound, and guest readback.
BlockMove/BlockMoveData and their uncached variants snapshot checked source ranges before
writing, preserving overlap semantics. Zero-length calls access no memory; negative Size
values, wrapped ranges, truncated reads, and rejected destinations produce memory faults.
Tests cover all four entry points, overlap in both directions, identical/disjoint buffers,
zero-length calls, range failures, protected code, and guest readback. Interpreter execution
reads instructions directly, so these bridges require no host instruction-cache operation.
GetResource/Get1Resource and GetString cache loaded guest-heap handles by resource type/ID.
ReleaseResource frees the payload and recycles its master pointer; DetachResource keeps
the allocation alive and removes the resource association. Handle disposal invalidates the
cache to prevent stale resource identities when master pointers are reused. Tests cover
signed IDs, stable handles, reload/release/detach, missing/empty resources, GetString,
payload-write rollback, and guest double dereferencing. Resource attributes, purging,
multiple resource files, and writeback remain pending.
Unknown libraries, symbols, and other data imports remain explicit failures. Further Toolbox
dispatch, complete application startup, Linux/ppc32 cross-platform tests, and Embedded
Swift validation remain outstanding.
The phases below describe the larger runtime roadmap.

## 1. Overview & Target Platforms
`swift-pef` provides a clean-room Classic Mac OS 9 PowerPC HLE runtime without requiring an Apple Mac OS ROM, System Folder disk image, or full-system CPU virtualization:
1. **QEMU `mac99` (`qemu-system-ppc -M mac99 -cpu G4`)**: Primary development, GDB debugging, and 2D software-rendered validation environment.
2. **Apple iBook G4 (`MPC7447A` + ATI Mobility Radeon 9200/9550)**: Bare-metal target leveraging native AltiVec (`v0–v31`) and Mesa `r200`/`r300` hardware-accelerated OpenGL.

---

## 2. Repository & Package Layout

```text
swift-pef/
├── Package.swift
├── README.md
├── docs/
│   ├── BLUEPRINT.md
│   ├── HOST_SETUP.md
│   └── EMBEDDED_SWIFT.md
├── Sources/
│   ├── CMORA/                          # Minimal PPC32 assembly & C ABI headers
│   │   ├── include/
│   │   │   ├── mora.h                  # TVector, MORAInvocationFrame, mac68k-packed structs
│   │   │   └── lowmem.h                # Low-memory globals (0x0000–0x2000)
│   │   └── mora_trampoline.S           # Guest <-> Host TOC (r2) & register save/restore stubs
│   ├── CMusashi/                       # Embedded 68020/040 CPU interpreter for kM68kISA UPPs
│   │   ├── include/musashi.h
│   │   └── ...
│   ├── PEFKit/                         # Library Target: Pure Swift PEF & CFM Container Engine
│   │   ├── PEFContainer.swift          # Joy!peff header & section table parser
│   │   ├── PEFSection.swift            # Code, UnpackedData, PatternData, Constant, Loader
│   │   ├── PEFPatternDecoder.swift     # Opcodes 0–4 pattern-initialized data unpacker
│   │   ├── PEFLoaderSection.swift      # Imported libraries, symbol table, export hash table
│   │   ├── PEFRelocator.swift          # 16-bit relocation VM bytecode interpreter
│   │   ├── CFMHash.swift               # PEFComputeHashWord & O(1) export slot lookup
│   │   └── ResourceFork/               # Resource Manager storage formats
│   │       ├── ResourceFork.swift      # Resource header, type list, name list parser
│   │       ├── AppleDoubleReader.swift # ._filename sidecar parser
│   │       ├── MacBinaryReader.swift   # MacBinary I/II/III (.bin) parser
│   │       └── XattrResourceReader.swift # Linux user.com.apple.ResourceFork reader
│   └── BlueBox/                        # Executable Target: Mac OS 9 HLE Runtime & Runner
│       ├── BlueBoxRunner.swift         # Process setup, 32-bit mmap layout, LowMem globals
│       ├── CFMRuntime.swift            # Fragment instantiation, init/term TVector execution
│       ├── MixedModeManager.swift      # RoutineDescriptor & kM68kISA Line-A trap bridge
│       ├── GraphiteBridge/
│       │   ├── CFMLibraryRegistry.swift # Maps (Library, Symbol) -> MORAHandler
│       │   ├── InterfaceLibShims.swift  # QuickDraw, Windows, Controls, Menus, Events, Memory
│       │   ├── CarbonLibShims.swift     # Carbon opaque accessors & event model
│       │   ├── FileManagerShims.swift   # HFS colon-path <-> POSIX & FSSpec/FSRef mapping
│       │   ├── SoundManagerShims.swift  # SndNewChannel / bufferCmd -> ALSA S16_BE
│       │   └── OpenGLAndSprockets.swift # agl* -> Mesa r200/r300 GLX & DrawSprocket -> SDL
│       └── main.swift                  # CLI entry point (`bluebox <AppPath>`)
└── Tests/
    ├── PEFKitTests/
    └── BlueBoxTests/
```

---

## 3. Core Technical Specifications

### 3.1 MORA <-> SysV `ppc32` ABI Bridge (`CMORA`)
Linux `ppc32` Swift compiles to the System V ABI, whereas Classic Mac OS 9 binaries use the **Mac OS Runtime for Architectures (MORA)** ABI.

| ABI Aspect | Classic Mac OS 9 (MORA) | Linux `ppc32` (SysV / Swift) |
| :--- | :--- | :--- |
| **Function Pointer** | Pointer to 8-byte `TVector { codePtr, tocR2 }` | Direct pointer to instruction address |
| **`r2` Register** | Guest fragment Table of Contents (TOC) | Reserved by SysV runtime (TLS / small data) |
| **Stack Linkage Area** | 24 bytes (`0(r1)` backchain, `4(r1)` CR, `8(r1)` LR, `20(r1)` saved `r2`) | 8 bytes (`0(r1)` backchain, `4(r1)` LR) |
| **Parameter Save Area** | Caller allocates 32 bytes (`24(r1)`–`55(r1)`) for `r3–r10` | No caller-allocated spill area for register args |
| **Non-Volatile Registers** | `r13–r31`, `f14–f31`, `v20–v31` | `r14–r31`, `f14–f31`, `v20–v31` (`r13` reserved in SysV) |

* **Guest-to-Host Thunk (`mora_to_sysv_thunk`):**
  1. Each resolved CFM import receives a synthetic 8-byte `TVector` in guest memory: `{ &mora_to_sysv_thunk, symbolHandlerID }`.
  2. When guest code calls an imported function, it loads `r2` with `symbolHandlerID` and branches via `CTR` to `mora_to_sysv_thunk`.
  3. The assembly stub saves `r13`, `LR`, `CR`, and AltiVec `VRSAVE`, restores the host Swift runtime's `r2`, packs `r3–r10`, `f1–f13`, and caller stack pointer `r1` into `MORAInvocationFrame`, and invokes `@_cdecl("swift_dispatch_cfm_call")`.
  4. Swift reads arguments directly from `MORAInvocationFrame`, invokes `PureSwift/Graphite`, writes return values to `frame.r3` / `frame.f1`, and returns to assembly to restore guest `r2` and `blr`.
* **Host-to-Guest Call (`sysv_to_mora_call`):**
  1. Saves host `r2` and `r13`, allocates a 56-byte MORA stack frame (`24` linkage + `32` parameter save area), loads `r3–r10` / `f1–f13` from `MORAInvocationFrame`, loads `r2 = tvector->tocR2`, and executes `bctrl` to `tvector->codePtr`.

### 3.2 `mac68k` Struct Alignment Compatibility
Classic Mac OS 9 binaries pack Toolbox structs using **2-byte (`mac68k`) alignment** rather than natural 4-byte PowerPC alignment:
* All guest-visible C structs in `CMORA/include/mora.h` (`EventRecord`, `FSSpec`, `BitMap`, `PixMap`, `CGrafPort`, `WindowRecord`, `ControlRecord`, `DialogRecord`, `DITL` items) are wrapped in `#pragma pack(push, 2)` / `#pragma pack(pop)`.
* `Graphite` Swift wrappers synchronize with `mac68k`-packed backing structures whenever pre-Carbon `InterfaceLib` apps directly read/write fields such as `thePort->portRect` or `((WindowPeek)w)->visible`.

### 3.3 Memory Map & Low-Memory Globals (`ppc32` 3G/1G Split)
* **`0x00000000`–`0x00002000`**: Mapped via `mmap(..., MAP_FIXED)` (requires `vm.mmap_min_addr=0` or a `SIGSEGV` instruction decoder fallback for `lwz`/`lhz`/`lbz` faults below `0x1000`). Backed by `LowMemGlobals` (`Ticks` at `0x016A` incremented at 60.15 Hz on a `CLOCK_MONOTONIC` thread, `Time` at `0x020C`, `CurrentA5`, `MemTop`).
* **`0x01000000`–`0x0FFFFFFF`**: Guest PEF `Code` (`PROT_READ | PROT_EXEC`) and `Data`/`pidata` (`PROT_READ | PROT_WRITE`) mappings, keeping all guest pointers within the lower 256 MB.
* **Master Pointer Table (`Handle`s)**: Page-aligned array of 32-bit `UInt32` guest addresses so double-dereferencing `*myHandle` and `HLock()`/`HUnlock()` operate at native memory speed.

### 3.4 Mixed-Mode Manager & 68k UPP Fallback
* `NewRoutineDescriptor` inspects `ISAType`:
  * `kPowerPCISA`: Wraps the guest `TVector` pointer for `sysv_to_mora_call`.
  * `kM68kISA`: Wraps the 68k instruction pointer in a `RoutineDescriptor` (`0xAAFE` magic). When `CallUniversalProc` is invoked on a `kM68kISA` UPP, `CMusashi` executes the 68k code against the shared 32-bit flat address space and traps `0xAxxx` Line-A opcodes back into `CFMLibraryRegistry`.

---

## 4. Phased Implementation Plan

### Phase 1: `PEFKit` & `CMORA` Core Loader (Weeks 1–2)
- Implement `PEFContainer`, section table parser, and `PEFPatternDecoder` (opcodes `0–4`).
- Implement `PEFRelocator` bytecode VM and `CFMHash` (`PEFComputeHashWord`).
- Implement `mora_trampoline.S` (`mora_to_sysv_thunk` and `sysv_to_mora_call`).
- **Validation**: Execute a headless CodeWarrior/MPW PPC PEF CLI binary on QEMU `mac99` calling `NewPtr`, `DisposePtr`, `TickCount`, and `StdCLib` `printf` via `Graphite`.

### Phase 2: `ResourceForkKit` & `GraphiteBridge` Foundation (Weeks 3–4)
- Implement `AppleDoubleReader` (`._*`), `MacBinaryReader` (`.bin`), and `XattrResourceReader` (`user.com.apple.ResourceFork`) in `PEFKit`.
- Wire `CFMLibraryRegistry` to expose `InterfaceLib`, `CarbonLib`, `ControlsLib`, `WindowsLib`, `MenusLib`, `DialogsLib`, `AppearanceLib`, `ThreadsLib`, and `MathLib` to `PureSwift/Graphite`.
- Implement HFS colon-path (`Volume:Folder:File`) <-> POSIX translation in `FileManagerShims`.
- **Validation**: Launch classic 2D Toolbox apps (*SimpleText*, *ResEdit*, *Tetris Max*) on QEMU `mac99` using `Graphite`'s SDL software renderer.

### Phase 3: Mixed-Mode 68k UPPs (`CMusashi`) & Audio (Weeks 5–6)
- Integrate `CMusashi` for `kM68kISA` `RoutineDescriptor` execution (custom `WDEF`/`CDEF`/`MDEF` resources and 68k completion callbacks).
- Bind `SoundManager` (`SndNewChannel`, `SndDoCommand`, `bufferCmd`, `callBackCmd`) and `SoundSprocket` to ALSA (`S16_BE` native big-endian ring buffer) on QEMU `mac99` (`screamer`/`AC97`) and iBook G4 (`snd-aoa`).
- **Validation**: Verify apps with custom `WDEF`/`CDEF` controls and multi-channel sound playback run cleanly.

### Phase 4: iBook G4 Hardware Acceleration (Weeks 7–8)
- Bind `OpenGLLibrary` (`aglChoosePixelFormat`, `aglCreateContext`, `aglSetDrawable`, `aglSwapBuffers`) directly to Mesa GLX/EGL (`r200`/`r300` Gallium3D).
- Bind `DrawSprocketLib` (`DSpContext_Reserve`, `DSpContext_SetState`, `DSpContext_SwapBuffers`) to KMS/SDL fullscreen mode switching with big-endian dirty-rect texture uploads (`GL_BGRA` / `GL_UNSIGNED_INT_8_8_8_8_REV` and `RGB555`).
- **Validation**: Run native PPC 3D games (*Bugdom*, *Cro-Mag Rally*, *Quake III Arena* PPC) on the iBook G4 at full hardware frame rates.
