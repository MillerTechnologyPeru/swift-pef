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
}

/// `PEFImportedSymbol` (4 bytes): class byte (weak flag `0x80`) and a 24-bit name offset.
public struct PEFImportedSymbol: Sendable {
    public static let byteSize = 4

    public let rawClass: UInt8
    public let nameOffset: UInt32

    public var symbolClass: PEFSymbolClass? { PEFSymbolClass(rawValue: rawClass & 0x0F) }
    public var isWeak: Bool { rawClass & 0x80 != 0 }
}

/// `PEFLoaderRelocationHeader` (12 bytes): one per relocated section.
public struct PEFRelocationHeader: Sendable {
    public static let byteSize = 12

    public let sectionIndex: UInt16
    /// Number of 16-bit relocation instructions.
    public let relocCount: UInt32
    /// Byte offset of the first instruction, relative to `PEFLoaderInfoHeader.relocInstrOffset`.
    public let firstRelocOffset: UInt32
}

/// `PEFExportedSymbol` (10 bytes) joined with its entry from the export key table.
public struct PEFExportedSymbol: Sendable {
    public static let byteSize = 10

    /// Full hash word from the export key table: name length in the high 16 bits.
    public let hashWord: UInt32
    public let rawClass: UInt8
    public let nameOffset: UInt32
    public let symbolOffset: UInt32
    /// Section index; `-1` is an absolute symbol and `-2` is re-exported.
    public let sectionIndex: Int16

    public var nameLength: Int { Int(hashWord >> 16) }
    public var symbolClass: PEFSymbolClass? { PEFSymbolClass(rawValue: rawClass & 0x0F) }
    public var isWeak: Bool { rawClass & 0x80 != 0 }
}

