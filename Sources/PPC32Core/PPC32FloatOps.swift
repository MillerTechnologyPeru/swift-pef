// Scalar IEEE-754 floating point. FPSCR exception/sticky bits other than FPCC are not tracked.
extension PPC32State {
    @inline(__always)
    private func base(_ register: Int) -> UInt32 {
        register == 0 ? 0 : gpr[register]
    }

    /// Copies FPSCR[FX FEX VX OX] into CR1 for record-form (`.`) floating-point instructions.
    private mutating func recordCR1() {
        setCRField(1, fpscr >> 28)
    }

    // MARK: - Loads and stores

    mutating func executeFloatLoadStore(_ i: UInt32) -> Bool {
        let opcode = i >> 26
        let d = i.fieldD
        let a = i.fieldA
        let ea = base(a) &+ i.simm

        switch opcode {
        case 48, 49: fpr[d] = Double(Float(bitPattern: readUInt32(ea))) // lfs, lfsu
        case 50, 51: fpr[d] = Double(bitPattern: readUInt64(ea)) // lfd, lfdu
        case 52, 53: writeUInt32(Float(fpr[d]).bitPattern, at: ea) // stfs, stfsu
        case 54, 55: writeUInt64(fpr[d].bitPattern, at: ea) // stfd, stfdu
        default: return false
        }
        if opcode & 1 != 0 { gpr[a] = ea }
        return true
    }

    mutating func executeFloatLoadStoreExtended(_ i: UInt32) -> Bool {
        let xo = (i >> 1) & 0x3FF
        let d = i.fieldD
        let a = i.fieldA
        let ea = base(a) &+ gpr[i.fieldB]
        var update = false

        switch xo {
        case 535, 567: // lfsx, lfsux
            fpr[d] = Double(Float(bitPattern: readUInt32(ea)))
            update = xo == 567
        case 599, 631: // lfdx, lfdux
            fpr[d] = Double(bitPattern: readUInt64(ea))
            update = xo == 631
        case 663, 695: // stfsx, stfsux
            writeUInt32(Float(fpr[d]).bitPattern, at: ea)
            update = xo == 695
        case 727, 759: // stfdx, stfdux
            writeUInt64(fpr[d].bitPattern, at: ea)
            update = xo == 759
        case 983: // stfiwx: low word of the FPR
            writeUInt32(UInt32(truncatingIfNeeded: fpr[d].bitPattern), at: ea)
        default:
            return false
        }
        if update { gpr[a] = ea }
        return true
    }

    // MARK: - A-form arithmetic (opcodes 59 and 63)

    /// `single` selects opcode 59 (results rounded to single precision) over opcode 63.
    mutating func executeFloatArithmetic(_ i: UInt32, single: Bool) -> Bool {
        let d = i.fieldD
        let a = fpr[i.fieldA]
        let b = fpr[i.fieldB]
        let c = fpr[i.fieldC]

        var result: Double
        switch (i >> 1) & 0x1F {
        case 18: result = a / b // fdiv, fdivs
        case 20: result = a - b // fsub, fsubs
        case 21: result = a + b // fadd, fadds
        case 22: result = b.squareRoot() // fsqrt, fsqrts
        case 24 where single: result = 1.0 / b // fres
        case 25: result = a * c // fmul, fmuls
        case 26 where !single: result = 1.0 / b.squareRoot() // frsqrte
        case 23 where !single: // fsel
            fpr[d] = a >= 0.0 ? c : b
            if i.recordBit { recordCR1() }
            return true
        case 28: result = (-b).addingProduct(a, c) // fmsub, fmsubs
        case 29: result = b.addingProduct(a, c) // fmadd, fmadds
        case 30: result = -((-b).addingProduct(a, c)) // fnmsub, fnmsubs
        case 31: result = -(b.addingProduct(a, c)) // fnmadd, fnmadds
        default: return false
        }

        if single { result = Double(Float(result)) }
        fpr[d] = result
        if i.recordBit { recordCR1() }
        return true
    }

    // MARK: - Opcode 63

    mutating func executeFloat63(_ i: UInt32) -> Bool {
        let d = i.fieldD
        let a = i.fieldA
        let b = i.fieldB

        switch (i >> 1) & 0x3FF {
        case 0, 32: // fcmpu, fcmpo
            let x = fpr[a]
            let y = fpr[b]
            let nibble: UInt32 = x.isNaN || y.isNaN ? 0x1 : (x < y ? 0x8 : (x > y ? 0x4 : 0x2))
            setCRField(d >> 2, nibble)
            fpscr = (fpscr & ~0xF000) | (nibble << 12)
            return true

        case 12: fpr[d] = Double(Float(fpr[b])) // frsp
        case 14: // fctiw (honours FPSCR[RN])
            let rule: FloatingPointRoundingRule
            switch fpscr & 3 {
            case 1: rule = .towardZero
            case 2: rule = .up
            case 3: rule = .down
            default: rule = .toNearestOrEven
            }
            fpr[d] = integerWordBits(fpr[b], rule)
        case 15: fpr[d] = integerWordBits(fpr[b], .towardZero) // fctiwz
        case 40: fpr[d] = -fpr[b] // fneg
        case 72: fpr[d] = fpr[b] // fmr
        case 136: fpr[d] = -abs(fpr[b]) // fnabs
        case 264: fpr[d] = abs(fpr[b]) // fabs

        case 583: // mffs
            fpr[d] = Double(bitPattern: 0xFFF8_0000_0000_0000 | UInt64(fpscr))

        case 711: // mtfsf
            let fieldMask = (i >> 17) & 0xFF
            let value = UInt32(truncatingIfNeeded: fpr[b].bitPattern)
            for field in 0..<8 where fieldMask & (0x80 >> UInt32(field)) != 0 {
                let mask: UInt32 = 0xF << UInt32(28 - 4 * field)
                fpscr = (fpscr & ~mask) | (value & mask)
            }

        case 134: // mtfsfi
            let field = d >> 2
            let mask: UInt32 = 0xF << UInt32(28 - 4 * field)
            fpscr = (fpscr & ~mask) | (((i >> 12) & 0xF) << UInt32(28 - 4 * field))

        case 70: fpscr &= ~(1 << UInt32(31 - d)) // mtfsb0
        case 38: fpscr |= 1 << UInt32(31 - d) // mtfsb1

        default:
            return executeFloatArithmetic(i, single: false)
        }
        if i.recordBit { recordCR1() }
        return true
    }

    /// Converts to a saturated 32-bit integer and returns it as the FPR bit pattern `fctiw` produces.
    private func integerWordBits(_ value: Double, _ rule: FloatingPointRoundingRule) -> Double {
        let rounded = value.rounded(rule)
        let word: Int32
        if rounded.isNaN || rounded < -2147483648.0 {
            word = Int32.min
        } else if rounded >= 2147483648.0 {
            word = Int32.max
        } else {
            word = Int32(rounded)
        }
        return Double(bitPattern: 0xFFF8_0000_0000_0000 | UInt64(UInt32(bitPattern: word)))
    }
}
