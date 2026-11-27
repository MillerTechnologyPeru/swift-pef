import BinaryParsing

/// Symbol class stored in the low nibble of an imported/exported symbol's class byte.
public enum PEFSymbolClass: UInt8, Sendable {
    case code = 0
    case data = 1
    case tVector = 2
    case toc = 3
    case glue = 4
}

/// The 56-byte header at the start of the loader section (`PEFLoaderInfoHeader`).
public struct PEFLoaderInfoHeader: Sendable {
    public static let byteSize = 56

    public let mainSection: Int32
    public let mainOffset: UInt32
    public let initSection: Int32
    public let initOffset: UInt32
    public let termSection: Int32
    public let termOffset: UInt32
    public let importedLibraryCount: UInt32
    public let totalImportedSymbolCount: UInt32
    public let relocSectionCount: UInt32
    public let relocInstrOffset: UInt32
    public let loaderStringsOffset: UInt32
    public let exportHashOffset: UInt32
    public let exportHashTablePower: UInt32
    public let exportedSymbolCount: UInt32

    public init(parsing input: inout ParserSpan) throws(PEFError) {
        mainSection = try input.readInt32()
        mainOffset = try input.readUInt32()
        initSection = try input.readInt32()
        initOffset = try input.readUInt32()
        termSection = try input.readInt32()
        termOffset = try input.readUInt32()
        importedLibraryCount = try input.readUInt32()
        totalImportedSymbolCount = try input.readUInt32()
        relocSectionCount = try input.readUInt32()
        relocInstrOffset = try input.readUInt32()
        loaderStringsOffset = try input.readUInt32()
        exportHashOffset = try input.readUInt32()
        exportHashTablePower = try input.readUInt32()
        exportedSymbolCount = try input.readUInt32()
    }
}

/// `PEFImportedLibrary` (24 bytes).
public struct PEFImportedLibrary: Sendable {
    public static let byteSize = 24
    public static let optionWeak: UInt8 = 0x40
    public static let optionInitBefore: UInt8 = 0x80

    public let nameOffset: UInt32
    public let oldImpVersion: UInt32
    public let currentVersion: UInt32
    public let importedSymbolCount: UInt32
    public let firstImportedSymbol: UInt32
    public let options: UInt8

    public var isWeak: Bool { options & Self.optionWeak != 0 }
    public var initializesBeforeClient: Bool { options & Self.optionInitBefore != 0 }

    public init(parsing input: inout ParserSpan) throws(PEFError) {
        nameOffset = try input.readUInt32()
        oldImpVersion = try input.readUInt32()
        currentVersion = try input.readUInt32()
        importedSymbolCount = try input.readUInt32()
        firstImportedSymbol = try input.readUInt32()
        options = try input.readUInt8()
        _ = try input.readUInt8() // reservedA
        _ = try input.readUInt16() // reservedB
    }
}

/// `PEFImportedSymbol` (4 bytes): class byte (weak flag `0x80`) and a 24-bit name offset.
public struct PEFImportedSymbol: Sendable {
    public static let byteSize = 4

    public let rawClass: UInt8
    public let nameOffset: UInt32

    public var symbolClass: PEFSymbolClass? { PEFSymbolClass(rawValue: rawClass & 0x0F) }
    public var isWeak: Bool { rawClass & 0x80 != 0 }

    public init(parsing input: inout ParserSpan) throws(PEFError) {
        let word = try input.readUInt32()
        rawClass = UInt8(word >> 24)
        nameOffset = word & 0x00FF_FFFF
    }
}

/// `PEFLoaderRelocationHeader` (12 bytes): one per relocated section.
public struct PEFRelocationHeader: Sendable {
    public static let byteSize = 12

    public let sectionIndex: UInt16
    /// Number of 16-bit relocation instructions.
    public let relocCount: UInt32
    /// Byte offset of the first instruction, relative to `PEFLoaderInfoHeader.relocInstrOffset`.
    public let firstRelocOffset: UInt32

    public init(parsing input: inout ParserSpan) throws(PEFError) {
        sectionIndex = try input.readUInt16()
        _ = try input.readUInt16() // reservedA
        relocCount = try input.readUInt32()
        firstRelocOffset = try input.readUInt32()
    }
}

