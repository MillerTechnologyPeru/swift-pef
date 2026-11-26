/// Unpacks a pattern-initialized data section (`PEFSectionKind.patternInitializedData`).
///
/// Each instruction byte holds a 3-bit opcode and a 5-bit count. A count of zero means the
/// real value follows as a variable-length integer (7 bits per byte, high bit = continue).
public enum PEFPatternDecoder {
    /// Decodes `packed` into `output`, returning the number of bytes written.
    /// `output` must be at least as large as the section's `unpackedLength`.
    public static func unpack(
        _ packed: UnsafeRawBufferPointer,
        into output: UnsafeMutableRawBufferPointer
    ) throws(PEFError) -> Int {
        var input = 0
        var out = 0

        func readArg() throws(PEFError) -> Int {
            var value = 0
            while true {
                guard input < packed.count else { throw .truncatedSection(index: -1) }
                let byte = packed[input]
                input += 1
                value = (value << 7) | Int(byte & 0x7F)
                if byte & 0x80 == 0 { return value }
                guard value <= Int(UInt32.max) else { throw .truncatedSection(index: -1) }
            }
        }

        func copy(_ count: Int) throws(PEFError) {
            guard input + count <= packed.count, out + count <= output.count else {
                throw .truncatedSection(index: -1)
            }
            for i in 0..<count { output[out + i] = packed[input + i] }
            input += count
            out += count
        }

        func zero(_ count: Int) throws(PEFError) {
            guard out + count <= output.count else { throw .truncatedSection(index: -1) }
            for i in 0..<count { output[out + i] = 0 }
            out += count
        }

        while input < packed.count {
            let instruction = packed[input]
            input += 1
            let opcode = instruction >> 5
            var count = Int(instruction & 0x1F)
            if count == 0 { count = try readArg() }

            switch opcode {
            case 0: // Zero: `count` zero bytes
                try zero(count)

            case 1: // Block copy: `count` literal bytes
                try copy(count)

            case 2: // Repeated block: block of `count` bytes, repeated (arg + 1) times
                let repeatCount = try readArg() + 1
                guard input + count <= packed.count,
                      out + count * repeatCount <= output.count else {
                    throw .truncatedSection(index: -1)
                }
                let blockStart = input
                for _ in 0..<repeatCount {
                    for i in 0..<count { output[out + i] = packed[blockStart + i] }
                    out += count
                }
                input += count

            case 3, 4: // Interleave repeat block / zero: common = count, custom = arg1, repeat = arg2
                let customSize = try readArg()
                let repeatCount = try readArg()
                if opcode == 3 {
                    guard input + count <= packed.count else { throw .truncatedSection(index: -1) }
                }
                let commonStart = input
                if opcode == 3 { input += count }

                func emitCommon() throws(PEFError) {
                    if opcode == 3 {
                        guard out + count <= output.count else { throw .truncatedSection(index: -1) }
                        for i in 0..<count { output[out + i] = packed[commonStart + i] }
                        out += count
                    } else {
                        try zero(count)
                    }
                }

                try emitCommon()
                for _ in 0..<repeatCount {
                    try copy(customSize)
                    try emitCommon()
                }

            default:
                throw .invalidPatternOpcode(opcode)
            }
        }
        return out
    }
}
