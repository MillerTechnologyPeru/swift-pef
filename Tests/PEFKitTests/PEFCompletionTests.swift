import BinaryParsing
import Testing
@testable import PEFKit
#if canImport(Darwin)
import Darwin
#endif

private func be16(_ value: UInt16) -> [UInt8] {
    [UInt8(value >> 8), UInt8(truncatingIfNeeded: value)]
}

private func be32(_ value: UInt32) -> [UInt8] {
    [UInt8(value >> 24), UInt8(truncatingIfNeeded: value >> 16),
     UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
}

@Suite struct RelocatorTests {
    private func relocate(
        _ words: [UInt16], size: Int = 64,
        sections: [UInt32] = [0x1000, 0x2000, 0x3000],
        imports: [UInt32] = [0x4000, 0x5000], limit: Int = 1000
    ) throws -> [UInt32] {
        let instructions = words.flatMap(be16)
        var output = [UInt8](repeating: 0, count: size)
        try instructions.withUnsafeBytes { instructions in
            try output.withUnsafeMutableBytes { output in
                try sections.withUnsafeBufferPointer { sections in
                    try imports.withUnsafeBufferPointer { imports in
                        try PEFRelocator.apply(instructions: instructions, to: output,
                                               sectionAdjustments: sections, importedAddresses: imports,
                                               operationLimit: limit)
                    }
                }
            }
        }
        return output.withUnsafeBytes { bytes in
            (0..<(size / 4)).map { UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
        }
    }

    @Test func valueGroupsAndSkip() throws {
        let result = try relocate([0x0041, 0x4000, 0x4200, 0x4400, 0x4600, 0x4800])
        #expect(Array(result.prefix(12)) == [0, 0x2000, 0x1000, 0x2000,
                                           0x1000, 0x2000, 0, 0x1000, 0x2000, 0x2000, 0, 0])
    }

    @Test func indicesAndImportCursor() throws {
        let result = try relocate([0x6202, 0x6400, 0x4000, 0x4200, 0x6602, 0x6000, 0x4A00])
        #expect(Array(result.prefix(5)) == [0x3000, 0x1000, 0x3000, 0x4000, 0x5000])
    }

    @Test func longFormsAndByteOffsets() throws {
        let result = try relocate([0xA000, 4, 0xA400, 1, 0xB440, 2, 0x4000,
                                   0xB480, 0, 0x4200, 0xB400, 1])
        #expect(Array(result.prefix(5)) == [0, 0x5000, 0x3000, 0x1000, 0x2000])
        let incremented = try relocate([0x8003, 0x4000])
        #expect(incremented[1] == 0x1000)
    }

    @Test func repeats() throws {
        let small = try relocate([0x4000, 0x9001])
        #expect(Array(small.prefix(4)) == [0x1000, 0x1000, 0x1000, 0])
        let large = try relocate([0x4000, 0xB000, 2])
        #expect(Array(large.prefix(4)) == [0x1000, 0x1000, 0x1000, 0])
    }

    @Test func rejectsBadPrograms() {
        for words: [UInt16] in [
            [0xFFFF], [0xA000], [0xA400], [0xB000], [0xB400],
            [0x9000], [0x4000, 0x9000, 0x9100],
            [0xA000, 0, 0x9000], [0xB4C0, 0], [0x6002], [0x6603]
        ] {
            #expect(throws: PEFError.self) { try relocate(words) }
        }
        #expect(throws: PEFError.self) { try relocate([0x4000], size: 0) }
        #expect(throws: PEFError.self) { try relocate([0x8000], size: 0) }
        #expect(throws: PEFError.self) { try relocate([0x4000, 0x90FF], limit: 4) }
    }
}

