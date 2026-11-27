/// Guest master pointer for TextEdit's initial, empty private scrap.
/// An empty handle is non-null, with a null data pointer; no host pointers enter guest memory.
/// https://leopard-adc.pepas.com/documentation/mac/Text/Text-50.html
enum GuestTextEdit {
    static let scrapHandle: UInt32 = 0x2300_0000
    static let byteCount: UInt32 = 4
    static let initialBytes: [UInt8] = [0, 0, 0, 0]
}