/// `PEFExportedSymbol` (10 bytes) joined with its entry from the export key table.
public struct PEFExportedSymbol: Sendable {
    public static let byteSize = 10

    /// Full hash word from the export key table: name length in the high 16 bits.
    public let hashWord: UInt32
    public let rawClass: UInt8
    public let nameOffset: UInt32
    public let symbolOffset: UInt32
    /// Section index; `-2` is an absolute symbol and `-3` is a re-exported import.
    public let sectionIndex: Int16

    public var nameLength: Int { Int(hashWord >> 16) }
    public var symbolClass: PEFSymbolClass? { PEFSymbolClass(rawValue: rawClass & 0x0F) }
    public var isWeak: Bool { rawClass & 0x80 != 0 }

    /// Parses the 10-byte symbol record; `hashWord` comes from the separate export key table.
    init(parsing input: inout ParserSpan, hashWord: UInt32) throws(PEFError) {
        let classAndName = try input.readUInt32()
        self.hashWord = hashWord
        rawClass = UInt8(classAndName >> 24)
        nameOffset = classAndName & 0x00FF_FFFF
        symbolOffset = try input.readUInt32()
        sectionIndex = try input.readInt16()
    }
}

/// Zero-copy view over a PEF loader section. Borrows the container bytes it was parsed from.
///
/// A `ParserSpan` is non-escapable and cannot be stored, so the view keeps the raw bytes and
/// opens a short-lived span for each table access. It is noncopyable so a single view owns
/// the borrowed bytes; pass it `borrowing` rather than duplicating it.
public struct PEFLoaderSection: ~Copyable {
    /// The loader section's bytes; every offset in the loader tables is relative to this.
    public let bytes: UnsafeRawBufferPointer
    public let info: PEFLoaderInfoHeader

    private let importedSymbolsOffset: Int
    private let relocHeadersOffset: Int
    private let exportKeysOffset: Int
    private let exportSymbolsOffset: Int

    /// Parses the loader section described by `header` out of the whole `container` file.
    public static func parse(
        container: UnsafeRawBufferPointer,
        header: PEFSectionHeader,
        sectionIndex: Int = -1
    ) throws(PEFError) -> PEFLoaderSection {
        guard header.kind == .loader else { throw .malformedLoaderSection }
        let start = UInt64(header.containerOffset)
        let length = UInt64(header.containerLength)
        guard start + length <= UInt64(container.count) else {
            throw .truncatedSection(index: sectionIndex)
        }
        let range = Int(start)..<(Int(start) + Int(length))
        return try parse(loaderBytes: UnsafeRawBufferPointer(rebasing: container[range]))
    }

