extension PPC32State {
    // MARK: - Helpers

    /// Full-adder used by every add/subtract form: `a + b + carryIn` with carry-out and signed overflow.
    @inline(__always)
    func addCarrying(_ a: UInt32, _ b: UInt32, carryIn: UInt32) -> (result: UInt32, carry: Bool, overflow: Bool) {
        let wide = UInt64(a) + UInt64(b) + UInt64(carryIn)
        let result = UInt32(truncatingIfNeeded: wide)
        return (result, wide > 0xFFFF_FFFF, ((a ^ result) & (b ^ result)) >> 31 != 0)
    }

    /// Mask with ones from bit `mb` through bit `me` (big-endian numbering), wrapping if `mb > me`.
    @inline(__always)
    static func rotateMask(_ mb: Int, _ me: Int) -> UInt32 {
        let fromStart = UInt32.max >> UInt32(mb)
        let toEnd = UInt32.max << UInt32(31 - me)
        return mb <= me ? fromStart & toEnd : fromStart | toEnd
    }

    @inline(__always)
    func rotateLeft(_ value: UInt32, _ amount: Int) -> UInt32 {
        let n = UInt32(amount & 31)
        return n == 0 ? value : (value << n) | (value >> (32 - n))
    }

    mutating func compareSigned(_ a: Int32, _ b: Int32, field: Int) {
        var nibble: UInt32 = a < b ? 0x8 : (a > b ? 0x4 : 0x2)
        if xer & 0x8000_0000 != 0 { nibble |= 0x1 }
        setCRField(field, nibble)
    }

    mutating func compareUnsigned(_ a: UInt32, _ b: UInt32, field: Int) {
        var nibble: UInt32 = a < b ? 0x8 : (a > b ? 0x4 : 0x2)
        if xer & 0x8000_0000 != 0 { nibble |= 0x1 }
        setCRField(field, nibble)
    }

    // MARK: - Immediate forms and rotates

    mutating func executeIntegerImmediate(_ i: UInt32) -> Bool {
        let d = i.fieldD
        let a = i.fieldA

        switch i >> 26 {
        case 7: // mulli
            gpr[d] = UInt32(bitPattern: Int32(bitPattern: gpr[a]) &* Int32(bitPattern: i.simm))

        case 8: // subfic
            let sum = addCarrying(~gpr[a], i.simm, carryIn: 1)
            gpr[d] = sum.result
            setCarry(sum.carry)

        case 10: // cmpli
            compareUnsigned(gpr[a], i.uimm, field: Int((i >> 23) & 7))

        case 11: // cmpi
            compareSigned(Int32(bitPattern: gpr[a]), Int32(bitPattern: i.simm), field: Int((i >> 23) & 7))

        case 12, 13: // addic, addic.
            let sum = addCarrying(gpr[a], i.simm, carryIn: 0)
            gpr[d] = sum.result
            setCarry(sum.carry)
            if i >> 26 == 13 { setCR0(sum.result) }

        case 14: // addi (rA = 0 reads as zero)
            gpr[d] = (a == 0 ? 0 : gpr[a]) &+ i.simm

        case 15: // addis
            gpr[d] = (a == 0 ? 0 : gpr[a]) &+ (i.uimm << 16)

        case 24: gpr[a] = gpr[d] | i.uimm // ori
        case 25: gpr[a] = gpr[d] | (i.uimm << 16) // oris
        case 26: gpr[a] = gpr[d] ^ i.uimm // xori
        case 27: gpr[a] = gpr[d] ^ (i.uimm << 16) // xoris

        case 28: // andi.
            let result = gpr[d] & i.uimm
            gpr[a] = result
            setCR0(result)

        case 29: // andis.
            let result = gpr[d] & (i.uimm << 16)
            gpr[a] = result
            setCR0(result)

        case 20: // rlwimi
            let mask = Self.rotateMask(Int((i >> 6) & 31), Int((i >> 1) & 31))
            let rotated = rotateLeft(gpr[d], i.fieldB)
            let result = (rotated & mask) | (gpr[a] & ~mask)
            gpr[a] = result
            if i.recordBit { setCR0(result) }

        case 21: // rlwinm
            let mask = Self.rotateMask(Int((i >> 6) & 31), Int((i >> 1) & 31))
            let result = rotateLeft(gpr[d], i.fieldB) & mask
            gpr[a] = result
            if i.recordBit { setCR0(result) }

        case 23: // rlwnm
            let mask = Self.rotateMask(Int((i >> 6) & 31), Int((i >> 1) & 31))
            let result = rotateLeft(gpr[d], Int(gpr[i.fieldB] & 31)) & mask
            gpr[a] = result
            if i.recordBit { setCR0(result) }

        default:
            return false
        }
        return true
    }

    // MARK: - Opcode 31 integer forms

