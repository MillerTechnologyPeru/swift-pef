/// Checked memmove semantics: snapshot the source before writing, including overlapping ranges.
enum GuestBlockMove {
    static func copy(source: UInt32, destination: UInt32, count: UInt32,
                     read: (UInt32, Int) -> [UInt8]?, write: (UInt32, [UInt8]) -> Bool) throws(ToolboxMemoryFault) {
        guard count != 0 else { return }
        guard count <= UInt32(Int32.max), UInt64(source) + UInt64(count) <= UInt64(1) << 32 else {
            throw ToolboxMemoryFault(address: source, write: false)
        }
        guard UInt64(destination) + UInt64(count) <= UInt64(1) << 32 else {
            throw ToolboxMemoryFault(address: destination, write: true)
        }
        guard let bytes = read(source, Int(count)), bytes.count == Int(count) else {
            throw ToolboxMemoryFault(address: source, write: false)
        }
        guard write(destination, bytes) else {
            throw ToolboxMemoryFault(address: destination, write: true)
        }
    }
}
