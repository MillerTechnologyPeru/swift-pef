import Graphite

/// Classic two-byte-packed QDGlobals. InitGraf receives &thePort, not the record's base.
/// https://dev.os9.ca/techpubs/mac/Memory/Memory-181.html
enum GuestQuickDrawGlobals {
    static let address: UInt32 = 0x2100_0000
    static let byteCount: UInt32 = 206
    static let thePortOffset: UInt32 = 202
    static let publicPrefixLength: UInt32 = 126
    static let screenAddress: UInt32 = 0x3000_0000
    static let screenBounds = Rect(top: 0, left: 0, bottom: 480, right: 640)
    static let screenRowBytes = 80
    static let screenByteCount = screenRowBytes * 480

    /// Public globals from randSeed through thePort; the 76 private bytes are left alone.
    static func initialBytes() -> [UInt8] {
        var writer = BigEndianWriter(capacity: 130)
        writer.write(UInt32(1))
        writer.write(screenAddress)
        writer.write(UInt16(screenRowBytes))
        writer.write(screenBounds)
        writer.write(bytes: Cursor.arrow.curs)
        for pattern in [Pattern.darkGray, .lightGray, .gray, .black, .white] {
            writer.write(bytes: pattern.rows)
        }
        writer.write(UInt32(0)) // InitGraf leaves thePort nil until a port is opened.
        return writer.bytes
    }
}
