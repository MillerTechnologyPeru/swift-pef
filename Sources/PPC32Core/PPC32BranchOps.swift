extension PPC32State {
    // MARK: - Branch helpers

    /// Transfers control to `target`, reporting import traps and the host-return sentinel immediately.
    private mutating func branch(to target: UInt32) -> PPC32StepResult {
        pc = target
        if target == Self.returnSentinel { return .returnToHost }
        return target >= Self.importTrapBase ? .cfmImportTrap : .continue
    }

    /// Evaluates the BO/BI condition of a conditional branch, decrementing CTR when BO asks for it.
    private mutating func branchConditionHolds(bo: Int, bi: Int) -> Bool {
        let counterOK: Bool
        if bo & 0x04 == 0 {
            ctr = ctr &- 1
            counterOK = (ctr != 0) != (bo & 0x02 != 0)
        } else {
            counterOK = true
        }
        let conditionOK = bo & 0x10 != 0 || crBit(bi) == (bo & 0x08 != 0)
        return counterOK && conditionOK
    }

    // MARK: - b, bc

    mutating func executeBranch(_ i: UInt32, cia: UInt32) -> PPC32StepResult {
        let absolute = i & 2 != 0
        let link = i.recordBit

        if i >> 26 == 18 { // b, ba, bl, bla
            let displacement = UInt32(bitPattern: (Int32(bitPattern: i & 0x03FF_FFFC) << 6) >> 6)
            let target = absolute ? displacement : cia &+ displacement
            if link { lr = cia &+ 4 }
            return branch(to: target)
        }

        // bc, bca, bcl, bcla
        let taken = branchConditionHolds(bo: i.fieldD, bi: i.fieldA)
        if link { lr = cia &+ 4 }
        guard taken else { return .continue }
        let displacement = UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: i & 0xFFFC)))
        return branch(to: absolute ? displacement : cia &+ displacement)
    }

    // MARK: - Opcode 19: bclr, bcctr and condition-register logic

    mutating func executeBranchOrCRLogic(_ i: UInt32, cia: UInt32) -> PPC32StepResult {
        let xo = (i >> 1) & 0x3FF
        let link = i.recordBit

        switch xo {
        case 16: // bclr: the target is the LR value from before this instruction's own link update
            let target = lr & ~3
            let taken = branchConditionHolds(bo: i.fieldD, bi: i.fieldA)
            if link { lr = cia &+ 4 }
            return taken ? branch(to: target) : .continue

        case 528: // bcctr
            let target = ctr & ~3
            let taken = branchConditionHolds(bo: i.fieldD, bi: i.fieldA)
            if link { lr = cia &+ 4 }
            return taken ? branch(to: target) : .continue

        case 150: // isync
            return .continue

        case 0: // mcrf
            setCRField(i.fieldD >> 2, crField(i.fieldA >> 2))
            return .continue

        case 257, 129, 289, 225, 33, 449, 417, 193:
            let a = crBit(i.fieldA)
            let b = crBit(i.fieldB)
            let result: Bool
            switch xo {
            case 257: result = a && b // crand
            case 129: result = a && !b // crandc
            case 289: result = a == b // creqv
            case 225: result = !(a && b) // crnand
            case 33: result = !(a || b) // crnor
            case 449: result = a || b // cror
            case 417: result = a || !b // crorc
            default: result = a != b // crxor
            }
            setCRBit(i.fieldD, result)
            return .continue

        default:
            return .illegalInstruction
        }
    }

    // MARK: - SPR and CR moves (opcode 31)

    mutating func executeSystem(_ i: UInt32) -> Bool {
        let xo = (i >> 1) & 0x3FF
        let d = i.fieldD
        // The 10-bit SPR number is stored with its two 5-bit halves swapped.
        let spr = (i.fieldA) | (i.fieldB << 5)

        switch xo {
        case 339: // mfspr
            switch spr {
            case 1: gpr[d] = xer
            case 8: gpr[d] = lr
            case 9: gpr[d] = ctr
            case 256: gpr[d] = vrsave
            default: return false
            }

        case 467: // mtspr
            switch spr {
            case 1: xer = gpr[d]
            case 8: lr = gpr[d]
            case 9: ctr = gpr[d]
            case 256: vrsave = gpr[d]
            default: return false
            }

        case 371: // mftb
            switch spr {
            case 268: gpr[d] = UInt32(truncatingIfNeeded: timeBase)
            case 269: gpr[d] = UInt32(truncatingIfNeeded: timeBase >> 32)
            default: return false
            }

        case 19: // mfcr
            gpr[d] = cr

        case 144: // mtcrf
            let fieldMask = (i >> 12) & 0xFF
            var mask: UInt32 = 0
            for field in 0..<8 where fieldMask & (0x80 >> UInt32(field)) != 0 {
                mask |= 0xF << UInt32(28 - 4 * field)
            }
            cr = (cr & ~mask) | (gpr[d] & mask)

        case 512: // mcrxr
            setCRField(d >> 2, xer >> 28)
            xer &= 0x0FFF_FFFF

        case 598, 854: // sync, eieio
            break

        default:
            return false
        }
        return true
    }
}
