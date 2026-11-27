import Foundation
import Testing
import Graphite
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
    private func executable(_ instructions: [UInt32], imported: Bool = false,
                            importedSymbol: String = "UnknownToolboxCall", importedClass: UInt32 = 2,
                            secondaryImport: String? = nil, additionalImports: [String] = [],
                            callbackOffset: UInt32? = nil,
                            entryOffset: UInt32 = 0) -> [UInt8] {
        let code = instructions.flatMap(be32)
        let dataOffset = (128 + code.count + 15) / 16 * 16
        let loaderOffset = dataOffset + 256
        let names = imported ? [importedSymbol] + (secondaryImport.map { [$0] } ?? []) + additionalImports : []
        let relocations: [UInt16] = imported
            ? [0x4600, 0x8003, 0x6000] + (secondaryImport == nil ? [] : [0x6001])
                + (names.count > 2 ? (2..<names.count).map { UInt16(0x6000 + $0) } : []) : [0x4600]
        let strings = imported ? Array(("InterfaceLib\0" + names.map { $0 + "\0" }.joined()).utf8) : []
        let relocationOffset = imported ? 92 + names.count * 4 : 68
        let stringsOffset = relocationOffset + relocations.count * 2
        let hashOffset = (stringsOffset + strings.count + 3) / 4 * 4
        var loader: [UInt8] = []
        for word: UInt32 in [1, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0,
                              imported ? 1 : 0, UInt32(names.count), 1,
                              UInt32(relocationOffset), UInt32(stringsOffset), UInt32(hashOffset), 0, 0] {
            loader += be32(word)
        }
        if imported {
            loader += be32(0) + be32(0) + be32(0) + be32(UInt32(names.count)) + be32(0) + [0, 0, 0, 0]
            var nameOffset: UInt32 = 13
            for name in names {
                loader += be32(importedClass << 24 | nameOffset)
                nameOffset += UInt32(name.utf8.count + 1)
            }
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
        bytes += section(256, dataOffset, 1)
        bytes += section(loader.count, loaderOffset, 4)
        while bytes.count < 128 { bytes.append(0) }
        bytes += code
        while bytes.count < dataOffset { bytes.append(0) }
        bytes += be32(entryOffset) + be32(8) + be32(42) + be32(0)
        while bytes.count < loaderOffset { bytes.append(0) }
        if let callbackOffset {
            bytes.replaceSubrange(dataOffset + 48..<dataOffset + 56,
                                  with: be32(0x01000000 + callbackOffset) + be32(0))
        }
        return bytes + loader
    }

    @Test func guestReceivesLaunchEventAndCallsToolboxFromItsHandler() throws {
        func invoke(_ offset: UInt32) -> [UInt32] {
            [0x81820000 | offset, 0x800C0000, 0x804C0004, 0x7C0903A6, 0x4E800421]
        }
        var code: [UInt32] = [0x7FC802A6, 0x7C5F1378, // preserve main LR/TOC
            0x9042002C, // callback TVector TOC = this fragment's TOC
            0x3C606165, 0x60637674, 0x3C806F61, 0x60847070,
            0x38A20028, 0x38C0FFCE, 0x38E00000]
        code += invoke(4) // AEInstallEventHandler
        code += [0x7FE2FB78, 0x38600400, 0x38820040]
        code += invoke(8) // GetNextEvent
        code += [0x7FE2FB78, 0x38620040]
        code += invoke(12) // AEProcessAppleEvent
        code += [0x7FE2FB78, 0x7FC803A6, 0x4E800020]
        let callbackOffset = UInt32(code.count * 4)
        code += [0x7FA802A6, 0x7CBB2B78, // save handler LR and refcon
                 0x38600400, 0x38820050]
        code += invoke(8) // nested Toolbox call; the launch event has already been consumed
        code += [0x7F63DB78, 0x7FA803A6, 0x4E800020] // return the negative refcon as OSErr
        let bytes = executable(code, imported: true, importedSymbol: "AEInstallEventHandler",
                               secondaryImport: "GetNextEvent", additionalImports: ["AEProcessAppleEvent"],
                               callbackOffset: callbackOffset)
        let report = try bytes.withUnsafeBytes { try BlueBoxRunner.run(bytes: $0) }
        #expect(report.execution.stop == .returned)
        #expect(Int32(bitPattern: report.execution.r3) == -50)
        #expect(report.handledImportCount == 4)
        #expect(report.execution.toc == report.toc)
        #expect(report.execution.stackPointer == report.initialStackPointer)
        let limited = try bytes.withUnsafeBytes { try BlueBoxRunner.run(bytes: $0, maxInstructions: 35) }
        #expect(limited.execution.stop == .instructionLimit)
        #expect(limited.execution.instructions <= 35)
        var looping = bytes
        let handlerStart = 128 + Int(callbackOffset)
        looping.replaceSubrange(handlerStart..<handlerStart + 4, with: be32(0x48000000))
        let loopReport = try looping.withUnsafeBytes { try BlueBoxRunner.run(bytes: $0, maxInstructions: 100) }
        #expect(loopReport.execution.stop == .instructionLimit)
        #expect(loopReport.execution.pc == 0x01000000 + callbackOffset)
        #expect(loopReport.execution.instructions <= 100)
        var faulting = bytes
        faulting.replaceSubrange(handlerStart..<handlerStart + 4, with: be32(0))
        let faultReport = try faulting.withUnsafeBytes { try BlueBoxRunner.run(bytes: $0) }
        #expect(faultReport.execution.stop == .illegalInstruction(0))
        #expect(faultReport.execution.pc == 0x01000000 + callbackOffset)
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
        #expect(report.diagnostic.contains("InterfaceLib:UnknownToolboxCall"))
        #expect(report.execution.instructions == 5)
        #expect(report.handledImportCount == 0)
    }

    @Test func callsToolboxThroughTVectorAndReturnsToGuest() throws {
        // Preserve the host-return LR across bctrl, load the import TVector, call, restore LR and return.
        let code: [UInt32] = [0x7FC802A6, 0x81820004, 0x800C0000, 0x804C0004,
                              0x7C0903A6, 0x4E800421, 0x7FC803A6, 0x4E800020]
        let bytes = executable(code, imported: true, importedSymbol: "GetDblTime")
        let report = try bytes.withUnsafeBytes { try BlueBoxRunner.run(bytes: $0) }
        #expect(report.execution.stop == .returned)
        #expect(report.execution.r3 == 30)
        #expect(report.execution.instructions == 8)
        #expect(report.handledImportCount == 1)
    }

    @Test func diagnosesUnmappedReadAndProtectedWrite() throws {
        let read = try executable([0x80600000]).withUnsafeBytes { try BlueBoxRunner.run(bytes: $0) }
        #expect(read.execution.stop == .memoryFault(address: 0, write: false))
        let write = try executable([0x3C800100, 0x90640000]).withUnsafeBytes { try BlueBoxRunner.run(bytes: $0) }
        #expect(write.execution.stop == .memoryFault(address: 0x01000000, write: true))
        #expect(write.execution.pc == write.codeAddress + 4)
    }

    @Test func initializesApplicationOwnedQuickDrawGlobals() throws {
        // r3=&thePort within this PEF's data, r31=&randSeed, then call InitGraf and read randSeed.
        let code: [UInt32] = [0x7FC802A6, 0x386200CA, 0x3BE3FF82,
                              0x81820004, 0x800C0000, 0x804C0004, 0x7C0903A6, 0x4E800421,
                              0x807F0000, 0x7FC803A6, 0x4E800020]
        let report = try executable(code, imported: true, importedSymbol: "InitGraf").withUnsafeBytes {
            try BlueBoxRunner.run(bytes: $0)
        }
        #expect(report.execution.stop == .returned)
        #expect(report.execution.r3 == 1)
        #expect(report.handledImportCount == 1)
    }

    @Test func resolvesImportedQuickDrawData() throws {
        let report = try executable([0x80620004, 0x4E800020], imported: true,
                                    importedSymbol: "qd", importedClass: 1).withUnsafeBytes {
            try BlueBoxRunner.run(bytes: $0)
        }
        #expect(report.execution.stop == .returned)
        #expect(report.execution.r3 == GuestQuickDrawGlobals.address)
    }

    @Test func guestReadsPascalFontNameWrittenByGraphiteBridge() throws {
        // Save LR, put a guest data buffer in r4, request system family 0, then read its Pascal length.
        let code: [UInt32] = [0x7FC802A6, 0x3BE20028, 0x389F0000, 0x38600000,
                              0x81820004, 0x800C0000, 0x804C0004, 0x7C0903A6, 0x4E800421,
                              0x887F0000, 0x7FC803A6, 0x4E800020]
        let report = try executable(code, imported: true, importedSymbol: "GetFontName").withUnsafeBytes {
            try BlueBoxRunner.run(bytes: $0)
        }
        #expect(report.execution.stop == .returned)
        #expect(report.execution.r3 == 7)
        #expect(report.handledImportCount == 1)
    }

    @Test func guestDereferencesWindowManagerRegionHandle() throws {
        // Call InitWindows, follow WMgrPort.visRgn's master pointer, read the rectangular region size.
        let code: [UInt32] = [0x7FC802A6, 0x81820004, 0x800C0000, 0x804C0004,
                              0x7C0903A6, 0x4E800421, 0x3C802200, 0x80840018,
                              0x80840000, 0xA0640000, 0x7FC803A6, 0x4E800020]
        let report = try executable(code, imported: true, importedSymbol: "InitWindows").withUnsafeBytes {
            try BlueBoxRunner.run(bytes: $0)
        }
        #expect(report.execution.stop == .returned)
        #expect(report.execution.r3 == 10)
        #expect(report.handledImportCount == 1)
    }

    @Test func returnsMenuBarHeightThroughImportTVector() throws {
        let code: [UInt32] = [0x7FC802A6, 0x81820004, 0x800C0000, 0x804C0004,
                              0x7C0903A6, 0x4E800421, 0x7FC803A6, 0x4E800020]
        let report = try executable(code, imported: true, importedSymbol: "GetMBarHeight").withUnsafeBytes {
            try BlueBoxRunner.run(bytes: $0)
        }
        #expect(report.execution.stop == .returned)
        #expect(report.execution.r3 == 20)
        #expect(report.handledImportCount == 1)
    }

    @Test func guestDereferencesEmptyTextEditScrapHandle() throws {
        let code: [UInt32] = [0x7FC802A6, 0x81820004, 0x800C0000, 0x804C0004,
                              0x7C0903A6, 0x4E800421, 0x3C802300, 0x80640000,
                              0x7FC803A6, 0x4E800020]
        let report = try executable(code, imported: true, importedSymbol: "TEInit").withUnsafeBytes {
            try BlueBoxRunner.run(bytes: $0)
        }
        #expect(report.execution.stop == .returned)
        #expect(report.execution.r3 == 0) // Empty handle's data pointer is nil.
        #expect(report.handledImportCount == 1)
    }

    @Test func checksGuestParamTextReadsAfterDialogInitialization() throws {
        for valid in [false, true] {
            var code: [UInt32] = [0x7FC802A6, 0x3BE20000, 0x38600000,
                                  0x81820004, 0x800C0000, 0x804C0004, 0x7C0903A6, 0x4E800421,
                                  0x385F0000]
            // All four strings point to an empty Pascal string in guest data, or to unmapped null.
            code += valid ? [0x38620028, 0x38820028, 0x38A20028, 0x38C20028]
                          : [0x38600000, 0x38800000, 0x38A00000, 0x38C00000]
            code += [0x81820008, 0x800C0000, 0x804C0004, 0x7C0903A6, 0x4E800421,
                     0x7FC803A6, 0x4E800020]
            let report = try executable(code, imported: true, importedSymbol: "InitDialogs",
                                        secondaryImport: "ParamText").withUnsafeBytes {
                try BlueBoxRunner.run(bytes: $0)
            }
            #expect(report.execution.stop == (valid ? .returned : .memoryFault(address: 0, write: false)))
            #expect(report.handledImportCount == (valid ? 2 : 1))
        }
    }

    @Test func guestWritesAllocatedPointerAndDereferencesAllocatedHandle() throws {
        for handle in [false, true] {
            var code: [UInt32] = [0x7FC802A6, 0x38600010, 0x81820004, 0x800C0000,
                                  0x804C0004, 0x7C0903A6, 0x4E800421]
            if handle { code += [0x80630000] } // Master pointer -> data pointer.
            code += [0x3880002A, 0x90830000, 0x80630000, 0x7FC803A6, 0x4E800020]
            let report = try executable(code, imported: true,
                                        importedSymbol: handle ? "NewHandleClear" : "NewPtrClear").withUnsafeBytes {
                try BlueBoxRunner.run(bytes: $0)
            }
            #expect(report.execution.stop == .returned)
            #expect(report.execution.r3 == 42)
            #expect(report.handledImportCount == 1)
        }
    }

    @Test func guestReadsMemErrorAfterAllocationFailure() throws {
        let code: [UInt32] = [0x7FC802A6, 0x3BE20000, 0x3860FFFF,
                              0x81820004, 0x800C0000, 0x804C0004, 0x7C0903A6, 0x4E800421,
                              0x385F0000, 0x81820008, 0x800C0000, 0x804C0004, 0x7C0903A6,
                              0x4E800421, 0x7FC803A6, 0x4E800020]
        let report = try executable(code, imported: true, importedSymbol: "NewPtr",
                                    secondaryImport: "MemError").withUnsafeBytes {
            try BlueBoxRunner.run(bytes: $0)
        }
        #expect(report.execution.stop == .returned)
        #expect(Int32(bitPattern: report.execution.r3) == -108)
        #expect(report.handledImportCount == 2)
    }

    @Test func guestGestaltCallWritesResponseAndReportsErrors() throws {
        for scenario in 0..<3 {
            let selector: UInt32 = scenario == 1 ? 0x7174696D : 0x73797361 // qtim or sysa
            var code: [UInt32] = [0x7FC802A6, 0x3BE20028,
                                  0x3C600000 | (selector >> 16), 0x60630000 | (selector & 0xFFFF)]
            code += [scenario == 2 ? 0x38800000 : 0x389F0000,
                     0x81820004, 0x800C0000, 0x804C0004, 0x7C0903A6, 0x4E800421]
            if scenario == 0 { code += [0x807F0000] }
            code += [0x7FC803A6, 0x4E800020]
            let report = try executable(code, imported: true, importedSymbol: "Gestalt").withUnsafeBytes {
                try BlueBoxRunner.run(bytes: $0)
            }
            if scenario == 2 {
                #expect(report.execution.stop == .memoryFault(address: 0, write: true))
                #expect(report.handledImportCount == 0)
            } else {
                #expect(report.execution.stop == .returned)
                #expect(Int32(bitPattern: report.execution.r3) == (scenario == 0 ? 2 : -5551))
                #expect(report.handledImportCount == 1)
            }
        }
    }

    @Test func guestReadsStringBytesFromApplicationResourceFork() throws {
        let resources = try ResourceMap.write([(resource: Resource(type: "STR#", id: -7),
                                                bytes: [0, 1, 1, 0x8E])])
        let code: [UInt32] = [0x7FC802A6, 0x3BE20028, 0x387F0000, 0x3880FFF9, 0x38A00001,
                              0x81820004, 0x800C0000, 0x804C0004, 0x7C0903A6, 0x4E800421,
                              0x887F0001, 0x7FC803A6, 0x4E800020]
        let report = try executable(code, imported: true, importedSymbol: "GetIndString").withUnsafeBytes {
            try BlueBoxRunner.run(bytes: $0, resourceFork: resources)
        }
        #expect(report.execution.stop == .returned)
        #expect(report.execution.r3 == 0x8E)
        #expect(report.handledImportCount == 1)
    }

    @Test func guestConvertsPascalStringInPlaceAndUsesReturnedPointer() throws {
        let code: [UInt32] = [0x7FC802A6, 0x3BE20028, 0x3C80028E, 0x60844100, 0x909F0000,
                              0x387F0000, 0x81820004, 0x800C0000, 0x804C0004, 0x7C0903A6,
                              0x4E800421, 0x88630000, 0x7FC803A6, 0x4E800020]
        let report = try executable(code, imported: true, importedSymbol: "p2cstr").withUnsafeBytes {
            try BlueBoxRunner.run(bytes: $0)
        }
        #expect(report.execution.stop == .returned)
        #expect(report.execution.r3 == 0x8E)
        #expect(report.handledImportCount == 1)
    }

    @Test func guestBlockMoveHandlesOverlapAndProtectedDestination() throws {
        for protected in [false, true] {
            let code: [UInt32] = [0x7FC802A6, 0x38620028, 0x3CC01234, 0x60C65678, 0x90C30000,
                                  0x3BE30001, protected ? 0x3C800100 : 0x389F0000, 0x38A00004,
                                  0x81820004, 0x800C0000, 0x804C0004, 0x7C0903A6, 0x4E800421,
                                  0x807F0000, 0x7FC803A6, 0x4E800020]
            let report = try executable(code, imported: true, importedSymbol: "BlockMoveData").withUnsafeBytes {
                try BlueBoxRunner.run(bytes: $0)
            }
            if protected {
                #expect(report.execution.stop == .memoryFault(address: 0x01000000, write: true))
                #expect(report.handledImportCount == 0)
            } else {
                #expect(report.execution.stop == .returned)
                #expect(report.execution.r3 == 0x12345678)
                #expect(report.handledImportCount == 1)
            }
        }
    }

    @Test func guestDereferencesLoadedResourceHandle() throws {
        let resources = try ResourceMap.write([(resource: Resource(type: "TEST", id: -7), bytes: [1, 2, 3, 4])])
        let code: [UInt32] = [0x7FC802A6, 0x3C605445, 0x60635354, 0x3880FFF9,
                              0x81820004, 0x800C0000, 0x804C0004, 0x7C0903A6, 0x4E800421,
                              0x80630000, 0x80630000, 0x7FC803A6, 0x4E800020]
        let report = try executable(code, imported: true, importedSymbol: "GetResource").withUnsafeBytes {
            try BlueBoxRunner.run(bytes: $0, resourceFork: resources)
        }
        #expect(report.execution.stop == .returned)
        #expect(report.execution.r3 == 0x01020304)
        #expect(report.handledImportCount == 1)
    }

    @Test func guestInstallsAndRetrievesAppleEventHandler() throws {
        // Save LR/TOC, register an opaque guest UPP and refcon, then retrieve both into guest data.
        let code: [UInt32] = [0x7FC802A6, 0x3BE20000, 0x3C606165, 0x60637674,
                              0x3C806F61, 0x60847070, 0x3CA00100, 0x60A50200, 0x38C0FFFF, 0x38E00000,
                              0x81820004, 0x800C0000, 0x804C0004, 0x7C0903A6, 0x4E800421,
                              0x385F0000, 0x3BA20028, 0x3C606165, 0x60637674, 0x3C806F61, 0x60847070,
                              0x38BD0000, 0x38DD0004, 0x38E00000,
                              0x81820008, 0x800C0000, 0x804C0004, 0x7C0903A6, 0x4E800421,
                              0x807D0000, 0x7FC803A6, 0x4E800020]
        let report = try executable(code, imported: true, importedSymbol: "AEInstallEventHandler",
                                    secondaryImport: "AEGetEventHandler").withUnsafeBytes {
            try BlueBoxRunner.run(bytes: $0)
        }
        #expect(report.execution.stop == .returned)
        #expect(report.execution.r3 == 0x01000200)
        #expect(report.handledImportCount == 2)
    }

    @Test func initGrafRejectsReadOnlyGuestDestination() throws {
        // Pass thePort=code+126, making InitGraf's first write target the code section.
        let code: [UInt32] = [0x3C600100, 0x3863007E,
                              0x81820004, 0x800C0000, 0x804C0004, 0x7C0903A6, 0x4E800421]
        let report = try executable(code, imported: true, importedSymbol: "InitGraf").withUnsafeBytes {
            try BlueBoxRunner.run(bytes: $0)
        }
        #expect(report.execution.stop == .memoryFault(address: 0x01000000, write: true))
        #expect(report.handledImportCount == 0)
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

    @Test func macGzipAdvancesPastQuickDrawInitialization() throws {
        let root = ProcessInfo.processInfo.environment["PEF_FIXTURES_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/fixtures")
        let path = root.appendingPathComponent("extracted/macgzip/MacGzip/MacGzip")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let app = try BlueBoxApplication.load(path: path.path)
        #expect(app.resourceFork != nil)
        let report = try app.dataFork.withUnsafeBytes {
            try BlueBoxRunner.run(bytes: $0, resourceFork: app.resourceFork,
                                  captureFramebuffer: true, maxInstructions: 10000)
        }
        #expect(report.execution.stop == .alertPending)
        #expect(report.pendingAlert?.id == 151)
        #expect(report.diagnostic.contains("Sorry, System 7 required"))
        #expect(report.diagnostic.contains("gestaltUndefSelectorErr"))
        #expect(report.framebufferPPM?.count == 921615)
        #expect(report.handledImportCount == 19)
        #expect(report.execution.instructions == 1513)
    }
}
