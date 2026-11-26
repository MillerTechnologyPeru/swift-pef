import Testing
@testable import PEFKit

@Suite struct PatternDecoderTests {
    private func unpack(_ bytes: [UInt8], capacity: Int = 64) throws -> [UInt8] {
        var out = [UInt8](repeating: 0xFF, count: capacity)
        let written = try bytes.withUnsafeBytes { src in
            try out.withUnsafeMutableBytes { dst in
                try PEFPatternDecoder.unpack(src, into: dst)
            }
        }
        return Array(out[0..<written])
    }

    @Test func zeroFill() throws {
        #expect(try unpack([0x03]) == [0, 0, 0])
    }

    @Test func blockCopy() throws {
        #expect(try unpack([0x23, 1, 2, 3]) == [1, 2, 3])
    }

    @Test func repeatedBlock() throws {
        // block of 2 bytes, arg 2 => repeated 3 times
        #expect(try unpack([0x42, 0x02, 0xAA, 0xBB]) == [0xAA, 0xBB, 0xAA, 0xBB, 0xAA, 0xBB])
    }

    @Test func interleaveRepeatBlock() throws {
        // common = [9], custom size 2, repeat 2 => 9 c c 9 c c 9
        let packed: [UInt8] = [0x61, 0x02, 0x02, 9, 1, 2, 3, 4]
        #expect(try unpack(packed) == [9, 1, 2, 9, 3, 4, 9])
    }

    @Test func interleaveRepeatZero() throws {
        let packed: [UInt8] = [0x82, 0x01, 0x02, 7, 8]
        #expect(try unpack(packed) == [0, 0, 7, 0, 0, 8, 0, 0])
    }

    @Test func variableLengthCount() throws {
        // count field 0 => arg 0x81 0x00 = 128 zeros
        #expect(try unpack([0x00, 0x81, 0x00], capacity: 256).count == 128)
    }

    @Test func invalidOpcode() {
        #expect(throws: PEFError.self) { try unpack([0xE1]) }
    }
}

@Suite struct CFMHashTests {
    @Test func lengthIsStoredInHighHalf() {
        let name: [UInt8] = Array("NewPtr".utf8)
        let hash = name.withUnsafeBufferPointer { CFMHash.computeHashWord($0) }
        #expect(hash >> 16 == 6)
    }
}

@Suite struct LoaderSectionTests {
    private func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    /// One library (`StdCLib`), one imported symbol (`printf`), one reloc section, one export (`main`).
    private func makeLoader() -> [UInt8] {
        let strings = Array("StdCLib\0printf\0main".utf8)
        let mainHash = Array("main".utf8).withUnsafeBufferPointer { CFMHash.computeHashWord($0) }

        var b: [UInt8] = []
        // Info header (56 bytes)
        for w: UInt32 in [0xFFFF_FFFF, 0, 0xFFFF_FFFF, 0, 0xFFFF_FFFF, 0,
                          1, 1, 1, 96, 100, 120, 0, 1] { b += be32(w) }
        // Library (24 bytes): name offset 0, 1 symbol starting at index 0
        b += be32(0) + be32(0) + be32(0) + be32(1) + be32(0) + [0, 0, 0, 0]
        // Imported symbol: TVector class, name offset 8
        b += be32((2 << 24) | 8)
        // Reloc header: section 1, 1 instruction at offset 0
        b += [0, 1, 0, 0] + be32(1) + be32(0)
        // Relocation instructions (2 bytes) + padding to strings at 100
        b += [0x00, 0x00, 0, 0]
        b += strings
        while b.count < 120 { b.append(0) }
        // Hash table: 1 slot holding 1 chain entry starting at index 0
        b += be32(1 << 18)
        b += be32(mainHash)
        b += be32((2 << 24) | 15) + be32(0x10) + [0, 0]
        return b
    }

    @Test func parsesTables() throws {
        let bytes = makeLoader()
        try bytes.withUnsafeBytes { raw in
            let loader = try PEFLoaderSection.parse(loaderBytes: raw)
            #expect(loader.info.importedLibraryCount == 1)

            let lib = try loader.importedLibrary(at: 0)
            #expect(Array(try #require(loader.name(atOffset: lib.nameOffset))) == Array("StdCLib".utf8))

            let sym = try loader.importedSymbol(at: 0)
            #expect(sym.symbolClass == .tVector)
            #expect(Array(try #require(loader.name(atOffset: sym.nameOffset))) == Array("printf".utf8))

            let header = try loader.relocationHeader(at: 0)
            #expect(header.sectionIndex == 1)
            #expect(try loader.relocationInstructions(for: header).count == 2)
        }
    }

    @Test func findsExportByName() throws {
        let bytes = makeLoader()
        try bytes.withUnsafeBytes { raw in
            let loader = try PEFLoaderSection.parse(loaderBytes: raw)
            let found = Array("main".utf8).withUnsafeBufferPointer { loader.findExport(named: $0) }
            #expect(found?.symbolOffset == 0x10)
            let missing = Array("nope".utf8).withUnsafeBufferPointer { loader.findExport(named: $0) }
            #expect(missing == nil)
        }
    }

    @Test func rejectsTruncatedTables() {
        var bytes = makeLoader()
        bytes.removeLast(30)
        bytes.withUnsafeBytes { raw in
            #expect(throws: PEFError.self) { try PEFLoaderSection.parse(loaderBytes: raw) }
        }
    }
}
