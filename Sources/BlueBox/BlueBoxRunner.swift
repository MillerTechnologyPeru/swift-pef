import PEFKit
import PPC32Core
import Graphite

enum BlueBoxEntry: String {
    case main
    case initialize = "init"
    case terminate = "term"
}

struct GuestImport {
    let library: String
    let symbol: String
    let symbolClass: PEFSymbolClass
}

struct BlueBoxRunReport {
    let execution: PPCExecutionReport
    let codeAddress: UInt32
    let toc: UInt32
    let initialStackPointer: UInt32
    let sectionCount: Int
    let imports: [GuestImport]
    let handledImportCount: UInt64
    let pendingAlert: GuestAlert?
    let framebufferPPM: [UInt8]?
    let executionEntry: BlueBoxEntry

    var diagnostic: String {
        let phase = executionEntry == .initialize ? "init, " : ""
        let context = "\(phase)pc=\(hex(execution.pc)), lr=\(hex(execution.lr)), instructions=\(execution.instructions)"
        switch execution.stop {
        case .alertPending:
            let text = pendingAlert?.items.filter { !$0.isButton }.map(\.text).joined(separator: " | ") ?? ""
            return "StopAlert #\(pendingAlert?.id ?? 0) awaiting input: \(text) (\(context))"
        case .returned:
            return "returned r3=\(execution.r3), f1=\(execution.f1) (\(context))"
        case .initializationFailed(let error):
            return "fragment initialization failed with OSErr \(error) (\(context))"
        case .instructionLimit:
            return "instruction limit reached (\(context))"
        case .unsupportedImport(let index):
            return "unsupported import \(importName(index)) (\(context))"
        case .unsupportedRoutineDescriptor(let address):
            return "unsupported Mixed Mode routine descriptor at \(hex(address)) (\(context))"
        case .illegalInstruction(let opcode):
            return "unsupported/illegal instruction \(hex(opcode)) (\(context))"
        case .invalidInstructionAddress:
            return "unaligned or non-executable instruction address (\(context))"
        case .memoryFault(let address, let write):
            if address >= PPC32State.importTrapBase {
                let index = (address - PPC32State.importTrapBase) / 4
                if Int(index) < imports.count {
                    return "unsupported data import \(importName(index)) at \(hex(address)) (\(context))"
                }
            }
            return "guest memory \(write ? "write" : "read") fault at \(hex(address)) (\(context))"
        }
    }

    private func importName(_ index: UInt32) -> String {
        guard Int(index) < imports.count else { return "#\(index)" }
        let symbol = imports[Int(index)]
        return "\(symbol.library):\(symbol.symbol)"
    }
}

func hex(_ value: UInt32) -> String {
    "0x" + String(repeating: "0", count: 8 - String(value, radix: 16).count) + String(value, radix: 16)
}