@Suite struct ResourceReaderTests {
    // One named 'TEST' resource, signed ID -7, attributes 0x20, payload [1,2,3].
    private func fork() -> [UInt8] {
        var bytes = be32(16) + be32(23) + be32(7) + be32(56)
        bytes += be32(3) + [1, 2, 3]
        var map = [UInt8](repeating: 0, count: 22)
        map += be16(0) + be16(28) + be16(50)
        map += be16(0) + be32(0x54455354) + be16(0) + be16(10)
        map += be16(0xFFF9) + be16(0) + be32(0x20000000) + be32(0)
        map += [5] + Array("hello".utf8)
        return bytes + map
    }

    @Test func readsResourceAndName() throws {
        try fork().withUnsafeBytes { bytes in
            let resource = try ResourceFork(bytes: bytes)
            let count = resource.typeCount
            #expect(count == 1)
            let found = try resource.find(type: 0x54455354, id: -7)
            let entry = try #require(found)
            #expect(entry.attributes == 0x20)
            #expect(Array(entry.data) == [1, 2, 3])
            #expect(entry.name.map(Array.init) == Array("hello".utf8))
            let missing = try resource.find(type: 0x54455354, id: 0)
            #expect(missing == nil)
        }
    }

    @Test func everyTruncationFails() {
        let bytes = fork()
        for length in 0..<bytes.count {
            Array(bytes.prefix(length)).withUnsafeBytes { bytes in
                #expect(throws: PEFError.self) { _ = try ResourceFork(bytes: bytes) }
            }
        }
    }

    @Test func rejectsBadResourceOffsets() {
        for offset in [23 + 24, 23 + 26, 23 + 36, 23 + 43] {
            var bytes = fork()
            bytes[offset] = 0xFF
            bytes.withUnsafeBytes { bytes in
                #expect(throws: PEFError.self) { _ = try ResourceFork(bytes: bytes) }
            }
        }
    }

    @Test func appleDouble() throws {
        let resource = fork()
        var archive = be32(0x00051607) + be32(0x00020000)
        archive += [UInt8](repeating: 0, count: 16)
        archive += be16(1) + be32(2) + be32(38) + be32(UInt32(resource.count)) + resource
        try archive.withUnsafeBytes { bytes in
            let found = try AppleDoubleReader.resourceFork(in: bytes)
            let data = try #require(found)
            #expect(Array(data) == resource)
        }
        for count in 0..<archive.count {
            Array(archive.prefix(count)).withUnsafeBytes { bytes in
                #expect(throws: PEFError.self) { _ = try AppleDoubleReader.resourceFork(in: bytes) }
            }
        }
    }

    @Test func macBinaryVersionsAndCRC() throws {
        for version: UInt8 in [0, 129, 130] {
            var bytes = [UInt8](repeating: 0, count: 128)
            bytes[1] = 1
            bytes[2] = 65
            bytes.replaceSubrange(83..<87, with: be32(3))
            bytes.replaceSubrange(87..<91, with: be32(2))
            if version != 0 {
                bytes[122] = version
                bytes[123] = 129
                bytes[121] = 1 // secondary header rounds up to 128 bytes
                if version == 130 { bytes.replaceSubrange(102..<106, with: Array("mBIN".utf8)) }
                var crc: UInt16 = 0
                for byte in bytes.prefix(124) {
                    crc ^= UInt16(byte) << 8
                    for _ in 0..<8 { crc = crc & 0x8000 == 0 ? crc &<< 1 : (crc &<< 1) ^ 0x1021 }
                }
                bytes.replaceSubrange(124..<126, with: be16(crc))
                bytes += [UInt8](repeating: 0, count: 128)
            }
            bytes += [1, 2, 3] + [UInt8](repeating: 0, count: 125) + [4, 5]
            try bytes.withUnsafeBytes { bytes in
                let forks = try MacBinaryReader.parse(bytes)
                #expect(Array(forks.dataFork) == [1, 2, 3])
                #expect(Array(forks.resourceFork) == [4, 5])
            }
            var broken = bytes
            broken.removeLast()
            broken.withUnsafeBytes { bytes in
                #expect(throws: PEFError.self) { _ = try MacBinaryReader.parse(bytes) }
            }
            if version != 0 {
                bytes[10] ^= 1
                bytes.withUnsafeBytes { bytes in
                    #expect(throws: PEFError.self) { _ = try MacBinaryReader.parse(bytes) }
                }
            }
        }
    }
}