/// Zero-copy view over a PEF loader section. Borrows the container bytes it was parsed from.
public struct PEFLoaderSection {
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
        let start = Int(header.containerOffset)
        let length = Int(header.containerLength)
        guard fits(UInt32(start), UInt64(length), in: container.count) else {
            throw .truncatedSection(index: sectionIndex)
        }
        return try parse(loaderBytes: UnsafeRawBufferPointer(rebasing: container[start..<(start + length)]))
    }

    /// Parses a loader section from just its own bytes.
    public static func parse(loaderBytes bytes: UnsafeRawBufferPointer) throws(PEFError) -> PEFLoaderSection {
        guard bytes.count >= PEFLoaderInfoHeader.byteSize else { throw .truncatedHeader }

        func word(_ index: Int) -> UInt32 { bytes.loadBigEndianUInt32(at: index * 4) }
        let info = PEFLoaderInfoHeader(
            mainSection: Int32(bitPattern: word(0)),
            mainOffset: word(1),
            initSection: Int32(bitPattern: word(2)),
            initOffset: word(3),
            termSection: Int32(bitPattern: word(4)),
            termOffset: word(5),
            importedLibraryCount: word(6),
            totalImportedSymbolCount: word(7),
            relocSectionCount: word(8),
            relocInstrOffset: word(9),
            loaderStringsOffset: word(10),
            exportHashOffset: word(11),
            exportHashTablePower: word(12),
            exportedSymbolCount: word(13)
        )

        // Bounds are checked in 64 bits so hostile 32-bit counts cannot overflow `Int` on ppc32.
        let count = bytes.count
        let librariesEnd = UInt64(PEFLoaderInfoHeader.byteSize)
            + UInt64(info.importedLibraryCount) * UInt64(PEFImportedLibrary.byteSize)
        let importedSymbolsEnd = librariesEnd
            + UInt64(info.totalImportedSymbolCount) * UInt64(PEFImportedSymbol.byteSize)
        let relocHeadersEnd = importedSymbolsEnd
            + UInt64(info.relocSectionCount) * UInt64(PEFRelocationHeader.byteSize)
        guard relocHeadersEnd <= UInt64(count),
              Int(info.relocInstrOffset) <= count,
              Int(info.loaderStringsOffset) <= count,
              info.exportHashTablePower <= 30 else {
            throw .malformedLoaderSection
        }

        let slotBytes = UInt64(4) << UInt64(info.exportHashTablePower)
        let keysBytes = UInt64(info.exportedSymbolCount) * 4
        let symbolsBytes = UInt64(info.exportedSymbolCount) * UInt64(PEFExportedSymbol.byteSize)
        let hashEnd = UInt64(info.exportHashOffset) + slotBytes + keysBytes + symbolsBytes
        guard hashEnd <= UInt64(count) else { throw .malformedLoaderSection }

        return PEFLoaderSection(
            bytes: bytes,
            info: info,
            importedSymbolsOffset: Int(librariesEnd),
            relocHeadersOffset: Int(importedSymbolsEnd),
            exportKeysOffset: Int(info.exportHashOffset) + Int(slotBytes),
            exportSymbolsOffset: Int(info.exportHashOffset) + Int(slotBytes) + Int(keysBytes)
        )
    }

    // MARK: - Tables

    public func importedLibrary(at index: Int) throws(PEFError) -> PEFImportedLibrary {
        guard index >= 0, index < Int(info.importedLibraryCount) else { throw .malformedLoaderSection }
        let o = PEFLoaderInfoHeader.byteSize + index * PEFImportedLibrary.byteSize
        return PEFImportedLibrary(
            nameOffset: bytes.loadBigEndianUInt32(at: o),
            oldImpVersion: bytes.loadBigEndianUInt32(at: o + 4),
            currentVersion: bytes.loadBigEndianUInt32(at: o + 8),
            importedSymbolCount: bytes.loadBigEndianUInt32(at: o + 12),
            firstImportedSymbol: bytes.loadBigEndianUInt32(at: o + 16),
            options: bytes[o + 20]
        )
    }

    public func importedSymbol(at index: Int) throws(PEFError) -> PEFImportedSymbol {
        guard index >= 0, index < Int(info.totalImportedSymbolCount) else { throw .malformedLoaderSection }
        let word = bytes.loadBigEndianUInt32(at: importedSymbolsOffset + index * PEFImportedSymbol.byteSize)
        return PEFImportedSymbol(rawClass: UInt8(word >> 24), nameOffset: word & 0x00FF_FFFF)
    }

    public func relocationHeader(at index: Int) throws(PEFError) -> PEFRelocationHeader {
        guard index >= 0, index < Int(info.relocSectionCount) else { throw .malformedLoaderSection }
        let o = relocHeadersOffset + index * PEFRelocationHeader.byteSize
        return PEFRelocationHeader(
            sectionIndex: bytes.loadBigEndianUInt16(at: o),
            relocCount: bytes.loadBigEndianUInt32(at: o + 4),
            firstRelocOffset: bytes.loadBigEndianUInt32(at: o + 8)
        )
    }

    /// The raw big-endian 16-bit relocation opcodes for one relocated section.
    public func relocationInstructions(
        for header: PEFRelocationHeader
    ) throws(PEFError) -> UnsafeRawBufferPointer {
        let start = UInt64(info.relocInstrOffset) + UInt64(header.firstRelocOffset)
        let size = UInt64(header.relocCount) * 2
        guard start + size <= UInt64(bytes.count) else {
            throw .relocationOutOfBounds(offset: Int(truncatingIfNeeded: start))
        }
        return UnsafeRawBufferPointer(rebasing: bytes[Int(start)..<Int(start + size)])
    }

    public func exportedSymbol(at index: Int) throws(PEFError) -> PEFExportedSymbol {
        guard index >= 0, index < Int(info.exportedSymbolCount) else { throw .malformedLoaderSection }
        let o = exportSymbolsOffset + index * PEFExportedSymbol.byteSize
        let classAndName = bytes.loadBigEndianUInt32(at: o)
        return PEFExportedSymbol(
            hashWord: bytes.loadBigEndianUInt32(at: exportKeysOffset + index * 4),
            rawClass: UInt8(classAndName >> 24),
            nameOffset: classAndName & 0x00FF_FFFF,
            symbolOffset: bytes.loadBigEndianUInt32(at: o + 4),
            sectionIndex: Int16(bitPattern: bytes.loadBigEndianUInt16(at: o + 8))
        )
    }

    // MARK: - Names

    /// NUL-terminated name of an imported library or symbol.
    public func name(atOffset offset: UInt32) -> UnsafeRawBufferPointer? {
        let start = UInt64(info.loaderStringsOffset) + UInt64(offset)
        guard start < UInt64(bytes.count) else { return nil }
        var end = Int(start)
        while end < bytes.count, bytes[end] != 0 { end += 1 }
        return UnsafeRawBufferPointer(rebasing: bytes[Int(start)..<end])
    }

    /// Name of an exported symbol; its length comes from the hash word, so no NUL is required.
    public func name(of symbol: PEFExportedSymbol) -> UnsafeRawBufferPointer? {
        let start = UInt64(info.loaderStringsOffset) + UInt64(symbol.nameOffset)
        guard start + UInt64(symbol.nameLength) <= UInt64(bytes.count) else { return nil }
        return UnsafeRawBufferPointer(rebasing: bytes[Int(start)..<(Int(start) + symbol.nameLength)])
    }

    // MARK: - Export lookup

    /// Looks up an exported symbol by name using the export hash table.
    public func findExport(named name: UnsafeBufferPointer<UInt8>) -> PEFExportedSymbol? {
        let hashWord = CFMHash.computeHashWord(name)
        let power = info.exportHashTablePower
        let slot = Int((hashWord ^ (hashWord >> power)) & ((1 << power) - 1))

        let slotWord = bytes.loadBigEndianUInt32(at: Int(info.exportHashOffset) + slot * 4)
        let chainCount = Int(slotWord >> 18)
        let firstIndex = Int(slotWord & 0x3_FFFF)
        guard UInt64(firstIndex) + UInt64(chainCount) <= UInt64(info.exportedSymbolCount) else { return nil }

        for index in firstIndex..<(firstIndex + chainCount) {
            guard bytes.loadBigEndianUInt32(at: exportKeysOffset + index * 4) == hashWord,
                  let symbol = try? exportedSymbol(at: index),
                  let candidate = self.name(of: symbol),
                  candidate.count == name.count else { continue }
            var equal = true
            for i in 0..<name.count where candidate[i] != name[i] { equal = false; break }
            if equal { return symbol }
        }
        return nil
    }
}

private func fits(_ offset: UInt32, _ size: UInt64, in count: Int) -> Bool {
    UInt64(offset) + size <= UInt64(count)
}
