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
                let blockStart = out
                try appendLiteral(count, from: &packed, to: output, at: &out)
                for _ in 1..<repeatCount {
                    try appendCopy(of: blockStart, count: count, to: output, at: &out)
                }

            case 3, 4: // Interleave repeat block / zero: common = count, custom = arg1, repeat = arg2
                let customSize = try readArgument(&packed)
                let repeatCount = try readArgument(&packed)
                let commonStart = out
                if opcode == 3 {
                    try appendLiteral(count, from: &packed, to: output, at: &out)
                } else {
                    try appendZeros(count, to: output, at: &out)
                }
                for _ in 0..<repeatCount {
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
        var value: UInt64 = 0
        while true {
            let byte = try packed.readUInt8()
            value = (value << 7) | UInt64(byte & 0x7F)
            guard value <= UInt64(UInt32.max) else { throw .invalidPatternOpcode(byte) }
            if byte & 0x80 == 0 { return Int(value) }
        }
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
