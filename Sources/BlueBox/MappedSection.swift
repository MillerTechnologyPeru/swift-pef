import PEFKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

enum BlueBoxError: Error {
    case mmapFailed
}

/// Anonymous host memory backing one instantiated PEF section.
struct MappedPEFSection: ~Copyable {
    let baseAddress: UnsafeMutableRawPointer
    let byteCount: Int
    let kind: PEFSectionKind

    init(byteCount: Int, kind: PEFSectionKind, executable: Bool) throws(BlueBoxError) {
        let size = max(byteCount, 4096)
        let prot: Int32 = executable ? (PROT_READ | PROT_EXEC) : (PROT_READ | PROT_WRITE)
        guard let ptr = mmap(nil, size, prot, MAP_PRIVATE | MAP_ANON, -1, 0),
              ptr != MAP_FAILED else {
            throw .mmapFailed
        }
        self.baseAddress = ptr
        self.byteCount = size
        self.kind = kind
    }

    mutating func sealExecutable() {
        _ = mprotect(baseAddress, byteCount, PROT_READ | PROT_EXEC)
    }

    deinit {
        _ = munmap(baseAddress, byteCount)
    }
}
