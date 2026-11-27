/// Version-seven Mixed Mode records for a single prepared, absolute PowerPC TVector.
/// The packed header is 12 bytes and the RoutineRecord is 20 bytes, all big-endian.
enum GuestRoutineDescriptor {
    static let byteCount = 32
    static let appleEventHandlerProcInfo: UInt32 = 0x00000FE0

    static func bytes(vector: UInt32, procInfo: UInt32) -> [UInt8] {
        typealias Coding = GuestAppleEventDescriptors
        return [0xAA, 0xFE, 7, 0] + [UInt8](repeating: 0, count: 8)
            + Coding.word(procInfo) + [0, 1, 0, 0] + Coding.word(vector)
            + [UInt8](repeating: 0, count: 8)
    }

    static func resolve(_ pointer: UInt32, expectedProcInfo: UInt32?,
                        read: (UInt32, Int) -> [UInt8]?) throws(GuestCallbackError) -> UInt32 {
        guard pointer != 0, pointer & 1 == 0, let prefix = read(pointer, 2), prefix.count == 2 else {
            throw .invalidVector
        }
        guard prefix == [0xAA, 0xFE] else {
            guard pointer & 3 == 0 else { throw .invalidVector }
            return pointer
        }
        guard let bytes = read(pointer, byteCount), bytes.count == byteCount else { throw .invalidVector }
        // Multi-record, relative, unprepared, selector-dispatched and 68k routines need other bridges.
        guard bytes[2] == 7, bytes[3..<12].allSatisfy({ $0 == 0 }),
              bytes[16] == 0, bytes[17] == 1, bytes[18] == 0,
              bytes[19] == 0 || bytes[19] == 4,
              bytes[24..<32].allSatisfy({ $0 == 0 }),
              expectedProcInfo == nil || GuestAppleEventDescriptors.word(bytes, 12) == expectedProcInfo else {
            throw .unsupportedRoutineDescriptor
        }
        let vector = GuestAppleEventDescriptors.word(bytes, 20)
        guard vector != 0, vector & 3 == 0 else { throw .invalidVector }
        return vector
    }
}
