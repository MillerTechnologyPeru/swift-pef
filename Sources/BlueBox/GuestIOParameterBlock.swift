import Graphite

/// Classic IOParam is packed to two-byte alignment, including its long at offset 46.
struct GuestIOParameterBlock {
    let address: UInt32
    let reference: Int16
    let buffer: UInt32
    let requestedCount: Int32
    let positionMode: UInt16
    let positionOffset: Int32

    init(at address: UInt32, read: (UInt32, Int) -> [UInt8]?) throws {
        guard UInt64(address) + 50 <= 1 << 32 else { throw ToolboxMemoryFault(address: address, write: false) }
        let bytes = try GuestAppleEventDescriptors.read(address, count: 50, using: read)
        func short(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]) }
        self.address = address
        reference = Int16(bitPattern: short(24))
        buffer = GuestAppleEventDescriptors.word(bytes, 32)
        requestedCount = Int32(bitPattern: GuestAppleEventDescriptors.word(bytes, 36))
        positionMode = short(44)
        positionOffset = Int32(bitPattern: GuestAppleEventDescriptors.word(bytes, 46))
    }

    func finish(error: MacError? = nil, actualCount: Int = 0, position: UInt32? = nil,
                write: (UInt32, [UInt8]) -> Bool) throws {
        typealias Coding = GuestAppleEventDescriptors
        try Coding.write(address + 40, bytes: Coding.word(UInt32(actualCount)), using: write)
        if let position { try Coding.write(address + 46, bytes: Coding.word(position), using: write) }
        let result = UInt16(truncatingIfNeeded: error?.code ?? 0)
        try Coding.write(address + 16, bytes: [UInt8(result >> 8), UInt8(truncatingIfNeeded: result)], using: write)
    }
}
