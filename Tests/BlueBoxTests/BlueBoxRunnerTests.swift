import Foundation
import Testing
@testable import BlueBox

@Suite struct BlueBoxRunnerTests {
    private func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    private func be16(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    /// Code + data/TOC/TVector + loader, with real section and import relocation records.
    private func executable(_ instructions: [UInt32], imported: Bool = false, entryOffset: UInt32 = 0) -> [UInt8] {
        let code = instructions.flatMap(be32)
        let dataOffset = (128 + code.count + 15) / 16 * 16
        let loaderOffset = dataOffset + 16
        let relocations: [UInt16] = imported ? [0x4600, 0x8003, 0x6000] : [0x4600]
        let strings = imported ? Array("InterfaceLib\0TickCount\0".utf8) : []
        let relocationOffset = imported ? 96 : 68
        let stringsOffset = relocationOffset + relocations.count * 2
        let hashOffset = (stringsOffset + strings.count + 3) / 4 * 4
        var loader: [UInt8] = []
        for word: UInt32 in [1, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0,
                              imported ? 1 : 0, imported ? 1 : 0, 1,
                              UInt32(relocationOffset), UInt32(stringsOffset), UInt32(hashOffset), 0, 0] {
            loader += be32(word)
        }
        if imported {
            loader += be32(0) + be32(0) + be32(0) + be32(1) + be32(0) + [0, 0, 0, 0]
            loader += be32(0x0200000D)
        }
        loader += be16(1) + be16(0) + be32(UInt32(relocations.count)) + be32(0)
        loader += relocations.flatMap(be16) + strings
        while loader.count < hashOffset { loader.append(0) }
        loader += be32(0)
        var bytes: [UInt8] = []
        for word: UInt32 in [0x4A6F7921, 0x70656666, 0x70777063, 1, 0, 0, 0, 0] { bytes += be32(word) }
        bytes += be16(3) + be16(2) + be32(0)
        func section(_ total: Int, _ offset: Int, _ kind: UInt8) -> [UInt8] {
            be32(0xFFFFFFFF) + be32(0) + be32(UInt32(total)) + be32(UInt32(total))
                + be32(UInt32(total)) + be32(UInt32(offset)) + [kind, 1, 4, 0]
        }
        bytes += section(code.count, 128, 0)
        bytes += section(16, dataOffset, 1)
        bytes += section(loader.count, loaderOffset, 4)
        while bytes.count < 128 { bytes.append(0) }
        bytes += code
        while bytes.count < dataOffset { bytes.append(0) }
        bytes += be32(entryOffset) + be32(8) + be32(42) + be32(0)
        return bytes + loader
    }

    @Test func loadsTVectorTOCAndStackAndReturns() throws {
        // Load through r2, spill below r1, reload, return.
        let bytes = executable([0x80620000, 0x9061FFFC, 0x8061FFFC, 0x4E800020])
        let report = try bytes.withUnsafeBytes { try BlueBoxRunner.run(bytes: $0) }
        #expect(report.execution.stop == .returned)
        #expect(report.execution.r3 == 42)
        #expect(report.execution.instructions == 4)
        #expect(report.codeAddress == 0x01000000)
        #expect(report.toc == 0x01004008 || report.toc == 0x01001008) // host page size
        #expect(report.initialStackPointer % 16 == 0)
        #expect(report.execution.stackPointer == report.initialStackPointer)
        #expect(report.diagnostic.contains("returned r3=42"))
    }

    @Test func boundsGuestLoops() throws {
        let report = try executable([0x48000000]).withUnsafeBytes {
            try BlueBoxRunner.run(bytes: $0, maxInstructions: 7)
        }
        #expect(report.execution.stop == .instructionLimit)
        #expect(report.execution.instructions == 7)
        #expect(report.execution.pc == report.codeAddress)
    }

    @Test func diagnosesIllegalOpcode() throws {
        let report = try executable([0]).withUnsafeBytes { try BlueBoxRunner.run(bytes: $0) }
        #expect(report.execution.stop == .illegalInstruction(0))
        #expect(report.execution.pc == report.codeAddress)
        #expect(report.diagnostic.contains("0x00000000"))
    }

    @Test func diagnosesNamedImportThroughSyntheticTVector() throws {
        let bytes = executable([0x81820004, 0x800C0000, 0x804C0004, 0x7C0903A6, 0x4E800421], imported: true)
        let report = try bytes.withUnsafeBytes { try BlueBoxRunner.run(bytes: $0) }
        #expect(report.execution.stop == .unsupportedImport(0))
        #expect(report.diagnostic.contains("InterfaceLib:TickCount"))
        #expect(report.execution.instructions == 5)
    }

    @Test func diagnosesUnmappedReadAndProtectedWrite() throws {
        let read = try executable([0x80600000]).withUnsafeBytes { try BlueBoxRunner.run(bytes: $0) }
        #expect(read.execution.stop == .memoryFault(address: 0, write: false))
        let write = try executable([0x3C800100, 0x90640000]).withUnsafeBytes { try BlueBoxRunner.run(bytes: $0) }
        #expect(write.execution.stop == .memoryFault(address: 0x01000000, write: true))
        #expect(write.execution.pc == write.codeAddress + 4)
    }

    @Test func rejectsUnalignedEntryAndMissingInit() throws {
        let invalid = try executable([0x4E800020], entryOffset: 2).withUnsafeBytes {
            try BlueBoxRunner.run(bytes: $0)
        }
        #expect(invalid.execution.stop == .invalidInstructionAddress)
        #expect(throws: BlueBoxError.self) {
            try executable([0x4E800020]).withUnsafeBytes { try BlueBoxRunner.run(bytes: $0, entry: .initialize) }
        }
    }

    @Test func runsRealPluginWithBoundedDiagnostics() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent(".build/fixtures/extracted/bbedit/volume/BBEdit Lite 6.1/BBEdit Lite Support/Plug-Ins/Educate Quotes")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let data = try Data(contentsOf: path)
        let report = try data.withUnsafeBytes { try BlueBoxRunner.run(bytes: $0, maxInstructions: 1000) }
        #expect(report.execution.instructions <= 1000)
        print("Real execution: Educate Quotes: \(report.diagnostic)")
    }
}