    /// Parses a loader section from just its own bytes.
    public static func parse(loaderBytes bytes: UnsafeRawBufferPointer) throws(PEFError) -> PEFLoaderSection {
        guard bytes.count >= PEFLoaderInfoHeader.byteSize else { throw .truncatedHeader }

        var span = ParserSpan(_unsafeBytes: bytes)
        let info = try PEFLoaderInfoHeader(parsing: &span)

        // Bounds are checked in 64 bits so hostile 32-bit counts cannot overflow `Int` on ppc32.
        let count = UInt64(bytes.count)
        let librariesEnd = UInt64(PEFLoaderInfoHeader.byteSize)
            + UInt64(info.importedLibraryCount) * UInt64(PEFImportedLibrary.byteSize)
        let importedSymbolsEnd = librariesEnd
            + UInt64(info.totalImportedSymbolCount) * UInt64(PEFImportedSymbol.byteSize)
        let relocHeadersEnd = importedSymbolsEnd
            + UInt64(info.relocSectionCount) * UInt64(PEFRelocationHeader.byteSize)
        guard relocHeadersEnd <= count,
              UInt64(info.relocInstrOffset) >= relocHeadersEnd,
              info.relocInstrOffset <= info.loaderStringsOffset,
              info.loaderStringsOffset <= info.exportHashOffset,
              UInt64(info.exportHashOffset) <= count,
              info.exportHashTablePower <= 30 else {
            throw .malformedLoaderSection
        }

        let slotBytes = UInt64(4) << UInt64(info.exportHashTablePower)
        let keysBytes = UInt64(info.exportedSymbolCount) * 4
        let symbolsBytes = UInt64(info.exportedSymbolCount) * UInt64(PEFExportedSymbol.byteSize)
        let hashEnd = UInt64(info.exportHashOffset) + slotBytes + keysBytes + symbolsBytes
        guard hashEnd <= count else { throw .malformedLoaderSection }

        let view = PEFLoaderSection(
            bytes: bytes,
            info: info,
            importedSymbolsOffset: Int(librariesEnd),
            relocHeadersOffset: Int(importedSymbolsEnd),
            exportKeysOffset: Int(info.exportHashOffset) + Int(slotBytes),
            exportSymbolsOffset: Int(info.exportHashOffset) + Int(slotBytes) + Int(keysBytes)
        )
        for index in 0..<Int(info.importedLibraryCount) {
            let library = try view.importedLibrary(at: index)
            guard UInt64(library.firstImportedSymbol) + UInt64(library.importedSymbolCount)
                    <= UInt64(info.totalImportedSymbolCount),
                  view.name(atOffset: library.nameOffset) != nil else {
                throw .malformedLoaderSection
            }
        }
        for index in 0..<Int(info.totalImportedSymbolCount) {
            let symbol = try view.importedSymbol(at: index)
            guard symbol.symbolClass != nil, view.name(atOffset: symbol.nameOffset) != nil else {
                throw .malformedLoaderSection
            }
        }
        for index in 0..<Int(info.relocSectionCount) {
            _ = try view.relocationInstructions(for: view.relocationHeader(at: index))
        }
        for index in 0..<Int(info.exportedSymbolCount) {
            let symbol = try view.exportedSymbol(at: index)
            guard symbol.symbolClass != nil, view.name(of: symbol) != nil,
                  symbol.sectionIndex >= 0 || symbol.sectionIndex == -2 || symbol.sectionIndex == -3 else {
                throw .malformedLoaderSection
            }
            if symbol.sectionIndex == -3, symbol.symbolOffset >= info.totalImportedSymbolCount {
                throw .malformedLoaderSection
            }
        }
        for slot in 0..<Int(slotBytes / 4) {
            let word = try view.withSpan(at: Int(info.exportHashOffset) + slot * 4) {
                (span) throws(PEFError) in try span.readUInt32()
            }
            guard UInt64(word & 0x3FFFF) + UInt64(word >> 18) <= UInt64(info.exportedSymbolCount) else {
                throw .malformedLoaderSection
            }
        }
        return view
    }

    /// Runs `body` with a parser span positioned at `offset` within the loader bytes.
    private func withSpan<T>(
        at offset: Int,
        _ body: (inout ParserSpan) throws(PEFError) -> T
    ) throws(PEFError) -> T {
        var span = ParserSpan(_unsafeBytes: bytes)
        try span.seek(absoluteOffset: UInt64(offset))
        return try body(&span)
    }

    // MARK: - Tables

    public func importedLibrary(at index: Int) throws(PEFError) -> PEFImportedLibrary {
        guard index >= 0, index < Int(info.importedLibraryCount) else { throw .malformedLoaderSection }
        let offset = PEFLoaderInfoHeader.byteSize + index * PEFImportedLibrary.byteSize
        return try withSpan(at: offset) { (span) throws(PEFError) in try PEFImportedLibrary(parsing: &span) }
    }

    public func importedSymbol(at index: Int) throws(PEFError) -> PEFImportedSymbol {
        guard index >= 0, index < Int(info.totalImportedSymbolCount) else { throw .malformedLoaderSection }
        let offset = importedSymbolsOffset + index * PEFImportedSymbol.byteSize
        return try withSpan(at: offset) { (span) throws(PEFError) in try PEFImportedSymbol(parsing: &span) }
    }

    public func relocationHeader(at index: Int) throws(PEFError) -> PEFRelocationHeader {
        guard index >= 0, index < Int(info.relocSectionCount) else { throw .malformedLoaderSection }
        let offset = relocHeadersOffset + index * PEFRelocationHeader.byteSize
        return try withSpan(at: offset) { (span) throws(PEFError) in try PEFRelocationHeader(parsing: &span) }
    }

