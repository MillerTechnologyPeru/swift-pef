#if !arch(powerpc)
import CMORA
import PPC32Core

enum EmulatedPPCBackend {
    typealias CallbackError = GuestCallbackError

    /// Invokes a TVector or supported Mixed Mode UPP on a dedicated stack frame.
    static func callVector(
        at vector: UInt32, arguments: [UInt32], stackPointer: UInt32,
        in memory: borrowing GuestAddressSpace, maxInstructions: Int,
        memoryRegions: UnsafeBufferPointer<PPC32MemoryRegion>,
        expectedProcInfo: UInt32? = nil,
        budget: GuestInstructionBudget? = nil,
        dispatchImport: (UInt32, inout MORAInvocationFrame) -> Bool
    ) throws(CallbackError) -> PPCExecutionReport {
        guard arguments.count <= 8 else { throw .tooManyArguments }
        let vector = try GuestRoutineDescriptor.resolve(vector, expectedProcInfo: expectedProcInfo, read: { address, count in
            guard memoryRegions.contains(where: { $0.contains(address, byteCount: count) }) else { return nil }
            return Array(UnsafeRawBufferPointer(start: memory.hostPointer(for: address), count: count))
        })
        guard vector != 0, vector & 3 == 0,
              memoryRegions.contains(where: { $0.contains(vector, byteCount: 8) }) else {
            throw .invalidVector
        }
        guard stackPointer != 0, stackPointer & 15 == 0,
              memoryRegions.contains(where: { $0.writable && $0.contains(stackPointer, byteCount: 64) }) else {
            throw .invalidStack
        }
        let code = memory.readBigEndian(UInt32.self, at: vector)
        let toc = memory.readBigEndian(UInt32.self, at: vector + 4)
        // Reserve the linkage and register argument areas without inheriting host stack state.
        memory.hostPointer(for: stackPointer).initializeMemory(as: UInt8.self, repeating: 0, count: 64)
        memory.writeBigEndian(PPC32State.returnSentinel, at: stackPointer + 8)
        memory.writeBigEndian(toc, at: stackPointer + 20)
        return call(codeAddress: code, toc: toc, stackPointer: stackPointer,
                    in: memory, maxInstructions: maxInstructions, memoryRegions: memoryRegions,
                    budget: budget, configure: { state in
                        for (index, argument) in arguments.enumerated() { state.gpr[index + 3] = argument }
                    }, dispatchImport: dispatchImport)
    }

