#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Sparse guest memory for the 64-bit emulated backend. Pointers remain valid until destruction.
struct GuestAddressSpace: ~Copyable {
    static let byteCount: UInt64 = 1 << 32
    let basePointer: UnsafeMutableRawPointer
    let pageSize: Int

    init() throws(BlueBoxError) {
        pageSize = Int(sysconf(Int32(_SC_PAGESIZE)))
        guard pageSize > 0, UInt64(Int.max) >= Self.byteCount else {
            throw .addressSpaceReservationFailed
        }
        guard let pointer = mmap(nil, Int(Self.byteCount), PROT_NONE,
                                 MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0),
              pointer != MAP_FAILED else {
            throw .addressSpaceReservationFailed
        }
        basePointer = pointer
    }

    /// Commits whole host pages while leaving synthetic import addresses inaccessible.
    func commit(at address: UInt32, byteCount: Int) throws(BlueBoxError) {
        guard byteCount > 0, address < 0xF000_0000,
              UInt64(byteCount) <= UInt64(0xF000_0000) - UInt64(address) else {
            throw .invalidGuestRange
        }
        let start = Int(address) / pageSize * pageSize
        let end = ((Int(address) + byteCount + pageSize - 1) / pageSize) * pageSize
        guard mprotect(basePointer + start, end - start, PROT_READ | PROT_WRITE) == 0 else {
            throw .guestMemoryCommitFailed
        }
    }

    func hostPointer(for address: UInt32) -> UnsafeMutableRawPointer {
        basePointer + Int(address)
    }

    func readBigEndian<T: FixedWidthInteger>(_ type: T.Type, at address: UInt32) -> T {
        T(bigEndian: hostPointer(for: address).loadUnaligned(as: T.self))
    }

    func writeBigEndian<T: FixedWidthInteger>(_ value: T, at address: UInt32) {
        hostPointer(for: address).storeBytes(of: value.bigEndian, as: T.self)
    }

    deinit {
        _ = munmap(basePointer, Int(Self.byteCount))
    }
}