    mutating func executeIntegerExtended(_ i: UInt32) -> Bool {
        let xo = (i >> 1) & 0x3FF
        let d = i.fieldD
        let a = i.fieldA
        let b = i.fieldB

        // Logical, shift and extend forms write rA from rS (the "D" field).
        let logical: UInt32
        switch xo {
        case 0: // cmp
            compareSigned(Int32(bitPattern: gpr[a]), Int32(bitPattern: gpr[b]), field: Int((i >> 23) & 7))
            return true
        case 32: // cmpl
            compareUnsigned(gpr[a], gpr[b], field: Int((i >> 23) & 7))
            return true

        case 11: // mulhwu
            let result = UInt32(truncatingIfNeeded: (UInt64(gpr[a]) * UInt64(gpr[b])) >> 32)
            gpr[d] = result
            if i.recordBit { setCR0(result) }
            return true
        case 75: // mulhw
            let product = Int64(Int32(bitPattern: gpr[a])) * Int64(Int32(bitPattern: gpr[b]))
            let result = UInt32(truncatingIfNeeded: product >> 32)
            gpr[d] = result
            if i.recordBit { setCR0(result) }
            return true

        case 28: logical = gpr[d] & gpr[b] // and
        case 60: logical = gpr[d] & ~gpr[b] // andc
        case 124: logical = ~(gpr[d] | gpr[b]) // nor
        case 284: logical = ~(gpr[d] ^ gpr[b]) // eqv
        case 316: logical = gpr[d] ^ gpr[b] // xor
        case 412: logical = gpr[d] | ~gpr[b] // orc
        case 444: logical = gpr[d] | gpr[b] // or
        case 476: logical = ~(gpr[d] & gpr[b]) // nand
        case 26: logical = UInt32(gpr[d].leadingZeroBitCount) // cntlzw
        case 922: logical = UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: gpr[d]))) // extsh
        case 954: logical = UInt32(bitPattern: Int32(Int8(truncatingIfNeeded: gpr[d]))) // extsb

        case 24: // slw
            let n = gpr[b] & 0x3F
            logical = n > 31 ? 0 : gpr[d] << n
        case 536: // srw
            let n = gpr[b] & 0x3F
            logical = n > 31 ? 0 : gpr[d] >> n
        case 792: // sraw
            logical = shiftRightAlgebraic(gpr[d], by: gpr[b] & 0x3F)
        case 824: // srawi
            logical = shiftRightAlgebraic(gpr[d], by: UInt32(b))

        default:
            return executeArithmetic(i, base: xo & 0x1FF, overflowEnable: xo & 0x200 != 0)
        }

        gpr[a] = logical
        if i.recordBit { setCR0(logical) }
        return true
    }

    /// Arithmetic right shift that sets XER[CA] when a one bit is shifted out of a negative value.
    private mutating func shiftRightAlgebraic(_ value: UInt32, by amount: UInt32) -> UInt32 {
        let signed = Int32(bitPattern: value)
        if amount > 31 {
            setCarry(signed < 0)
            return signed < 0 ? UInt32.max : 0
        }
        let lostBits = amount == 0 ? 0 : value & ((1 << amount) - 1)
        setCarry(signed < 0 && lostBits != 0)
        return UInt32(bitPattern: signed >> Int32(amount))
    }

    /// add/subf/neg/mullw/divw families. `base` is the extended opcode with the OE bit removed.
    private mutating func executeArithmetic(_ i: UInt32, base: UInt32, overflowEnable: Bool) -> Bool {
        let d = i.fieldD
        let ra = gpr[i.fieldA]
        let rb = gpr[i.fieldB]
        let ca = carry

        var result: UInt32 = 0
        var overflow = false
        var setsCarry = false
        var carryOut = false

        func record(_ sum: (result: UInt32, carry: Bool, overflow: Bool), carries: Bool) {
            result = sum.result
            overflow = sum.overflow
            setsCarry = carries
            carryOut = sum.carry
        }

        switch base {
        case 266: record(addCarrying(ra, rb, carryIn: 0), carries: false) // add
        case 10: record(addCarrying(ra, rb, carryIn: 0), carries: true) // addc
        case 138: record(addCarrying(ra, rb, carryIn: ca), carries: true) // adde
        case 202: record(addCarrying(ra, 0, carryIn: ca), carries: true) // addze
        case 234: record(addCarrying(ra, UInt32.max, carryIn: ca), carries: true) // addme
        case 40: record(addCarrying(~ra, rb, carryIn: 1), carries: false) // subf
        case 8: record(addCarrying(~ra, rb, carryIn: 1), carries: true) // subfc
        case 136: record(addCarrying(~ra, rb, carryIn: ca), carries: true) // subfe
        case 200: record(addCarrying(~ra, 0, carryIn: ca), carries: true) // subfze
        case 232: record(addCarrying(~ra, UInt32.max, carryIn: ca), carries: true) // subfme
        case 104: record(addCarrying(~ra, 0, carryIn: 1), carries: false) // neg

        case 235: // mullw
            let product = Int64(Int32(bitPattern: ra)) * Int64(Int32(bitPattern: rb))
            result = UInt32(truncatingIfNeeded: product)
            overflow = product != Int64(Int32(truncatingIfNeeded: product))

        case 459: // divwu (undefined results are written as zero)
            if rb == 0 {
                result = 0
                overflow = true
            } else {
                result = ra / rb
            }

        case 491: // divw
            let n = Int32(bitPattern: ra)
            let m = Int32(bitPattern: rb)
            if m == 0 || (n == Int32.min && m == -1) {
                result = 0
                overflow = true
            } else {
                result = UInt32(bitPattern: n / m)
            }

        default:
            return false
        }

        gpr[d] = result
        if setsCarry { setCarry(carryOut) }
        if overflowEnable { setOverflow(overflow) }
        if i.recordBit { setCR0(result) }
        return true
    }
}
