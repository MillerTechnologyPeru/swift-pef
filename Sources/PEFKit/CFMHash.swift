public enum CFMHash {
    /// Apple Code Fragment Manager symbol hash (`PEFComputeHashWord`).
    ///
    /// Mirrors `PEFBinaryFormat.h`: the running value is a 16-bit-wide
    /// "pseudo rotate" (`(x << 1) - (x >> 16)`) XORed with each byte, then folded.
    @inlinable
    public static func computeHashWord(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32 {
        var hashValue: Int32 = 0
        var length: UInt32 = 0
        for byte in bytes {
            if byte == 0 { break }
            hashValue = ((hashValue << 1) &- (hashValue >> 16)) ^ Int32(byte)
            length &+= 1
        }
        let folded = UInt32(bitPattern: hashValue)
        return (length << 16) | ((folded ^ (folded >> 16)) & 0xFFFF)
    }
}