    /// The raw big-endian 16-bit relocation opcodes for one relocated section.
    public func relocationInstructions(
        for header: PEFRelocationHeader
    ) throws(PEFError) -> UnsafeRawBufferPointer {
        let start = UInt64(info.relocInstrOffset) + UInt64(header.firstRelocOffset)
        let size = UInt64(header.relocCount) * 2
        guard header.firstRelocOffset % 2 == 0, start + size <= UInt64(info.loaderStringsOffset) else {
            throw .relocationOutOfBounds(offset: Int(truncatingIfNeeded: start))
        }
        return UnsafeRawBufferPointer(rebasing: bytes[Int(start)..<Int(start + size)])
    }

    public func exportedSymbol(at index: Int) throws(PEFError) -> PEFExportedSymbol {
        guard index >= 0, index < Int(info.exportedSymbolCount) else { throw .malformedLoaderSection }
        let hashWord = try withSpan(at: exportKeysOffset + index * 4) { (span) throws(PEFError) in
            try span.readUInt32()
        }
        let offset = exportSymbolsOffset + index * PEFExportedSymbol.byteSize
        return try withSpan(at: offset) { (span) throws(PEFError) in
            try PEFExportedSymbol(parsing: &span, hashWord: hashWord)
        }
    }

    // MARK: - Names

    /// NUL-terminated name of an imported library or symbol.
    public func name(atOffset offset: UInt32) -> UnsafeRawBufferPointer? {
        let start = UInt64(info.loaderStringsOffset) + UInt64(offset)
        let limit = Int(info.exportHashOffset)
        guard start < UInt64(limit) else { return nil }
        var end = Int(start)
        while end < limit, bytes[end] != 0 { end += 1 }
        guard end < limit else { return nil }
        return UnsafeRawBufferPointer(rebasing: bytes[Int(start)..<end])
    }

    /// Name of an exported symbol; its length comes from the hash word, so no NUL is required.
    public func name(of symbol: PEFExportedSymbol) -> UnsafeRawBufferPointer? {
        let start = UInt64(info.loaderStringsOffset) + UInt64(symbol.nameOffset)
        guard start + UInt64(symbol.nameLength) <= UInt64(info.exportHashOffset) else { return nil }
        return UnsafeRawBufferPointer(rebasing: bytes[Int(start)..<(Int(start) + symbol.nameLength)])
    }

    /// Resolves the PEF export pseudo-sections and regular section-relative addresses.
    public func address(
        of symbol: PEFExportedSymbol,
        sectionAddresses: UnsafeBufferPointer<UInt32>,
        importedAddresses: UnsafeBufferPointer<UInt32>
    ) throws(PEFError) -> UInt32 {
        switch symbol.sectionIndex {
        case -2:
            return symbol.symbolOffset
        case -3:
            guard UInt64(symbol.symbolOffset) < UInt64(importedAddresses.count) else {
                throw .malformedLoaderSection
            }
            return importedAddresses[Int(symbol.symbolOffset)]
        case 0...Int16.max:
            let index = Int(symbol.sectionIndex)
            guard index < sectionAddresses.count else { throw .malformedLoaderSection }
            return sectionAddresses[index] &+ symbol.symbolOffset
        default:
            throw .malformedLoaderSection
        }
    }

    // MARK: - Export lookup

    /// Looks up an exported symbol by name using the export hash table.
    public func findExport(named name: UnsafeBufferPointer<UInt8>) -> PEFExportedSymbol? {
        let hashWord = CFMHash.computeHashWord(name)
        let power = info.exportHashTablePower
        let slot = Int((hashWord ^ (hashWord >> power)) & ((1 << power) - 1))

        guard let slotWord = try? withSpan(at: Int(info.exportHashOffset) + slot * 4, { (span) throws(PEFError) in
            try span.readUInt32()
        }) else { return nil }
        let chainCount = Int(slotWord >> 18)
        let firstIndex = Int(slotWord & 0x3_FFFF)
        guard UInt64(firstIndex) + UInt64(chainCount) <= UInt64(info.exportedSymbolCount) else { return nil }

        for index in firstIndex..<(firstIndex + chainCount) {
            guard let symbol = try? exportedSymbol(at: index),
                  symbol.hashWord == hashWord,
                  let candidate = self.name(of: symbol),
                  candidate.count == name.count else { continue }
            var equal = true
            for i in 0..<name.count where candidate[i] != name[i] { equal = false; break }
            if equal { return symbol }
        }
        return nil
    }
}
