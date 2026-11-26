extension PPC32State {
    /// Effective-address base: `(rA|0)`.
    @inline(__always)
    private func base(_ register: Int) -> UInt32 {
        register == 0 ? 0 : gpr[register]
    }

    // MARK: - D-form loads and stores (opcodes 32-47)

    mutating func executeLoadStore(_ i: UInt32) -> Bool {
        let opcode = i >> 26
        let d = i.fieldD
        let a = i.fieldA
        let ea = base(a) &+ i.simm

        switch opcode {
        case 32, 33: // lwz, lwzu
            gpr[d] = readUInt32(ea)
        case 34, 35: // lbz, lbzu
            gpr[d] = UInt32(readUInt8(ea))
        case 40, 41: // lhz, lhzu
            gpr[d] = UInt32(readUInt16(ea))
        case 42, 43: // lha, lhau
            gpr[d] = UInt32(bitPattern: Int32(Int16(bitPattern: readUInt16(ea))))
        case 36, 37: // stw, stwu
            writeUInt32(gpr[d], at: ea)
        case 38, 39: // stb, stbu
            writeUInt8(UInt8(truncatingIfNeeded: gpr[d]), at: ea)
        case 44, 45: // sth, sthu
            writeUInt16(UInt16(truncatingIfNeeded: gpr[d]), at: ea)

        case 46: // lmw
            var address = ea
            for register in d...31 {
                gpr[register] = readUInt32(address)
                address = address &+ 4
            }
            return true

        case 47: // stmw
            var address = ea
            for register in d...31 {
                writeUInt32(gpr[register], at: address)
                address = address &+ 4
            }
            return true

        default:
            return false
        }

        // Update forms (odd opcodes) write the effective address back to rA.
        if opcode & 1 != 0 { gpr[a] = ea }
        return true
    }

    // MARK: - X-form loads and stores (opcode 31)

    mutating func executeLoadStoreExtended(_ i: UInt32) -> Bool {
        let xo = (i >> 1) & 0x3FF
        let d = i.fieldD
        let a = i.fieldA
        let ea = base(a) &+ gpr[i.fieldB]
        var update = false

        switch xo {
        case 23, 55: // lwzx, lwzux
            gpr[d] = readUInt32(ea)
            update = xo == 55
        case 87, 119: // lbzx, lbzux
            gpr[d] = UInt32(readUInt8(ea))
            update = xo == 119
        case 279, 311: // lhzx, lhzux
            gpr[d] = UInt32(readUInt16(ea))
            update = xo == 311
        case 343, 375: // lhax, lhaux
            gpr[d] = UInt32(bitPattern: Int32(Int16(bitPattern: readUInt16(ea))))
            update = xo == 375
        case 151, 183: // stwx, stwux
            writeUInt32(gpr[d], at: ea)
            update = xo == 183
        case 215, 247: // stbx, stbux
            writeUInt8(UInt8(truncatingIfNeeded: gpr[d]), at: ea)
            update = xo == 247
        case 407, 439: // sthx, sthux
            writeUInt16(UInt16(truncatingIfNeeded: gpr[d]), at: ea)
            update = xo == 439

        case 534: // lwbrx
            gpr[d] = readUInt32(ea).byteSwapped
        case 790: // lhbrx
            gpr[d] = UInt32(readUInt16(ea).byteSwapped)
        case 662: // stwbrx
            writeUInt32(gpr[d].byteSwapped, at: ea)
        case 918: // sthbrx
            writeUInt16(UInt16(truncatingIfNeeded: gpr[d]).byteSwapped, at: ea)

        case 20: // lwarx
            gpr[d] = readUInt32(ea)
            hasReservation = true
            reservedAddress = ea

        case 150: // stwcx. (single guest thread: succeeds while the reservation is held)
            var nibble: UInt32 = xer & 0x8000_0000 != 0 ? 0x1 : 0
            if hasReservation && reservedAddress == ea {
                writeUInt32(gpr[d], at: ea)
                nibble |= 0x2
            }
            hasReservation = false
            setCRField(0, nibble)

        case 1014: // dcbz: zero one 32-byte cache line
            let line = ea & ~31
            for offset in 0..<4 { writeUInt64(0, at: line &+ UInt32(offset * 8)) }

        case 54, 86, 246, 278, 470, 982: // dcbst, dcbf, dcbtst, dcbt, dcbi, icbi: no cache to maintain
            break

        default:
            return false
        }

        if update { gpr[a] = ea }
        return true
    }
}
