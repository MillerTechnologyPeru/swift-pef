// Instruction field accessors (PowerPC numbers bits from the most significant end).
extension UInt32 {
    /// rD / rS / frD / frS / BO / crfD field (bits 6-10).
    @inline(__always) var fieldD: Int { Int((self >> 21) & 31) }
    /// rA / frA / BI field (bits 11-15).
    @inline(__always) var fieldA: Int { Int((self >> 16) & 31) }
    /// rB / frB / SH field (bits 16-20).
    @inline(__always) var fieldB: Int { Int((self >> 11) & 31) }
    /// frC field (bits 21-25).
    @inline(__always) var fieldC: Int { Int((self >> 6) & 31) }
    /// Record bit (Rc / LK share bit 31).
    @inline(__always) var recordBit: Bool { self & 1 != 0 }
    /// Sign-extended 16-bit immediate.
    @inline(__always) var simm: UInt32 { UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: self))) }
    /// Zero-extended 16-bit immediate.
    @inline(__always) var uimm: UInt32 { self & 0xFFFF }
}

extension PPC32State {
    /// Executes one instruction.
    ///
    /// `pc` is advanced past the instruction before it executes, so branch handlers overwrite it.
    /// On `.illegalInstruction` `pc` is restored to the offending instruction.
    public mutating func step() -> PPC32StepResult {
        let cia = pc
        if cia == Self.returnSentinel { return .returnToHost }
        if cia >= Self.importTrapBase { return .cfmImportTrap }

        let instruction = readUInt32(cia)
        pc = cia &+ 4
        timeBase &+= 1

        let result = execute(instruction, cia: cia)
        if result == .illegalInstruction { pc = cia }
        return result
    }

    /// Runs until the guest leaves normal execution or `maxInstructions` have retired.
    public mutating func run(maxInstructions: Int) -> PPC32StepResult {
        var retired = 0
        while retired < maxInstructions {
            let result = step()
            if result != .continue { return result }
            retired += 1
        }
        return .continue
    }

    private mutating func execute(_ i: UInt32, cia: UInt32) -> PPC32StepResult {
        switch i >> 26 {
        case 7, 8, 10, 11, 12, 13, 14, 15, 20, 21, 23, 24, 25, 26, 27, 28, 29:
            return executeIntegerImmediate(i) ? .continue : .illegalInstruction

        case 16, 18:
            return executeBranch(i, cia: cia)

        case 19:
            return executeBranchOrCRLogic(i, cia: cia)

        case 31:
            return executeExtended31(i)

        case 32...47:
            return executeLoadStore(i) ? .continue : .illegalInstruction

        case 48...55:
            return executeFloatLoadStore(i) ? .continue : .illegalInstruction

        case 59:
            return executeFloatArithmetic(i, single: true) ? .continue : .illegalInstruction

        case 63:
            return executeFloat63(i) ? .continue : .illegalInstruction

        default:
            return .illegalInstruction
        }
    }

    /// Primary opcode 31: dispatches on the 10-bit extended opcode across the unit files.
    private mutating func executeExtended31(_ i: UInt32) -> PPC32StepResult {
        if executeIntegerExtended(i) { return .continue }
        if executeLoadStoreExtended(i) { return .continue }
        if executeFloatLoadStoreExtended(i) { return .continue }
        if executeSystem(i) { return .continue }
        return .illegalInstruction
    }
}
