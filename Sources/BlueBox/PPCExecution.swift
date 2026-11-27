import PPC32Core

enum PPCExecutionStop: Equatable {
    case alertPending
    case returned
    case initializationFailed(Int16)
    case instructionLimit
    case unsupportedImport(UInt32)
    case unsupportedRoutineDescriptor(UInt32)
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

/// Shared across the outer invocation and its callbacks, including synthetic trap steps.
final class GuestInstructionBudget {
    var remaining: Int
    init(_ limit: Int) { remaining = max(0, limit) }
}

struct GuestPPCInvocation {
    let vector: UInt32
    let arguments: [UInt32]
    var procInfo: UInt32? = nil
}

enum GuestCallbackError: Error, Equatable {
    case invalidVector
    case invalidStack
    case tooManyArguments
    case unsupportedRoutineDescriptor
}
