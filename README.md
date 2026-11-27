# swift-pef (`PEFKit` & `BlueBox`)

A native 32-bit big-endian PowerPC (`ppc32`) High-Level Emulation (HLE) loader and Code Fragment Manager (CFM) runtime written in Swift. `swift-pef` loads Classic Mac OS 9 Preferred Executable Format (`PEF`) binaries and binds their imported Toolbox and Carbon symbols directly to **`PureSwift/Graphite`** on Linux (`powerpc-unknown-linux-gnu`).

## Implementation status

PEFKit implements container/section validation and unpacking, all standard relocation opcode
families, import/export tables and CFM hash lookup, export address resolution, resource maps,
AppleDouble v1/v2, MacBinary I/II/III (including header CRC), and resource-fork xattrs.
The format parsers are Foundation-free and use caller-owned buffers. A small CResourceIO
target wraps macOS/Linux xattr system calls.

The library also prepares entire fragments in caller-owned section memory and resolves
imports through host callbacks, including weak imports. The test suite includes preparation
with nonzero preferred addresses, import ownership/weakness checks, malformed/truncated inputs, archive fixtures, and native macOS xattr reads.
Local integration tests pass against 15 real PowerPC PEF payloads from MacGzip, MacZip,
BBEdit Lite, and BBEdit plug-ins, plus their 15 resource forks. These tests cover preparation,
export lookup, and relocated entry vectors using placeholder import addresses; guest code
is not executed. Fixtures live in `.build/fixtures` (or `PEF_FIXTURES_DIR`) and the suite is
disabled when its fixture manifest is absent.
BlueBox maps prepared sections into `GuestAddressSpace`, reads the entry TVector, initializes
the stack and TOC, and executes through PPC32Core with checked memory and an instruction limit.
It reports unsupported imports by library and symbol, illegal opcodes, and memory faults.
The initial InterfaceLib dispatcher bridges `TickCount`, `GetDblTime`, `GetCaretTime`,
`InitCursor`, `HideCursor`, and `ShowCursor` to Graphite and handles `FlushEvents` against
per-run queue state. Host input delivery and cursor presentation remain pending.
`InitGraf` initializes packed guest QuickDraw globals, including the `qd` data import, and
Graphite shares a guest-backed 640×480 monochrome screen. Guest destinations are checked
before host writes; invalid or read-only pointers produce memory-fault diagnostics.
`InitFonts` prepares a per-run Graphite font registry with its built-in bitmap fallback.
`GetSysFont`, `GetAppFont`, `GetDefFontSize`, and `GetFontName` expose the configured defaults
and write checked MacRoman Pascal strings. Resource fonts and host font discovery remain pending.
`InitWindows` creates a headless monochrome Window Manager port over the shared screen,
with packed guest GrafPort and region handles. `GetWMgrPort` returns its guest address and
`FrontWindow` reports the initial empty window list. Window creation and presentation remain pending.
`InitMenus` creates headless menu state and draws an empty 20-pixel Roman-script menu bar
through Graphite. `DrawMenuBar`, `ClearMenuBar`, and `GetMBarHeight` support that initial state;
resource menus, menu tracking, and menu color resources remain pending.
`TEInit` creates an empty private-scrap handle in guest memory; `TEScrapHandle`,
`TEGetScrapHandle`, and `TEGetScrapLength` expose that initial state. TextEdit records,
editing, hooks, scrap resizing, and system clipboard transfer remain pending.
`InitDialogs` retains the guest resume pointer and initializes empty substitution strings
and the default dialog font. `SetDialogFont`/`SetDAFont` and `ParamText` update per-run state;
Pascal-string reads are range checked and copied. Dialog creation, modal handling, alert
audio, and guest callback invocation remain pending.
A bounded 16 MiB application heap supports `MaxApplZone`, `MoreMasters`, pointer/handle
allocation and clearing, disposal, size queries, `FreeMem`, and `MemError`. Master pointers
are guest addresses; freed blocks coalesce for reuse. Resizing, compaction, purging, locking,
grow-zone callbacks, and separate system zones remain pending. CPU access checks cover the
heap mapping rather than individual allocation lifetimes.
Gestalt uses an explicit guest profile: a Mac OS 9.0 compatibility version, PowerPC
architecture, 16 MiB memory budget, and monochrome QuickDraw. It writes checked big-endian
responses; unimplemented selectors return `gestaltUndefSelectorErr` without touching the
response. Host capabilities and optional managers are not advertised.
The CLI attaches application resource forks from native attributes, AppleDouble sidecars,
or MacBinary archives. `GetIndString` uses Graphite's `STR#` reader and copies a checked
Pascal string to guest memory; `ResError` reports missing or malformed resource errors.
Missing resources and out-of-range indexes produce empty strings. Only the application's
read-only resource fork is connected; resource handles, file chains, and writes remain pending.
Pascal/C string conversions support in-place and copying variants, their legacy aliases,
overlapping buffers, and checked guest reads/writes. Conversion preserves bytes and bounds
C-to-Pascal strings at 255 bytes.
MacGzip now converts its first resource string, reaching `InterfaceLib:BlockMoveData`
after 801 instructions.
Further Toolbox dispatch and full application startup remain pending, as do Linux/ppc32
and Embedded Swift validation.

Run a raw PEF or MacBinary with `bluebox --max-instructions 100000 /path/to/ClassicApp`.
Use `--entry init` or `--entry term` to select those entry vectors explicitly; initialization
and termination are not yet orchestrated automatically. Exit codes are 0 for a guest return,
124 for the instruction limit, 1 for an execution stop, and 2 for a loading or argument error.
The Graphite and device integrations below describe the intended architecture.

## Targets
- **`PEFKit`**: Foundation-free Swift library (Embedded Swift validation pending) implementing the `Joy!peff` container parser, `pidata` pattern-initialized data decompressor, 16-bit loader relocation VM, `PEFComputeHashWord` symbol lookup, and Resource Fork readers (AppleDouble `._*`, MacBinary `.bin`, Linux `xattr`).
- **`BlueBox`**: Classic Mac OS 9 HLE runner executable bridging the Mac OS Runtime for Architectures (MORA) ABI and `TVector`s to `PureSwift/Graphite`, with Musashi 68k UPP fallback (`kM68kISA`), ALSA big-endian audio, and dual presentation backends for **QEMU `mac99`** (software/SDL) and **Apple iBook G4** (Mesa `r200`/`r300` hardware OpenGL).

## Documentation Included
- `docs/BLUEPRINT.md` — Full architecture, memory map, MORA <-> SysV ABI specification, and phased execution plan.
- `docs/HOST_SETUP.md` — Kernel configuration, QEMU `mac99` launch commands, iBook G4 Mesa/AGP setup, and `ppc32` Swift build instructions.
- `docs/EMBEDDED_SWIFT.md` — Noncopyable (`~Copyable`) ownership patterns, typed throws, and existential-free CFM dispatch guidelines.

## Quick Start
```bash
# 1. Configure low-memory globals page mapping on ppc32 Linux
sudo sysctl -w vm.mmap_min_addr=0

# 2. Build PEFKit & BlueBox for powerpc-unknown-linux-gnu
swift build -c release -Xswiftc -wmo

# 3. Run a Classic Mac OS 9 PowerPC PEF application
.build/release/bluebox /path/to/ClassicApp
```
