import Graphite

/// Byte-preserving conversions. Snapshot the source before writing so overlapping buffers work.
enum GuestStringConversion {
    static func pascalToC(source: UInt32, destination: UInt32,
                          read: (UInt32, Int) -> [UInt8]?, write: (UInt32, [UInt8]) -> Bool) throws(ToolboxMemoryFault) {
        guard let header = read(source, 1), header.count == 1 else {
            throw ToolboxMemoryFault(address: source, write: false)
        }
        let count = Int(header[0]) + 1
        guard let bytes = read(source, count), bytes.count == count else {
            throw ToolboxMemoryFault(address: source, write: false)
        }
        let output = PascalString(lengthPrefixed: bytes).cString
        guard write(destination, output) else {
            throw ToolboxMemoryFault(address: destination, write: true)
        }
    }

    static func cToPascal(source: UInt32, destination: UInt32,
                          read: (UInt32, Int) -> [UInt8]?, write: (UInt32, [UInt8]) -> Bool) throws(ToolboxMemoryFault) {
        var bytes: [UInt8] = []
        // Classic Pascal strings truncate at 255 bytes; no unbounded host strlen is used.
        for offset in 0..<255 {
            let (address, overflow) = source.addingReportingOverflow(UInt32(offset))
            guard !overflow else { throw ToolboxMemoryFault(address: source, write: false) }
            guard let byte = read(address, 1), byte.count == 1 else {
                throw ToolboxMemoryFault(address: address, write: false)
            }
            if byte[0] == 0 { break }
            bytes.append(byte[0])
        }
        guard write(destination, PascalString(cString: bytes).lengthPrefixed) else {
            throw ToolboxMemoryFault(address: destination, write: true)
        }
    }
}
