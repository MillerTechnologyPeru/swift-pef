import BinaryParsing

/// A validated, non-owning view. Keep the source storage alive and unchanged for every access.
public struct PEFContainer: ~Copyable {
    public let bytes: UnsafeRawBufferPointer
    public let header: PEFContainerHeader
    private let namesEnd: Int

    public init(bytes: UnsafeRawBufferPointer) throws(PEFError) {
        var parser = ParserSpan(_unsafeBytes: bytes)
        let header = try PEFContainerHeader(parsing: &parser)
        let tableEnd = 40 + Int(header.sectionCount) * 28
        guard header.instSectionCount <= header.sectionCount,
              header.instSectionCount <= 32767, tableEnd <= bytes.count,
              UInt64(bytes.count) <= UInt64(UInt32.max) else {
            throw .invalidSectionLayout
        }
        var namesEnd = bytes.count
        var loaderCount = 0
        for index in 0..<Int(header.sectionCount) {
            let span = ParserSpan(_unsafeBytes: bytes)
            let section = try PEFSectionHeader.parse(container: span, index: index)
            let instantiated = section.kind == .code || section.kind == .unpackedData
                || section.kind == .patternInitializedData || section.kind == .constant
                || section.kind == .executableData
            guard instantiated == (index < Int(header.instSectionCount)) else {
                throw .invalidSectionLayout
            }
            if instantiated {
                guard section.alignment <= 31, section.unpackedLength <= section.totalLength,
                      section.kind == .patternInitializedData || section.containerLength == section.unpackedLength else {
                    throw .invalidSectionLayout
                }
                if section.kind == .code || section.kind == .constant {
                    guard section.totalLength == section.unpackedLength else { throw .invalidSectionLayout }
                }
            }
            if section.kind == .loader { loaderCount += 1 }
            if section.containerLength > 0 {
                guard UInt64(section.containerOffset) >= UInt64(tableEnd) else { throw .invalidSectionLayout }
                namesEnd = min(namesEnd, Int(section.containerOffset))
            }
        }
        guard loaderCount <= 1 else { throw .invalidSectionLayout }
        for index in 0..<Int(header.sectionCount) {
            let span = ParserSpan(_unsafeBytes: bytes)
            let section = try PEFSectionHeader.parse(container: span, index: index)
            _ = try Self.sectionName(section, bytes: bytes, tableEnd: tableEnd, namesEnd: namesEnd)
        }
        self.header = header
        self.bytes = bytes
        self.namesEnd = namesEnd
    }

    public func section(at index: Int) throws(PEFError) -> PEFSectionHeader {
        guard index >= 0, index < Int(header.sectionCount) else {
            throw .truncatedSection(index: index)
        }
        let span = ParserSpan(_unsafeBytes: bytes)
        return try PEFSectionHeader.parse(container: span, index: index)
    }

    public func contents(ofSection index: Int) throws(PEFError) -> UnsafeRawBufferPointer {
        let section = try section(at: index)
        let start = Int(section.containerOffset)
        return UnsafeRawBufferPointer(rebasing: bytes[start..<(start + Int(section.containerLength))])
    }

    private static func sectionName(
        _ section: PEFSectionHeader, bytes: UnsafeRawBufferPointer, tableEnd: Int, namesEnd: Int
    ) throws(PEFError) -> UnsafeRawBufferPointer? {
        if section.nameOffset == -1 { return nil }
        guard section.nameOffset >= 0 else { throw .invalidSectionLayout }
        let start = UInt64(tableEnd) + UInt64(section.nameOffset)
        guard start < UInt64(namesEnd) else { throw .invalidSectionLayout }
        var end = Int(start)
        while end < namesEnd, bytes[end] != 0 { end += 1 }
        guard end < namesEnd else { throw .invalidSectionLayout }
        return UnsafeRawBufferPointer(rebasing: bytes[Int(start)..<end])
    }

    public func name(ofSection index: Int) throws(PEFError) -> UnsafeRawBufferPointer? {
        try Self.sectionName(section(at: index), bytes: bytes,
                             tableEnd: 40 + Int(header.sectionCount) * 28, namesEnd: namesEnd)
    }

    private func validateEntry(sectionIndex: Int32, offset: UInt32) throws(PEFError) {
        if sectionIndex == -1 { return }
        guard sectionIndex >= 0, sectionIndex < Int32(header.instSectionCount),
              offset < (try section(at: Int(sectionIndex))).totalLength else {
            throw .malformedLoaderSection
        }
    }

    /// Parses the optional loader and validates its references against this container.
    public func loaderSection() throws(PEFError) -> PEFLoaderSection? {
        for index in Int(header.instSectionCount)..<Int(header.sectionCount) {
            if try section(at: index).kind != .loader { continue }
            let loader = try PEFLoaderSection.parse(loaderBytes: contents(ofSection: index))
            try validateEntry(sectionIndex: loader.info.mainSection, offset: loader.info.mainOffset)
            try validateEntry(sectionIndex: loader.info.initSection, offset: loader.info.initOffset)
            try validateEntry(sectionIndex: loader.info.termSection, offset: loader.info.termOffset)
            for index in 0..<Int(loader.info.relocSectionCount) {
                guard try loader.relocationHeader(at: index).sectionIndex < header.instSectionCount else {
                    throw .malformedLoaderSection
                }
            }
            for index in 0..<Int(loader.info.exportedSymbolCount) {
                let symbol = try loader.exportedSymbol(at: index)
                if symbol.sectionIndex >= 0 {
                    guard symbol.sectionIndex < Int16(header.instSectionCount),
                          symbol.symbolOffset <= (try section(at: Int(symbol.sectionIndex))).totalLength else {
                        throw .malformedLoaderSection
                    }
                }
            }
            return consume loader
        }
        return nil
    }

    /// Materializes initialized bytes and zero-fill into nonoverlapping caller-owned storage.
    /// Noninstantiated section sizes are ignored by PEF; retrieve those using contents(ofSection:).
    public func unpackSection(at index: Int, into output: UnsafeMutableRawBufferPointer) throws(PEFError) {
        guard index >= 0, index < Int(header.instSectionCount) else { throw .invalidSectionLayout }
        let section = try section(at: index)
        guard UInt64(section.totalLength) <= UInt64(output.count) else { throw .outputBufferTooSmall }
        let source = try contents(ofSection: index)
        let initialized = Int(section.unpackedLength)
        if section.kind == .patternInitializedData {
            var parser = ParserSpan(_unsafeBytes: source)
            let target = UnsafeMutableRawBufferPointer(rebasing: output[0..<initialized])
            guard try PEFPatternDecoder.unpack(&parser, into: target) == initialized else {
                throw .invalidSectionLayout
            }
        } else {
            for index in 0..<source.count { output[index] = source[index] }
        }
        for index in initialized..<Int(section.totalLength) { output[index] = 0 }
    }
}
