import CMORA
import PPC32Core

enum EmulatedPPCBackend {
    /// Borrows the mapping for the invocation and bounds execution, including import loops.
    static func call(
        codeAddress: UInt32,
        toc: UInt32,
        stackPointer: UInt32,
        in memory: borrowing GuestAddressSpace,
        maxInstructions: Int,
        configure: (inout PPC32State) -> Void = { _ in },
        dispatchImport: (UInt32, inout MORAInvocationFrame) -> Bool
    ) -> (result: PPC32StepResult, r3: UInt32, f1: Double) {
        var state = PPC32State(memoryBase: memory.basePointer)
        state.pc = codeAddress
        state.lr = PPC32State.returnSentinel
        state.gpr[1] = stackPointer
        state.gpr[2] = toc
        configure(&state)
        for _ in 0..<max(0, maxInstructions) {
            let result = state.step()
            switch result {
            case .continue:
                break
            case .cfmImportTrap:
                var frame = MORAInvocationFrame()
                withUnsafeMutableBytes(of: &frame.gpr) { bytes in
                    let registers = bytes.bindMemory(to: UInt32.self)
                    for index in 0..<8 {
                        registers[index] = state.gpr[index + 3]
                    }
                }
                withUnsafeMutableBytes(of: &frame.fpr) { bytes in
                    let registers = bytes.bindMemory(to: Double.self)
                    for index in 0..<13 {
                        registers[index] = state.fpr[index + 1]
                    }
                }
                frame.callerSP = state.gpr[1]
                guard dispatchImport(state.importSymbolIndex, &frame) else {
                    return (result, state.gpr[3], state.fpr[1])
                }
                state.gpr[3] = frame.returnGPR
                state.gpr[4] = frame.returnGPR2
                state.fpr[1] = frame.returnFPR
                state.returnFromImportTrap()
            case .returnToHost, .illegalInstruction:
                return (result, state.gpr[3], state.fpr[1])
            }
        }
        return (.continue, state.gpr[3], state.fpr[1])
    }
}
