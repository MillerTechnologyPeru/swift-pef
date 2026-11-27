import CMORA
import PPC32Core

enum PPCExecutionStop: Equatable {
    case alertPending
    case returned
    case instructionLimit
    case unsupportedImport(UInt32)
    case illegalInstruction(UInt32)
    case invalidInstructionAddress
    case memoryFault(address: UInt32, write: Bool)
}

struct PPCExecutionReport {
    let result: PPC32StepResult
    var stop: PPCExecutionStop
    let pc: UInt32
    let lr: UInt32
    let stackPointer: UInt32
    let toc: UInt32
    let r3: UInt32
    let f1: Double
    /// Instructions attempted, including an instruction which faults or is unsupported.
    let instructions: UInt64
}

enum EmulatedPPCBackend {
    /// Borrows the mapping and optional memory regions for the complete invocation.
    static func call(
        codeAddress: UInt32,
        toc: UInt32,
        stackPointer: UInt32,
        in memory: borrowing GuestAddressSpace,
        maxInstructions: Int,
        memoryRegions: UnsafeBufferPointer<PPC32MemoryRegion>? = nil,
        configure: (inout PPC32State) -> Void = { _ in },
        dispatchImport: (UInt32, inout MORAInvocationFrame) -> Bool
    ) -> PPCExecutionReport {
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
            for _ in 0..<max(0, maxInstructions) {
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
