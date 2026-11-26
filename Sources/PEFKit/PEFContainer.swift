public enum PEFError: Error, Sendable {
    case invalidMagic
    case unsupportedArchitecture(UInt32)
    case unsupportedFormatVersion(UInt32)
    case truncatedHeader
    case truncatedSection(index: Int)
    case invalidPatternOpcode(UInt8)
    case relocationOutOfBounds(offset: Int)
    case unresolvedSymbol(hash: UInt32)
    case malformedLoaderSection
}

public enum PEFSectionKind: UInt8, Sendable {
    case code = 0
    case unpackedData = 1
    case patternInitializedData = 2
    case constant = 3
    case loader = 4
    case debug = 5
    case executableData = 6
    case exception = 7
    case traceback = 8
}

public struct PEFContainerHeader: Sendable {
    public static let tag1Magic: UInt32 = 0x4A6F7921 // 'Joy!'
    public static let tag2Magic: UInt32 = 0x70656666 // 'peff'
    public static let archPowerPC: UInt32 = 0x70777063 // 'pwpc'

    public let tag1: UInt32
    public let tag2: UInt32
    public let architecture: UInt32
    public let formatVersion: UInt32
    public let dateTimeStamp: UInt32
    public let oldDefVersion: UInt32
    public let oldImpVersion: UInt32
    public let currentVersion: UInt32
    public let sectionCount: UInt16
    public let instSectionCount: UInt16
    public let reservedA: UInt32

    public static func parse(from buffer: UnsafeRawBufferPointer) throws(PEFError) -> PEFContainerHeader {
        guard buffer.count >= 40 else { throw .truncatedHeader }
        let tag1 = buffer.loadBigEndianUInt32(at: 0)
        let tag2 = buffer.loadBigEndianUInt32(at: 4)
        guard tag1 == tag1Magic, tag2 == tag2Magic else { throw .invalidMagic }

        let arch = buffer.loadBigEndianUInt32(at: 8)
        guard arch == archPowerPC else { throw .unsupportedArchitecture(arch) }

        let version = buffer.loadBigEndianUInt32(at: 12)
        guard version == 1 else { throw .unsupportedFormatVersion(version) }

        return PEFContainerHeader(
            tag1: tag1,
            tag2: tag2,
            architecture: arch,
            formatVersion: version,
            dateTimeStamp: buffer.loadBigEndianUInt32(at: 16),
            oldDefVersion: buffer.loadBigEndianUInt32(at: 20),
            oldImpVersion: buffer.loadBigEndianUInt32(at: 24),
            currentVersion: buffer.loadBigEndianUInt32(at: 28),
            sectionCount: buffer.loadBigEndianUInt16(at: 32),
            instSectionCount: buffer.loadBigEndianUInt16(at: 34),
            reservedA: buffer.loadBigEndianUInt32(at: 36)
        )
    }
}

extension UnsafeRawBufferPointer {
    @inlinable
    func loadBigEndianUInt16(at offset: Int) -> UInt16 {
        let b0 = UInt16(self[offset])
        let b1 = UInt16(self[offset + 1])
        return (b0 << 8) | b1
    }

    @inlinable
    func loadBigEndianUInt32(at offset: Int) -> UInt32 {
        let b0 = UInt32(self[offset])
        let b1 = UInt32(self[offset + 1])
        let b2 = UInt32(self[offset + 2])
        let b3 = UInt32(self[offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}
