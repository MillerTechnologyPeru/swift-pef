import Graphite

/// Monochrome Window Manager port and its two region master pointers, packed for the guest ABI.
/// https://dev.os9.ca/techpubs/mac/Toolbox/Toolbox-222.html
enum GuestWindowManager {
    static let address: UInt32 = 0x2200_0000
    static let portByteCount = 108
    static let visibleHandle = address + 108
    static let clipHandle = address + 112
    static let visibleRegion = address + 116
    static let clipRegion = address + 126
    static let byteCount: UInt32 = 136

    static func initialBytes() -> [UInt8] {
        var writer = BigEndianWriter(capacity: Int(byteCount))
        writer.write(Int16(0)) // device
        writer.write(GuestQuickDrawGlobals.screenAddress)
        writer.write(UInt16(GuestQuickDrawGlobals.screenRowBytes))
        writer.write(GuestQuickDrawGlobals.screenBounds)
        writer.write(GuestQuickDrawGlobals.screenBounds) // portRect
        writer.write(visibleHandle)
        writer.write(clipHandle)
        writer.write(bytes: Pattern.white.rows) // bkPat
        writer.write(bytes: Pattern.black.rows) // fillPat
        writer.write(Point.zero) // pnLoc
        writer.write(Point(v: 1, h: 1)) // pnSize
        writer.write(Int16(8)) // patCopy
        writer.write(bytes: Pattern.black.rows) // pnPat
        writer.write(Int16(0)) // pnVis
        writer.write(Int16(0)) // txFont
        writer.write(UInt16(0)) // txFace plus alignment byte
        writer.write(Int16(1)) // srcOr
        writer.write(Int16(0)) // txSize: system default
        writer.write(UInt32(0)) // spExtra
        writer.write(Int32(33)) // blackColor
        writer.write(Int32(30)) // whiteColor
        writer.writeZeros(20) // colrBit, patStretch, picSave, rgnSave, polySave, grafProcs
        writer.write(visibleRegion) // visRgn master pointer
        writer.write(clipRegion) // clipRgn master pointer
        writer.write(UInt16(10))
        writer.write(GuestQuickDrawGlobals.screenBounds)
        writer.write(UInt16(10))
        writer.write(Rect(top: -32767, left: -32767, bottom: 32767, right: 32767))
        return writer.bytes
    }
}