    /// Borrows the mapping and optional memory regions for the complete invocation.
    static func call(
        codeAddress: UInt32,
        toc: UInt32,
        stackPointer: UInt32,
        in memory: borrowing GuestAddressSpace,
        maxInstructions: Int,
        memoryRegions: UnsafeBufferPointer<PPC32MemoryRegion>? = nil,
        budget: GuestInstructionBudget? = nil,
        configure: (inout PPC32State) -> Void = { _ in },
        takeCallback: () -> GuestPPCInvocation? = { nil },
        completeCallback: () -> Void = {},
        dispatchImport: (UInt32, inout MORAInvocationFrame) -> Bool
    ) -> PPCExecutionReport {
        let budget = budget ?? GuestInstructionBudget(maxInstructions)
        var fault = UInt64.max
        return withUnsafeMutablePointer(to: &fault) { fault in
            var state = PPC32State(memoryBase: memory.basePointer)
            state.pc = codeAddress
            state.lr = PPC32State.returnSentinel
            state.gpr[1] = stackPointer
            state.gpr[2] = toc
            configure(&state)
            state.memoryRegions = memoryRegions
            state.memoryFault = fault
            while budget.remaining > 0 {
                budget.remaining -= 1
                let instructionPC = state.pc
                if instructionPC < PPC32State.importTrapBase {
                    let executable = memoryRegions.map { regions in
                        regions.contains { $0.executable && $0.contains(instructionPC, byteCount: 4) }
                    } ?? true
                    guard instructionPC & 3 == 0, executable else {
                        return report(state, result: .illegalInstruction, stop: .invalidInstructionAddress)
                    }
                }
                let result = state.step()
                if fault.pointee != UInt64.max {
                    return report(state, result: .illegalInstruction,
                                  stop: .memoryFault(address: UInt32(truncatingIfNeeded: fault.pointee),
                                                     write: fault.pointee & (UInt64(1) << 32) != 0),
                                  pc: instructionPC)
                }
                switch result {
                case .continue:
                    break
                case .cfmImportTrap:
                    var frame = MORAInvocationFrame()
                    withUnsafeMutableBytes(of: &frame.gpr) { bytes in
                        let registers = bytes.bindMemory(to: UInt32.self)
                        for index in 0..<8 { registers[index] = state.gpr[index + 3] }
                    }
                    withUnsafeMutableBytes(of: &frame.fpr) { bytes in
                        let registers = bytes.bindMemory(to: Double.self)
                        for index in 0..<13 { registers[index] = state.fpr[index + 1] }
                    }
                    frame.callerSP = state.gpr[1]
                    guard dispatchImport(state.importSymbolIndex, &frame) else {
                        return report(state, result: result, stop: .unsupportedImport(state.importSymbolIndex))
                    }
                    if let callback = takeCallback() {
                        guard let memoryRegions, state.gpr[1] >= 256 else {
                            completeCallback()
                            return report(state, result: result, stop: .memoryFault(address: state.gpr[1], write: true))
                        }
                        let callbackStack = (state.gpr[1] - 256) & ~UInt32(15)
                        do {
                            let child = try callVector(at: callback.vector, arguments: callback.arguments,
                                stackPointer: callbackStack, in: memory,
                                maxInstructions: budget.remaining,
                                memoryRegions: memoryRegions, expectedProcInfo: callback.procInfo,
                                budget: budget, dispatchImport: dispatchImport)
                            let total = state.timeBase + child.instructions
                            completeCallback()
                            guard child.stop == .returned else {
                                return PPCExecutionReport(result: child.result, stop: child.stop, pc: child.pc,
                                    lr: child.lr, stackPointer: child.stackPointer, toc: child.toc,
                                    r3: child.r3, f1: child.f1, instructions: total)
                            }
                            state.timeBase = total
                            // AppleEvent handlers return a signed 16-bit OSErr.
                            frame.returnGPR = UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: child.r3)))
                        } catch {
                            completeCallback()
                            if (error as? CallbackError) == .unsupportedRoutineDescriptor {
                                return report(state, result: result, stop: .unsupportedRoutineDescriptor(callback.vector))
                            }
                            let invalidVector = (error as? CallbackError) == .invalidVector
                            let address = invalidVector ? callback.vector : callbackStack
                            return report(state, result: result,
                                          stop: .memoryFault(address: address, write: !invalidVector))
                        }
                    }
                    state.gpr[3] = frame.returnGPR
                    state.gpr[4] = frame.returnGPR2
                    state.fpr[1] = frame.returnFPR
                    state.returnFromImportTrap()
                case .returnToHost:
                    return report(state, result: result, stop: .returned)
                case .illegalInstruction:
                    return report(state, result: result, stop: .illegalInstruction(state.readUInt32(state.pc)))
                }
            }
            return report(state, result: .continue, stop: .instructionLimit)
        }
    }

    private static func report(
        _ state: borrowing PPC32State, result: PPC32StepResult, stop: PPCExecutionStop, pc: UInt32? = nil
    ) -> PPCExecutionReport {
        PPCExecutionReport(result: result, stop: stop, pc: pc ?? state.pc, lr: state.lr,
                           stackPointer: state.gpr[1], toc: state.gpr[2],
                           r3: state.gpr[3], f1: state.fpr[1], instructions: state.timeBase)
    }
}

#endif
