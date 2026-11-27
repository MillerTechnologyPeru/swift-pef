import BinaryParsing

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

    /// Parses one 28-byte section header.
    public init(parsing input: inout ParserSpan) throws(PEFError) {
        nameOffset = try input.readInt32()
        defaultAddress = try input.readUInt32()
        totalLength = try input.readUInt32()
        unpackedLength = try input.readUInt32()
        containerLength = try input.readUInt32()
        containerOffset = try input.readUInt32()

        let rawKind = try input.readUInt8()
        guard let kind = PEFSectionKind(rawValue: rawKind) else { throw .invalidSectionKind(rawKind) }
        self.kind = kind
        shareKind = try input.readUInt8()
        alignment = try input.readUInt8()
        _ = try input.readUInt8() // reservedA
    }

    /// Parses the section header at `index` in the table that follows the 40-byte container
    /// header, and checks that the section's bytes lie within the container.
    ///
    /// - Parameter container: a span over the whole container, offsets measured from the start.
    public static func parse(
        container: borrowing ParserSpan,
        index: Int
    ) throws(PEFError) -> PEFSectionHeader {
        guard index >= 0, index <= (Int.max - PEFContainerHeader.byteSize) / byteSize else {
            throw .truncatedSection(index: index)
        }
        var table: ParserSpan
        do throws(ParsingError) {
            let offset = PEFContainerHeader.byteSize + index * byteSize
            table = try container.seeking(toAbsoluteOffset: offset)
        } catch {
            throw .truncatedSection(index: index)
        }

        let header = try PEFSectionHeader(parsing: &table)
        let end = UInt64(header.containerOffset) + UInt64(header.containerLength)
        guard end <= UInt64(container.endPosition) else { throw .truncatedSection(index: index) }
        return header
    }
}
