import BinaryParsing

/// Unpacks a pattern-initialized data section (`PEFSectionKind.patternInitializedData`).
///
/// Each instruction byte holds a 3-bit opcode and a 5-bit count. A count of zero means the
/// real value follows as a variable-length integer (7 bits per byte, high bit = continue).
public enum PEFPatternDecoder {
    /// Decodes `packed` into `output`, returning the number of bytes written.
    /// `output` must be at least as large as the section's `unpackedLength`.
    public static func unpack(
        _ packed: inout ParserSpan,
        into output: UnsafeMutableRawBufferPointer
    ) throws(PEFError) -> Int {
        var out = 0

        while !packed.isEmpty {
            let instruction = try packed.readUInt8()
            let opcode = instruction >> 5
            var count = Int(instruction & 0x1F)
            if count == 0 { count = try readArgument(&packed) }

            switch opcode {
            case 0: // Zero: `count` zero bytes
                try appendZeros(count, to: output, at: &out)

            case 1: // Block copy: `count` literal bytes
                try appendLiteral(count, from: &packed, to: output, at: &out)

            case 2: // Repeated block: block of `count` bytes, repeated (arg + 1) times
                let repeatCount = try readArgument(&packed) + 1
                guard UInt64(count) * UInt64(repeatCount) <= UInt64(output.count - out) else {
                    throw .outputBufferTooSmall
                }
                let blockStart = out
                try appendLiteral(count, from: &packed, to: output, at: &out)
                for _ in 1..<(count == 0 ? 1 : repeatCount) {
                    try appendCopy(of: blockStart, count: count, to: output, at: &out)
                }

            case 3, 4: // Interleave repeat block / zero: common = count, custom = arg1, repeat = arg2
                let customSize = try readArgument(&packed)
                let repeatCount = try readArgument(&packed)
                let commonBytes = UInt64(count) * (UInt64(repeatCount) + 1)
                let customBytes = UInt64(customSize) * UInt64(repeatCount)
                let available = UInt64(output.count - out)
                guard commonBytes <= available, customBytes <= available - commonBytes else {
                    throw .outputBufferTooSmall
                }
                let commonStart = out
                if opcode == 3 {
                    try appendLiteral(count, from: &packed, to: output, at: &out)
                } else {
                    try appendZeros(count, to: output, at: &out)
                }
                for _ in 0..<(count == 0 && customSize == 0 ? 0 : repeatCount) {
                    try appendLiteral(customSize, from: &packed, to: output, at: &out)
                    try appendCopy(of: commonStart, count: count, to: output, at: &out)
                }

            default:
                throw .invalidPatternOpcode(opcode)
            }
        }
        return out
    }

    /// Reads a variable-length integer: 7 bits per byte, high bit set means more bytes follow.
    private static func readArgument(_ packed: inout ParserSpan) throws(PEFError) -> Int {
        var value: UInt32 = 0
        for _ in 0..<5 {
            let byte = try packed.readUInt8()
            // PEF specifies retaining only the low 32 bits of the five-byte accumulation.
            value = (value &<< 7) | UInt32(byte & 0x7F)
            if byte & 0x80 == 0 {
                guard UInt64(value) < UInt64(Int.max) else { throw .outputBufferTooSmall }
                return Int(value)
            }
        }
        throw .invalidPatternOpcode(0)
    }

    private static func reserve(
        _ count: Int,
        in output: UnsafeMutableRawBufferPointer,
        at out: Int
    ) throws(PEFError) {
        guard count >= 0, UInt64(out) + UInt64(count) <= UInt64(output.count) else {
            throw .outputBufferTooSmall
        }
    }

    private static func appendZeros(
        _ count: Int,
        to output: UnsafeMutableRawBufferPointer,
        at out: inout Int
    ) throws(PEFError) {
        try reserve(count, in: output, at: out)
        for i in 0..<count { output[out + i] = 0 }
        out += count
    }

    private static func appendLiteral(
        _ count: Int,
        from packed: inout ParserSpan,
        to output: UnsafeMutableRawBufferPointer,
        at out: inout Int
    ) throws(PEFError) {
        try reserve(count, in: output, at: out)
        for i in 0..<count { output[out + i] = try packed.readUInt8() }
        out += count
    }

    /// Re-emits `count` bytes that were already written at `source`.
    private static func appendCopy(
        of source: Int,
        count: Int,
        to output: UnsafeMutableRawBufferPointer,
        at out: inout Int
    ) throws(PEFError) {
        try reserve(count, in: output, at: out)
        for i in 0..<count { output[out + i] = output[source + i] }
        out += count
    }
}
