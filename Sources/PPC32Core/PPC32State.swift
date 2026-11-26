/// Outcome of executing one instruction (or a run of them).
public enum PPC32StepResult: UInt8, Sendable {
    /// The instruction retired normally; keep executing.
    case `continue`
    /// `pc` entered the synthetic import range (`0xF0000000...`). The host should service
    /// `importSymbolIndex`, write results into the registers, and call `returnFromImportTrap()`.
    case cfmImportTrap
    /// `pc` reached `PPC32State.returnSentinel`: the guest function returned to the host.
    case returnToHost
    /// The instruction is not implemented or not valid in user mode. `pc` still addresses it.
    case illegalInstruction
}

/// User-mode (problem state) PowerPC 32-bit register file and memory interface.
///
/// Guest memory is a flat big-endian 32-bit address space. On 64-bit little-endian hosts a
/// guest address `a` maps to `memoryBase + a`; on `ppc32` hosts it is the identity mapping
/// and `memoryBase` is ignored. Guest accesses are not bounds-checked: the caller is expected
/// to back the whole window it hands in (or reserve the full 4 GB range).
public struct PPC32State: ~Copyable {
    /// Guest addresses at or above this value are synthetic CFM import trap vectors.
    public static let importTrapBase: UInt32 = 0xF000_0000
    /// Return address that makes `step()` report `.returnToHost`.
    public static let returnSentinel: UInt32 = 0xFFFF_FFFE

    public var gpr: InlineArray<32, UInt32>
    public var fpr: InlineArray<32, Double>
    public var pc: UInt32
    public var lr: UInt32
    public var ctr: UInt32
    /// Condition register; field 0 is the most significant nibble.
    public var cr: UInt32
    /// Fixed-point exception register: SO `0x80000000`, OV `0x40000000`, CA `0x20000000`.
    public var xer: UInt32
    public var fpscr: UInt32
    public var vrsave: UInt32
    /// Counts retired instructions; read by `mftb`/`mftbu`.
    public var timeBase: UInt64

    var hasReservation: Bool
    var reservedAddress: UInt32

    public let memoryBase: UnsafeMutableRawPointer

    public init(memoryBase: UnsafeMutableRawPointer) {
        gpr = InlineArray(repeating: 0)
        fpr = InlineArray(repeating: 0.0)
        pc = 0
        lr = 0
        ctr = 0
        cr = 0
        xer = 0
        fpscr = 0
        vrsave = 0
        timeBase = 0
        hasReservation = false
        reservedAddress = 0
        self.memoryBase = memoryBase
    }

    /// Index of the imported symbol the guest just branched to. Valid after `.cfmImportTrap`.
    public var importSymbolIndex: UInt32 { (pc &- Self.importTrapBase) / 4 }

    /// Resumes the guest at its link register after the host has serviced an import trap.
    public mutating func returnFromImportTrap() {
        pc = lr
    }

    // MARK: - Guest memory

    @inline(__always)
    func hostPointer(_ address: UInt32) -> UnsafeMutableRawPointer {
        #if arch(powerpc)
        return UnsafeMutableRawPointer(bitPattern: UInt(address))!
        #else
        return memoryBase + Int(address)
        #endif
    }

    @inline(__always)
    public func readUInt8(_ address: UInt32) -> UInt8 {
        hostPointer(address).load(as: UInt8.self)
    }

    @inline(__always)
    public func readUInt16(_ address: UInt32) -> UInt16 {
        UInt16(bigEndian: hostPointer(address).loadUnaligned(as: UInt16.self))
    }

    @inline(__always)
    public func readUInt32(_ address: UInt32) -> UInt32 {
        UInt32(bigEndian: hostPointer(address).loadUnaligned(as: UInt32.self))
    }

    @inline(__always)
    public func readUInt64(_ address: UInt32) -> UInt64 {
        UInt64(bigEndian: hostPointer(address).loadUnaligned(as: UInt64.self))
    }

    @inline(__always)
    public func writeUInt8(_ value: UInt8, at address: UInt32) {
        hostPointer(address).storeBytes(of: value, as: UInt8.self)
    }

    @inline(__always)
    public func writeUInt16(_ value: UInt16, at address: UInt32) {
        hostPointer(address).storeBytes(of: value.bigEndian, as: UInt16.self)
    }

    @inline(__always)
    public func writeUInt32(_ value: UInt32, at address: UInt32) {
        hostPointer(address).storeBytes(of: value.bigEndian, as: UInt32.self)
    }

    @inline(__always)
    public func writeUInt64(_ value: UInt64, at address: UInt32) {
        hostPointer(address).storeBytes(of: value.bigEndian, as: UInt64.self)
    }

    // MARK: - Condition register and XER helpers

    @inline(__always)
    func crField(_ field: Int) -> UInt32 {
        (cr >> UInt32(28 - 4 * field)) & 0xF
    }

    @inline(__always)
    mutating func setCRField(_ field: Int, _ nibble: UInt32) {
        let shift = UInt32(28 - 4 * field)
        cr = (cr & ~(0xF << shift)) | ((nibble & 0xF) << shift)
    }

    /// CR bit `n`, numbered from the most significant bit (bit 0 = LT of field 0).
    @inline(__always)
    func crBit(_ bit: Int) -> Bool {
        (cr >> UInt32(31 - bit)) & 1 != 0
    }

    @inline(__always)
    mutating func setCRBit(_ bit: Int, _ value: Bool) {
        let mask: UInt32 = 1 << UInt32(31 - bit)
        cr = value ? cr | mask : cr & ~mask
    }

    /// Sets CR0 from a signed comparison of `result` with zero, plus XER[SO].
    @inline(__always)
    mutating func setCR0(_ result: UInt32) {
        var nibble: UInt32 = Int32(bitPattern: result) < 0 ? 0x8 : (result == 0 ? 0x2 : 0x4)
        if xer & 0x8000_0000 != 0 { nibble |= 0x1 }
        setCRField(0, nibble)
    }

    @inline(__always)
    var carry: UInt32 { (xer >> 29) & 1 }

    @inline(__always)
    mutating func setCarry(_ value: Bool) {
        xer = value ? xer | 0x2000_0000 : xer & ~0x2000_0000
    }

    /// Sets XER[OV] and, when overflowing, the sticky XER[SO].
    @inline(__always)
    mutating func setOverflow(_ value: Bool) {
        xer = value ? xer | 0xC000_0000 : xer & ~0x4000_0000
    }
}