@Suite struct PEFIntegrationTests {
    private func loader() -> [UInt8] {
        var bytes: [UInt8] = []
        for value: UInt32 in [0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0,
                              1, 1, 1, 96, 98, 112, 0, 1] {
            bytes += be32(value)
        }
        bytes += be32(0) + be32(0) + be32(0) + be32(1) + be32(0) + [0, 0, 0, 0]
        bytes += be32(0x02000004)
        bytes += be16(0) + be16(0) + be32(1) + be32(0)
        bytes += be16(0x6000)
        bytes += Array("Lib\0foo\0entry".utf8)
        while bytes.count < 112 { bytes.append(0) }
        // 'entry' has a fixed hash independent of the production implementation.
        bytes += be32(1 << 18) + be32(0x0005046D)
        bytes += be32(0x01000008) + be32(0) + be16(0)
        return bytes
    }

    private func container(pattern: Bool = false) -> [UInt8] {
        let loader = loader()
        let data: [UInt8] = pattern ? [0x04] : [0, 0, 0, 0]
        var bytes: [UInt8] = []
        for value: UInt32 in [0x4A6F7921, 0x70656666, 0x70777063, 1, 0, 0, 0, 0] {
            bytes += be32(value)
        }
        bytes += be16(2) + be16(1) + be32(0)
        bytes += be32(0) + be32(0) + be32(8) + be32(4) + be32(UInt32(data.count)) + be32(104)
        bytes += [pattern ? 2 : 1, 1, 2, 0]
        // Noninstantiated loader total/unpacked fields are ignored.
        bytes += be32(0xFFFFFFFF) + be32(0) + be32(0) + be32(0)
        bytes += be32(UInt32(loader.count)) + be32(UInt32(104 + data.count)) + [4, 1, 0, 0]
        bytes += Array("data\0".utf8)
        while bytes.count < 104 { bytes.append(0) }
        return bytes + data + loader
    }

    @Test func containerThroughImportRelocation() throws {
        for pattern in [false, true] {
            try container(pattern: pattern).withUnsafeBytes { bytes in
                let container = try PEFContainer(bytes: bytes)
                let name = try container.name(ofSection: 0).map(Array.init)
                #expect(name == Array("data".utf8))
                guard let loader = try container.loaderSection() else {
                    Issue.record("missing loader")
                    return
                }
                let export = Array("entry".utf8).withUnsafeBufferPointer { loader.findExport(named: $0) }
                #expect(export?.sectionIndex == 0)
                var output = [UInt8](repeating: 0xFF, count: 8)
                try output.withUnsafeMutableBytes { output in
                    try container.unpackSection(at: 0, into: output)
                    let instructions = try loader.relocationInstructions(for: loader.relocationHeader(at: 0))
                    try [UInt32(0x10000)].withUnsafeBufferPointer { sections in
                        try [UInt32(0xF000001C)].withUnsafeBufferPointer { imports in
                            try PEFRelocator.apply(instructions: instructions, to: output,
                                                   sectionAdjustments: sections, importedAddresses: imports)
                        }
                    }
                }
                #expect(output == [0xF0, 0, 0, 0x1C, 0, 0, 0, 0])
            }
        }
    }

