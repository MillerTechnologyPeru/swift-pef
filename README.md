# swift-pef (`PEFKit` & `BlueBox`)

A native 32-bit big-endian PowerPC (`ppc32`) High-Level Emulation (HLE) loader and Code Fragment Manager (CFM) runtime written in Swift. `swift-pef` loads Classic Mac OS 9 Preferred Executable Format (`PEF`) binaries and binds their imported Toolbox and Carbon symbols directly to **`PureSwift/Graphite`** on Linux (`powerpc-unknown-linux-gnu`).

## Targets
- **`PEFKit`**: Embedded-Swift compatible (`-enable-experimental-feature Embedded`) pure-Swift library implementing the `Joy!peff` container parser, `pidata` pattern-initialized data decompressor, 16-bit loader relocation VM, `PEFComputeHashWord` symbol lookup, and Resource Fork readers (AppleDouble `._*`, MacBinary `.bin`, Linux `xattr`).
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
