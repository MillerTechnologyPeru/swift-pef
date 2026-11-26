import BinaryParsing

public enum PEFError: Error, Sendable {
    /// A low-level read failed (for example, not enough bytes or an out-of-range seek).
    case parsing(ParsingError)
    case invalidMagic
    case unsupportedArchitecture(UInt32)
    case unsupportedFormatVersion(UInt32)
    case truncatedHeader
    case truncatedSection(index: Int)
    case invalidSectionKind(UInt8)
    case invalidPatternOpcode(UInt8)
    case outputBufferTooSmall
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
    public static let byteSize = 40
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

    /// Parses the 40-byte header at the start of a PEF container, validating magic,
    /// architecture, and format version.
    public init(parsing input: inout ParserSpan) throws(PEFError) {
        tag1 = try input.readUInt32()
        tag2 = try input.readUInt32()
        guard tag1 == Self.tag1Magic, tag2 == Self.tag2Magic else { throw .invalidMagic }

        architecture = try input.readUInt32()
        guard architecture == Self.archPowerPC else { throw .unsupportedArchitecture(architecture) }

        formatVersion = try input.readUInt32()
        guard formatVersion == 1 else { throw .unsupportedFormatVersion(formatVersion) }

        dateTimeStamp = try input.readUInt32()
        oldDefVersion = try input.readUInt32()
        oldImpVersion = try input.readUInt32()
        currentVersion = try input.readUInt32()
        sectionCount = try input.readUInt16()
        instSectionCount = try input.readUInt16()
        reservedA = try input.readUInt32()
    }
}
