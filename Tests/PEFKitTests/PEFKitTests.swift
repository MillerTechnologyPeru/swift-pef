import Testing
@testable import PEFKit

@Suite struct PatternDecoderTests {
    private func unpack(_ bytes: [UInt8], capacity: Int = 64) throws -> [UInt8] {
        var out = [UInt8](repeating: 0xFF, count: capacity)
        let written = try bytes.withUnsafeBytes { src in
            try out.withUnsafeMutableBytes { dst in
                try PEFPatternDecoder.unpack(src, into: dst)
            }
        }
        return Array(out[0..<written])
    }

    @Test func zeroFill() throws {
        #expect(try unpack([0x03]) == [0, 0, 0])
    }

    @Test func blockCopy() throws {
        #expect(try unpack([0x23, 1, 2, 3]) == [1, 2, 3])
    }

    @Test func repeatedBlock() throws {
        // block of 2 bytes, arg 2 => repeated 3 times
        #expect(try unpack([0x42, 0x02, 0xAA, 0xBB]) == [0xAA, 0xBB, 0xAA, 0xBB, 0xAA, 0xBB])
    }

    @Test func interleaveRepeatBlock() throws {
        // common = [9], custom size 2, repeat 2 => 9 c c 9 c c 9
        let packed: [UInt8] = [0x61, 0x02, 0x02, 9, 1, 2, 3, 4]
        #expect(try unpack(packed) == [9, 1, 2, 9, 3, 4, 9])
    }

    @Test func interleaveRepeatZero() throws {
        let packed: [UInt8] = [0x82, 0x01, 0x02, 7, 8]
        #expect(try unpack(packed) == [0, 0, 7, 0, 0, 8, 0, 0])
    }

    @Test func variableLengthCount() throws {
        // count field 0 => arg 0x81 0x00 = 128 zeros
        #expect(try unpack([0x00, 0x81, 0x00], capacity: 256).count == 128)
    }

    @Test func invalidOpcode() {
        #expect(throws: PEFError.self) { try unpack([0xE1]) }
    }
}

@Suite struct CFMHashTests {
    @Test func lengthIsStoredInHighHalf() {
        let name: [UInt8] = Array("NewPtr".utf8)
        let hash = name.withUnsafeBufferPointer { CFMHash.computeHashWord($0) }
        #expect(hash >> 16 == 6)
    }
}
