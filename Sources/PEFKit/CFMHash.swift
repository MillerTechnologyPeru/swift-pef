public enum CFMHash {
    /// Apple Code Fragment Manager symbol hash (`PEFComputeHashWord`).
    ///
    /// Mirrors `PEFBinaryFormat.h`: the running value is a 16-bit-wide
    /// "pseudo rotate" (`(x << 1) - (x >> 15)`) XORed with each byte, then folded.
    @inlinable
    public static func computeHashWord(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32 {
        var hashValue: Int32 = 0
        for byte in bytes {
            hashValue = ((hashValue << 1) &- (hashValue >> 15)) ^ Int32(byte)
        }
        let length = UInt32(truncatingIfNeeded: bytes.count)
        let folded = UInt32(bitPattern: hashValue)
        return (length << 16) | ((folded ^ (folded >> 16)) & 0xFFFF)
    }
}
