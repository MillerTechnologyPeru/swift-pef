# Embedded Swift & Noncopyable (`~Copyable`) Architecture Guide

`PEFKit` is designed to compile cleanly under **Embedded Swift** (`-enable-experimental-feature Embedded`) on `powerpc-unknown-linux-gnu` (`ppc32` BE), eliminating runtime reflection metadata, existential heap boxes, and ARC overhead.

PEFKit currently builds with standard Swift and BinaryParsing, rather than Embedded Swift.
The format APIs use typed throws and caller-owned buffers; native xattrs are isolated in
CResourceIO. Embedded compilation remains a separate validation step.

`PEFContainer`, `PEFLoaderSection`, and `ResourceFork` are noncopyable views, not buffer owners.
Their unsafe pointers do not enforce the backing storage's lifetime: create and use a view
inside the source buffer's lifetime, and keep those bytes unchanged. Resource entries and archive
slices also borrow that storage. Noncopyability alone does not prevent dangling pointers.

---

## 1. Noncopyable (`~Copyable`) Ownership Boundaries

| Type | Ownership Role | Deterministic Cleanup (`deinit`) |
| :--- | :--- | :--- |
| `MappedPEFSection` (in `BlueBox`, not `PEFKit`) | Owns `mmap` region for PEF `Code` (`RX`) or `Data`/`pidata` (`RW`) | Calls `munmap(baseAddress, byteCount)` |
| `LoadedCFMFragment` | Owns instantiated sections + synthetic import `TVector` page | Releases mapped sections and unregisters fragment ID |
| `MacHandle` / `MacPtr` | Owns a 32-bit guest `Handle` master pointer slot or `Ptr` allocation | Returns slot to Master Pointer free list / calls `free` |
| `ResourceEntry` | Owns an uncompressed resource block (`DITL`, `MENU`, `snd `) | Frees backing buffer on `ReleaseResource` |
| `PEFReader` | Zero-copy `borrowing` view over raw data-fork bytes | Non-owning; prevents accidental buffer duplication |

---

## 2. Existential-Free Patterns Used in `swift-pef`

1. **Enum Dispatch Instead of `any Protocol`**:
   - Resource fork storage backends are modeled as `enum ResourceStorage { case appleDouble(...), macBinary(...), xattr(...) }` rather than `any ResourceStorageBackend`.
2. **Typed Throws (`throws(PEFError)`)**:
   - All `PEFKit` parsing, `pidata` decompression, and relocation routines throw concrete `PEFError` values rather than boxed `any Error` existentials.
3. **Sorted Integer Hash Table for CFM Imports**:
   - Rather than `[String: (inout MORAInvocationFrame) -> Void]`, `CFMLibraryRegistry` stores a sorted contiguous array of `CFMSymbolEntry { libraryHash: UInt32, symbolHash: UInt32, nameOffset: UInt32, handler: MORAShimFunction }` where `handler` is a `@convention(c)` function pointer.
   - Symbol lookup performs binary search on precomputed `PEFComputeHashWord` values with zero heap allocations at runtime.
4. **No Stack Protector Runtime Dependency**:
   - When compiling Embedded Swift targets on `ppc32` Linux, pass `-Xfrontend -disable-stack-protector` so LLVM does not emit references to `__stack_chk_guard`.
