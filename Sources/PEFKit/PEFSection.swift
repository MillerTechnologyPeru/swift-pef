public struct PEFSectionHeader: Sendable {
    public static let byteSize = 28

    public let nameOffset: Int32
    public let defaultAddress: UInt32
    public let totalLength: UInt32
    public let unpackedLength: UInt32
    public let containerLength: UInt32
    public let containerOffset: UInt32
    public let kind: PEFSectionKind
    public let shareKind: UInt8
    public let alignment: UInt8

    /// Parses the section header at `index` in the table that follows the 40-byte container header.
    public static func parse(
        from buffer: UnsafeRawBufferPointer,
        index: Int
    ) throws(PEFError) -> PEFSectionHeader {
        let offset = 40 + index * byteSize
        guard offset + byteSize <= buffer.count else { throw .truncatedSection(index: index) }

        let rawKind = buffer[offset + 24]
        guard let kind = PEFSectionKind(rawValue: rawKind) else {
            throw .truncatedSection(index: index)
        }

        let header = PEFSectionHeader(
            nameOffset: Int32(bitPattern: buffer.loadBigEndianUInt32(at: offset)),
            defaultAddress: buffer.loadBigEndianUInt32(at: offset + 4),
            totalLength: buffer.loadBigEndianUInt32(at: offset + 8),
            unpackedLength: buffer.loadBigEndianUInt32(at: offset + 12),
            containerLength: buffer.loadBigEndianUInt32(at: offset + 16),
            containerOffset: buffer.loadBigEndianUInt32(at: offset + 20),
            kind: kind,
            shareKind: buffer[offset + 25],
            alignment: buffer[offset + 26]
        )

        // The section's bytes in the container must lie within the file.
        let end = Int(header.containerOffset) + Int(header.containerLength)
        guard end <= buffer.count else { throw .truncatedSection(index: index) }
        return header
    }
}