enum BlueBoxRunner {
    /// Prepares one application fragment, initializing it before main in the same guest context.
    static func run(
        bytes: UnsafeRawBufferPointer, resourceFork: [UInt8]? = nil,
        captureFramebuffer: Bool = false,
        files: [GuestFile] = [],
        applicationFile: GuestFile? = nil,
        entry: BlueBoxEntry = .main, maxInstructions: Int = 100_000
    ) throws -> BlueBoxRunReport {
        #if arch(powerpc)
        throw BlueBoxError.nativeExecutionUnavailable
        #else
        let container = try PEFContainer(bytes: bytes)
        guard let loader = try container.loaderSection() else { throw BlueBoxError.missingEntry(entry.rawValue) }
        let memory = try GuestAddressSpace()
        var allocations: [PEFSectionAllocation] = []
        var regions: [PPC32MemoryRegion] = []
        var nextAddress: UInt64 = 0x0100_0000
        for index in 0..<Int(container.header.instSectionCount) {
            let section = try container.section(at: index)
            let alignment = max(UInt64(memory.pageSize), UInt64(1) << section.alignment)
            nextAddress = (nextAddress + alignment - 1) / alignment * alignment
            guard nextAddress + UInt64(section.totalLength) <= 0x1000_0000 else {
                throw BlueBoxError.guestLayoutTooLarge
            }
            let address = UInt32(nextAddress)
            let length = Int(section.totalLength)
            if length > 0 { try memory.commit(at: address, byteCount: length) }
            allocations.append(PEFSectionAllocation(
                guestAddress: address,
                bytes: UnsafeMutableRawBufferPointer(start: memory.hostPointer(for: address), count: length)
            ))
            let executable = section.kind == .code || section.kind == .executableData
            let writable = section.kind != .code && section.kind != .constant
            regions.append(PPC32MemoryRegion(address: address, byteCount: section.totalLength,
                                            writable: writable, executable: executable))
            nextAddress += UInt64(max(length, 1))
        }

        let importCount = Int(loader.info.totalImportedSymbolCount)
        guard importCount <= 0x0100_0000 / 8 else { throw BlueBoxError.guestLayoutTooLarge }
        let vectorBase: UInt32 = 0x2000_0000
        let vectorLength = importCount * 8
        if vectorLength > 0 {
            try memory.commit(at: vectorBase, byteCount: vectorLength)
            regions.append(PPC32MemoryRegion(address: vectorBase, byteCount: UInt32(vectorLength), writable: false))
        }
        let vectorPointer = memory.hostPointer(for: vectorBase)
        try memory.commit(at: GuestQuickDrawGlobals.address, byteCount: Int(GuestQuickDrawGlobals.byteCount))
        regions.append(PPC32MemoryRegion(address: GuestQuickDrawGlobals.address,
                                        byteCount: GuestQuickDrawGlobals.byteCount, writable: true))
        var importedAddresses = [UInt32](repeating: 0, count: importCount)
        var imports: [GuestImport] = []
        var libraryNames: [UInt32: String] = [:]
        try importedAddresses.withUnsafeMutableBufferPointer { addresses in
            try loader.resolveImports(
                into: addresses,
                resolveLibrary: { (library, name) throws(PEFError) in
                    if library.isWeak { return nil }
                    libraryNames[library.nameOffset] = String(decoding: name, as: UTF8.self)
                    return library.nameOffset
                },
                resolveSymbol: { (library, symbol, name) throws(PEFError) in
                    if symbol.isWeak { return nil }
                    guard let symbolClass = symbol.symbolClass else { throw .malformedLoaderSection }
                    let index = UInt32(imports.count)
                    imports.append(GuestImport(library: libraryNames[library] ?? "?",
                                               symbol: String(decoding: name, as: UTF8.self),
                                               symbolClass: symbolClass))
                    if libraryNames[library] == "InterfaceLib", symbolClass == .data,
                       String(decoding: name, as: UTF8.self) == "qd" {
                        return GuestQuickDrawGlobals.address
                    }
                    let trap = PPC32State.importTrapBase + index * 4
                    if symbolClass == .tVector {
                        vectorPointer.storeBytes(of: trap.bigEndian, toByteOffset: Int(index) * 8, as: UInt32.self)
                        vectorPointer.storeBytes(of: UInt32(0), toByteOffset: Int(index) * 8 + 4, as: UInt32.self)
                        return vectorBase + index * 8
                    }
                    // Code imports branch here; accesses through unresolved data/TOC imports fault.
                    return trap
                }
            )
        }
        var scratch = [UInt32](repeating: 0, count: allocations.count)
        let entries = try allocations.withUnsafeBufferPointer { sections in
            try importedAddresses.withUnsafeBufferPointer { imports in
                try scratch.withUnsafeMutableBufferPointer { scratch in
                    try container.prepare(sections: sections, importedAddresses: imports, relocationScratch: scratch)
                }
            }
        }
        let selected: UInt32?
        switch entry {
        case .main: selected = entries.main
        case .initialize: selected = entries.initialize
        case .terminate: selected = entries.terminate
        }
        guard let selected else { throw BlueBoxError.missingEntry(entry.rawValue) }
        guard selected & 3 == 0, regions.contains(where: { $0.contains(selected, byteCount: 8) }) else {
            throw BlueBoxError.invalidEntryVector(selected)
        }
        let code = memory.readBigEndian(UInt32.self, at: selected)
        let toc = memory.readBigEndian(UInt32.self, at: selected + 4)
        let initializer = entry == .main ? entries.initialize : nil
        if let initializer {
            guard initializer & 3 == 0, regions.contains(where: { $0.contains(initializer, byteCount: 8) }) else {
                throw BlueBoxError.invalidEntryVector(initializer)
            }
        }
        let needsContext = initializer != nil || entry == .initialize
        if needsContext {
            guard bytes.count <= Int(0x30000000 - GuestFragmentContext.containerAddress) else {
                throw BlueBoxError.guestLayoutTooLarge
            }
            let context = GuestFragmentContext.bytes(containerLength: bytes.count, application: applicationFile)
            try memory.commit(at: GuestFragmentContext.address, byteCount: context.count)
            context.withUnsafeBytes { source in
                if let pointer = source.baseAddress {
                    memory.hostPointer(for: GuestFragmentContext.address).copyMemory(from: pointer, byteCount: source.count)
                }
            }
            regions.append(PPC32MemoryRegion(address: GuestFragmentContext.address, byteCount: UInt32(context.count), writable: false))
            if applicationFile == nil {
                try memory.commit(at: GuestFragmentContext.containerAddress, byteCount: bytes.count)
                if let pointer = bytes.baseAddress {
                    memory.hostPointer(for: GuestFragmentContext.containerAddress).copyMemory(from: pointer, byteCount: bytes.count)
                }
                regions.append(PPC32MemoryRegion(address: GuestFragmentContext.containerAddress,
                                                byteCount: UInt32(bytes.count), writable: false))
            }
        }
        let stackBase: UInt32 = 0x7000_0000
        let stackLength: UInt32 = 1024 * 1024
        try memory.commit(at: stackBase, byteCount: Int(stackLength))
        regions.append(PPC32MemoryRegion(address: stackBase, byteCount: stackLength, writable: true))
        // MORA's 24-byte linkage plus 32-byte argument area, rounded up to 16-byte alignment.
        let stackPointer = stackBase + stackLength - 64
        memory.writeBigEndian(UInt32(0), at: stackPointer)
        memory.writeBigEndian(PPC32State.returnSentinel, at: stackPointer + 8)
        memory.writeBigEndian(toc, at: stackPointer + 20)
        try memory.commit(at: GuestQuickDrawGlobals.screenAddress, byteCount: GuestQuickDrawGlobals.screenByteCount)
        regions.append(PPC32MemoryRegion(address: GuestQuickDrawGlobals.screenAddress,
                                        byteCount: UInt32(GuestQuickDrawGlobals.screenByteCount), writable: true))
        try memory.commit(at: GuestWindowManager.address, byteCount: Int(GuestWindowManager.byteCount))
        regions.append(PPC32MemoryRegion(address: GuestWindowManager.address,
                                        byteCount: GuestWindowManager.byteCount, writable: true))
        try memory.commit(at: GuestTextEdit.scrapHandle, byteCount: Int(GuestTextEdit.byteCount))
        regions.append(PPC32MemoryRegion(address: GuestTextEdit.scrapHandle,
                                        byteCount: GuestTextEdit.byteCount, writable: true))
        try memory.commit(at: GuestHeap.address, byteCount: Int(GuestHeap.byteCount))
        regions.append(PPC32MemoryRegion(address: GuestHeap.address, byteCount: GuestHeap.byteCount, writable: true))
        let resources = try resourceFork.map { try ResourceFile(bytes: $0) }
        let fragmentSymbols = try allocations.withUnsafeBufferPointer { sections in
            try importedAddresses.withUnsafeBufferPointer { imports in
                try GuestFragmentSymbols(loader: loader, sections: sections, imports: imports)
            }
        }
        var toolbox = ToolboxRuntime(screenPixels: memory.hostPointer(for: GuestQuickDrawGlobals.screenAddress),
                                     resources: resources, files: files + (applicationFile.map { [$0] } ?? []),
                                     fragmentSymbols: fragmentSymbols)
        var executionEntry = entry
        var execution = regions.withUnsafeBufferPointer { regions in
            let budget = GuestInstructionBudget(maxInstructions)
            func invoke(code: UInt32, toc: UInt32, initializing: Bool, elapsed: UInt64) -> PPCExecutionReport {
                // Each host entry gets a fresh linkage frame, with shared guest memory and Toolbox state.
                memory.hostPointer(for: stackPointer).initializeMemory(as: UInt8.self, repeating: 0, count: 64)
                memory.writeBigEndian(PPC32State.returnSentinel, at: stackPointer + 8)
                memory.writeBigEndian(toc, at: stackPointer + 20)
                return EmulatedPPCBackend.call(
                    codeAddress: code, toc: toc, stackPointer: stackPointer,
                    in: memory, maxInstructions: maxInstructions, memoryRegions: regions,
                    budget: budget,
                    configure: { state in
                        state.timeBase = elapsed
                        if initializing { state.gpr[3] = GuestFragmentContext.address }
                    },
                    takeCallback: { toolbox.takeAppleEventCallback() },
                    completeCallback: {
                        toolbox.completeAppleEventCallback(read: { address, count in
                            guard count >= 0, regions.contains(where: { $0.contains(address, byteCount: count) }) else { return nil }
                            return Array(UnsafeRawBufferPointer(start: memory.hostPointer(for: address), count: count))
                        }, write: { address, bytes in
                            guard regions.contains(where: { $0.writable && $0.contains(address, byteCount: bytes.count) }) else { return false }
                            bytes.withUnsafeBytes { source in
                                if let pointer = source.baseAddress { memory.hostPointer(for: address).copyMemory(from: pointer, byteCount: source.count) }
                            }
                            return true
                        })
                    },
                    dispatchImport: { index, frame in
                        guard Int(index) < imports.count else { return false }
                        return toolbox.dispatch(imports[Int(index)], frame: &frame, readGuest: { address, count in
                            guard count >= 0,
                                  regions.contains(where: { $0.contains(address, byteCount: count) }) else { return nil }
                            let bytes = UnsafeRawBufferPointer(start: memory.hostPointer(for: address), count: count)
                            return Array(bytes)
                        }, writeGuest: { address, bytes in
                            guard regions.contains(where: { $0.writable && $0.contains(address, byteCount: bytes.count) }) else {
                                return false
                            }
                            bytes.withUnsafeBytes { source in
                                if let pointer = source.baseAddress {
                                    memory.hostPointer(for: address).copyMemory(from: pointer, byteCount: source.count)
                                }
                            }
                            return true
                        })
                    }
                )
            }
            var elapsed: UInt64 = 0
            if let initializer {
                executionEntry = .initialize
                var initialized = invoke(code: memory.readBigEndian(UInt32.self, at: initializer),
                                         toc: memory.readBigEndian(UInt32.self, at: initializer + 4),
                                         initializing: true, elapsed: 0)
                guard initialized.stop == .returned else { return initialized }
                let error = Int16(truncatingIfNeeded: initialized.r3)
                guard error == 0 else {
                    initialized.stop = .initializationFailed(error)
                    return initialized
                }
                elapsed = initialized.instructions
            }
            executionEntry = entry
            var result = invoke(code: code, toc: toc, initializing: entry == .initialize, elapsed: elapsed)
            if entry == .initialize, result.stop == .returned {
                let error = Int16(truncatingIfNeeded: result.r3)
                if error != 0 { result.stop = .initializationFailed(error) }
            }
            return result
        }
        if let fault = toolbox.guestMemoryFault {
            execution.stop = .memoryFault(address: fault.address, write: fault.write)
        } else if toolbox.pendingAlert != nil {
            execution.stop = .alertPending
        }
        let snapshot = captureFramebuffer ? GuestFramebuffer.ppm(UnsafeRawBufferPointer(
            start: memory.hostPointer(for: GuestQuickDrawGlobals.screenAddress),
            count: GuestQuickDrawGlobals.screenByteCount)) : nil
        return BlueBoxRunReport(execution: execution, codeAddress: code, toc: toc,
                                initialStackPointer: stackPointer,
                                sectionCount: allocations.count, imports: imports,
                                handledImportCount: toolbox.handledImportCount,
                                pendingAlert: toolbox.pendingAlert, framebufferPPM: snapshot, executionEntry: executionEntry)
        #endif
    }
}