    @Test func badContainerLengthsAndIndices() {
        var bytes = container()
        bytes.replaceSubrange(48..<52, with: be32(2)) // total smaller than initialized data
        bytes.withUnsafeBytes { bytes in
            #expect(throws: PEFError.self) { _ = try PEFContainer(bytes: bytes) }
        }
        #expect(throws: PEFError.self) {
            try container().withParserSpan { (span) throws(PEFError) in
                _ = try PEFSectionHeader.parse(container: span, index: Int.max)
            }
        }
    }

    @Test func loaderRejectsOverlapsAndUnterminatedNames() {
        var badOffset = loader()
        badOffset.replaceSubrange(36..<40, with: be32(0))
        var badName = loader()
        badName.replaceSubrange(56..<60, with: be32(8))
        badName[111] = 65 // remove padding NUL after the export name
        for bytes in [badOffset, badName] {
            bytes.withUnsafeBytes { bytes in
                #expect(throws: PEFError.self) { _ = try PEFLoaderSection.parse(loaderBytes: bytes) }
            }
        }
    }

    @Test func resolvesExportPseudoSections() throws {
        for (section, value, expected): (UInt16, UInt32, UInt32) in [
            (0, 12, 0x100C), (0xFFFE, 0x12345678, 0x12345678), (0xFFFD, 0, 0xF0000000)
        ] {
            var bytes = loader()
            bytes.replaceSubrange(124..<128, with: be32(value))
            bytes.replaceSubrange(128..<130, with: be16(section))
            try bytes.withUnsafeBytes { bytes in
                let loader = try PEFLoaderSection.parse(loaderBytes: bytes)
                let symbol = try loader.exportedSymbol(at: 0)
                let address = try [UInt32(0x1000)].withUnsafeBufferPointer { sections in
                    try [UInt32(0xF0000000)].withUnsafeBufferPointer { imports in
                        try loader.address(of: symbol, sectionAddresses: sections, importedAddresses: imports)
                    }
                }
                #expect(address == expected)
            }
        }
    }

    private func prepared(
        _ bytes: [UInt8], address: UInt32 = 0x10000, capacity: Int = 12,
        imports: [UInt32] = [0xF000001C], limit: Int = 1000
    ) throws -> (bytes: [UInt8], entries: PEFEntryPoints, adjustment: UInt32) {
        var output = [UInt8](repeating: 0xFF, count: capacity)
        var scratch: [UInt32] = [0]
        let entries = try bytes.withUnsafeBytes { bytes in
            let container = try PEFContainer(bytes: bytes)
            return try output.withUnsafeMutableBytes { output in
                try [PEFSectionAllocation(guestAddress: address, bytes: output)].withUnsafeBufferPointer { sections in
                    try imports.withUnsafeBufferPointer { imports in
                        try scratch.withUnsafeMutableBufferPointer { scratch in
                            try container.prepare(sections: sections, importedAddresses: imports,
                                                  relocationScratch: scratch, operationLimit: limit)
                        }
                    }
                }
            }
        }
        return (output, entries, scratch[0])
    }

    @Test func preparesCompleteFragment() throws {
        for pattern in [false, true] {
            let result = try prepared(container(pattern: pattern))
            #expect(result.bytes == [0xF0, 0, 0, 0x1C, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])
            #expect(result.entries.main == 0x10000)
            #expect(result.entries.initialize == nil)
            #expect(result.entries.terminate == nil)
            #expect(result.adjustment == 0x10000)
        }
    }

    @Test func preparationUsesDefaultAddressAdjustment() throws {
        var bytes = container()
        bytes.replaceSubrange(44..<48, with: be32(0x2000))
        // Replace import relocation with one section-C relocation.
        bytes.replaceSubrange(204..<206, with: be16(0x4000))
        let result = try prepared(bytes)
        #expect(result.adjustment == 0xE000)
        #expect(Array(result.bytes.prefix(4)) == [0, 0, 0xE0, 0])
    }

    @Test func preparesFragmentWithoutLoader() throws {
        var bytes = Array(container().prefix(108))
        bytes.replaceSubrange(32..<34, with: be16(1))
        bytes.replaceSubrange(40..<44, with: be32(0xFFFFFFFF))
        let result = try prepared(bytes, imports: [])
        #expect(Array(result.bytes.prefix(8)) == [UInt8](repeating: 0, count: 8))
        #expect(result.entries.main == nil)
        #expect(result.entries.initialize == nil)
        #expect(result.entries.terminate == nil)
    }

    @Test func checksGuestRangeOverlapBeforeWriting() throws {
        var bytes = Array(container().prefix(112))
        bytes.replaceSubrange(34..<36, with: be16(2))
        // Turn the loader header into a second unpacked data section.
        bytes.replaceSubrange(76..<80, with: be32(8))
        bytes.replaceSubrange(80..<84, with: be32(4))
        bytes.replaceSubrange(84..<88, with: be32(4))
        bytes.replaceSubrange(88..<92, with: be32(108))
        bytes.replaceSubrange(92..<96, with: [1, 1, 2, 0])
        for address: UInt32 in [0x10004, 0x10008] {
            var first = [UInt8](repeating: 0xFF, count: 8)
            var second = first
            var scratch = [UInt32](repeating: 0, count: 2)
            do {
                try bytes.withUnsafeBytes { bytes in
                    let container = try PEFContainer(bytes: bytes)
                    try first.withUnsafeMutableBytes { first in
                        try second.withUnsafeMutableBytes { second in
                            let allocations = [
                                PEFSectionAllocation(guestAddress: 0x10000, bytes: first),
                                PEFSectionAllocation(guestAddress: address, bytes: second)
                            ]
                            try allocations.withUnsafeBufferPointer { sections in
                                try scratch.withUnsafeMutableBufferPointer { scratch in
                                    _ = try container.prepare(
                                        sections: sections,
                                        importedAddresses: UnsafeBufferPointer(start: nil, count: 0),
                                        relocationScratch: scratch
                                    )
                                }
                            }
                        }
                    }
                }
                #expect(address == 0x10008)
            } catch {
                #expect(address == 0x10004)
                #expect(first == [UInt8](repeating: 0xFF, count: 8))
                #expect(second == first)
            }
        }
    }

    @Test func preparationRejectsInvalidAllocationsAndBudgets() {
        #expect(throws: PEFError.self) { try prepared(container(), address: 3) }
        #expect(throws: PEFError.self) { try prepared(container(), address: 0xFFFFFFFC) }
        #expect(throws: PEFError.self) { try prepared(container(), capacity: 7) }
        #expect(throws: PEFError.self) { try prepared(container(), imports: []) }
        #expect(throws: PEFError.self) { try prepared(container(), limit: 0) }
    }

    @Test func resolvesImportsWithLibraryMetadata() throws {
        try loader().withUnsafeBytes { bytes in
            let loader = try PEFLoaderSection.parse(loaderBytes: bytes)
            var addresses: [UInt32] = [0, 0xDEADBEEF]
            var libraryCalls = 0
            try addresses.withUnsafeMutableBufferPointer { addresses in
                try loader.resolveImports(
                    into: addresses,
                    resolveLibrary: { (library, name) throws(PEFError) in
                        libraryCalls += 1
                        #expect(Array(name) == Array("Lib".utf8))
                        #expect(library.importedSymbolCount == 1)
                        return 42
                    },
                    resolveSymbol: { (identifier, symbol, name) throws(PEFError) in
                        #expect(identifier == 42)
                        #expect(symbol.symbolClass == .tVector)
                        #expect(Array(name) == Array("foo".utf8))
                        return 0xF000001C
                    }
                )
            }
            #expect(libraryCalls == 1)
            #expect(addresses == [0xF000001C, 0xDEADBEEF])
        }
    }

    @Test func weakImportRules() throws {
        for (weakLibrary, weakSymbol, presentLibrary, shouldThrow) in [
            (false, false, false, true), (true, false, false, false),
            (false, true, true, false), (true, false, true, true),
            (false, true, false, true)
        ] {
            var bytes = loader()
            if weakLibrary { bytes[76] = 0x40 }
            if weakSymbol { bytes[80] |= 0x80 }
            try bytes.withUnsafeBytes { bytes in
                let loader = try PEFLoaderSection.parse(loaderBytes: bytes)
                var addresses: [UInt32] = [0xDEADBEEF]
                do {
                    try addresses.withUnsafeMutableBufferPointer { addresses in
                        try loader.resolveImports(
                            into: addresses,
                            resolveLibrary: { _, _ throws(PEFError) in presentLibrary ? 1 : nil },
                            resolveSymbol: { _, _, _ throws(PEFError) in nil }
                        )
                    }
                    #expect(!shouldThrow)
                    #expect(addresses == [0])
                } catch {
                    #expect(shouldThrow)
                    guard case PEFError.unresolvedSymbol = error else {
                        Issue.record("unexpected import-resolution error")
                        return
                    }
                }
            }
        }
    }

    @Test func importGroupsCanBeReorderedButCannotOverlap() throws {
        for overlap in [false, true] {
            var bytes: [UInt8] = []
            for value: UInt32 in [0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0,
                                  2, 2, 0, 112, 112, 130, 0, 0] {
                bytes += be32(value)
            }
            // Library order differs from imported-symbol order.
            bytes += be32(0) + be32(0) + be32(0) + be32(1) + be32(1) + [0, 0, 0, 0]
            bytes += be32(5) + be32(0) + be32(0) + be32(1) + be32(overlap ? 1 : 0) + [0, 0, 0, 0]
            bytes += be32(0x0200000A) + be32(0x0200000E)
            bytes += Array("LibA\0LibB\0foo\0bar\0".utf8) + be32(0)
            try bytes.withUnsafeBytes { bytes in
                let loader = try PEFLoaderSection.parse(loaderBytes: bytes)
                var addresses: [UInt32] = [0, 0]
                var callbacks = 0
                do {
                    try addresses.withUnsafeMutableBufferPointer { addresses in
                        try loader.resolveImports(
                            into: addresses,
                            resolveLibrary: { (_, name) throws(PEFError) in
                                callbacks += 1
                                return name[3] == 65 ? 10 : 20
                            },
                            resolveSymbol: { (identifier, _, _) throws(PEFError) in identifier + 100 }
                        )
                    }
                    #expect(!overlap)
                    #expect(addresses == [120, 110])
                    #expect(callbacks == 2)
                } catch {
                    #expect(overlap)
                    #expect(callbacks == 0)
                }
            }
        }
    }

    @Test func importResolutionChecksCoverageAndCapacity() throws {
        var missingOwner = loader()
        missingOwner.replaceSubrange(68..<72, with: be32(0))
        try missingOwner.withUnsafeBytes { bytes in
            let loader = try PEFLoaderSection.parse(loaderBytes: bytes)
            var addresses: [UInt32] = [0]
            #expect(throws: PEFError.self) {
                try addresses.withUnsafeMutableBufferPointer { addresses in
                    try loader.resolveImports(into: addresses,
                        resolveLibrary: { _, _ throws(PEFError) in 0 },
                        resolveSymbol: { _, _, _ throws(PEFError) in 0 })
                }
            }
        }
        try loader().withUnsafeBytes { bytes in
            let loader = try PEFLoaderSection.parse(loaderBytes: bytes)
            #expect(throws: PEFError.self) {
                try loader.resolveImports(into: UnsafeMutableBufferPointer(start: nil, count: 0),
                    resolveLibrary: { _, _ throws(PEFError) in 0 },
                    resolveSymbol: { _, _, _ throws(PEFError) in 0 })
            }
        }
    }

    @Test func hashRegressionVectors() {
        for (name, expected): (String, UInt32) in [
            ("NewPtr", 0x00060DF2), ("printf", 0x00060B5E),
            ("VeryLongClassicMacintoshSymbolName", 0x00229D8B),
            ("abcdefghijklmnopqrstuvwxyz", 0x001A02D0), ("NewPtr\0ignored", 0x00060DF2)
        ] {
            let hash = Array(name.utf8).withUnsafeBufferPointer { CFMHash.computeHashWord($0) }
            #expect(hash == expected)
        }
    }

    @Test func patternRejectsOversizedCounts() {
        // Both arguments fit 32 bits but their expansion cannot fit in this destination.
        let packed: [UInt8] = [0x60, 0x8F, 0xFF, 0xFF, 0xFF, 0x7F,
                               0x8F, 0xFF, 0xFF, 0xFF, 0x7F, 0x8F, 0xFF, 0xFF, 0xFF, 0x7F]
        var output = [UInt8](repeating: 0, count: 8)
        #expect(throws: PEFError.self) {
            try output.withUnsafeMutableBytes { output in
                try packed.withParserSpan { (span) throws(PEFError) in
                    _ = try PEFPatternDecoder.unpack(&span, into: output)
                }
            }
        }
    }

    @Test func xattrErrorsAreTyped() {
        #expect(throws: PEFError.self) {
            try "/dev/null/not-a-file".withCString { path in
                _ = try XattrResourceReader.byteCount(path: path)
            }
        }
    }

    @Test func crossSectionReferencesAreChecked() {
        var bytes = container()
        // Loader begins at 108. Its main entry cannot refer to the noninstantiated loader.
        bytes.replaceSubrange(108..<112, with: be32(1))
        bytes.withUnsafeBytes { bytes in
            #expect(throws: PEFError.self) {
                let container = try PEFContainer(bytes: bytes)
                _ = try container.loaderSection()
            }
        }
    }

    @Test func emptyResourceMap() throws {
        var bytes = be32(16) + be32(16) + be32(0) + be32(30)
        bytes += [UInt8](repeating: 0, count: 22)
        bytes += be16(0) + be16(28) + be16(30) + be16(0xFFFF)
        try bytes.withUnsafeBytes { bytes in
            let fork = try ResourceFork(bytes: bytes)
            let count = fork.typeCount
            #expect(count == 0)
        }
    }

    @Test func patternFiveByteArguments() throws {
        // The PEF five-byte encoding discards the high three accumulation bits.
        let bytes: [UInt8] = [0, 0xF0, 0x80, 0x80, 0x80, 1]
        var output: [UInt8] = [0xFF]
        let written = try output.withUnsafeMutableBytes { output in
            try bytes.withParserSpan { (span) throws(PEFError) in
                try PEFPatternDecoder.unpack(&span, into: output)
            }
        }
        #expect(written == 1)
        #expect(output == [0])
    }

    #if canImport(Darwin)
    @Test func xattrRoundTrip() throws {
        var template = Array("/tmp/swift-pef-xattr-XXXXXX".utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress) }
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer {
            _ = close(descriptor)
            template.withUnsafeBufferPointer { _ = unlink($0.baseAddress) }
        }
        let payload: [UInt8] = [0, 1, 2, 3, 0xFF]
        let status = template.withUnsafeBufferPointer { path in
            payload.withUnsafeBytes { bytes in
                setxattr(path.baseAddress, "com.apple.ResourceFork", bytes.baseAddress, bytes.count, 0, 0)
            }
        }
        #expect(status == 0)
        guard status == 0 else { return }
        try template.withUnsafeBufferPointer { path in
            guard let path = path.baseAddress else { return }
            let count = try XattrResourceReader.byteCount(path: path)
            #expect(count == payload.count)
            var output = [UInt8](repeating: 0, count: count)
            let read = try output.withUnsafeMutableBytes { try XattrResourceReader.read(path: path, into: $0) }
            #expect(read == count)
            #expect(output == payload)
        }
    }
    #endif
}
