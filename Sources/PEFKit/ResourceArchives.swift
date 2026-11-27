/// Zero-copy readers. Returned pointers borrow the supplied archive storage.
public enum AppleDoubleReader {
    public static func resourceFork(in bytes: UnsafeRawBufferPointer) throws(PEFError) -> UnsafeRawBufferPointer? {
        do throws(PEFError) {
            let file = ForkBytes(bytes: bytes)
            guard try file.u32(0) == 0x0005_1607 else { throw .malformedArchive }
            let version = try file.u32(4)
            guard version == 0x0001_0000 || version == 0x0002_0000 else { throw .malformedArchive }
            let count = Int(try file.u16(24))
            let tableEnd = 26 + count * 12
            _ = try file.slice(0, UInt64(tableEnd))
            var result: UnsafeRawBufferPointer?
            for index in 0..<count {
                let entry = 26 + index * 12
                let id = try file.u32(entry)
                let offset = UInt64(try file.u32(entry + 4))
                let length = UInt64(try file.u32(entry + 8))
                guard offset >= UInt64(tableEnd), id != 0, id != 1 else { throw .malformedArchive }
                let data = try file.slice(offset, length)
                if id == 2 {
                    guard result == nil else { throw .malformedArchive }
                    result = data
                }
            }
            return result
        } catch {
            throw .malformedArchive
        }
    }
}

public struct MacBinaryForks {
    public let name: UnsafeRawBufferPointer
    public let dataFork: UnsafeRawBufferPointer
    public let resourceFork: UnsafeRawBufferPointer
}

public enum MacBinaryReader {
    public static func parse(_ bytes: UnsafeRawBufferPointer) throws(PEFError) -> MacBinaryForks {
        do throws(PEFError) {
            let file = ForkBytes(bytes: bytes)
            _ = try file.slice(0, 128)
            guard bytes[0] == 0, (1...63).contains(bytes[1]), bytes[74] == 0, bytes[82] == 0 else {
                throw .malformedArchive
            }
            let version = bytes[122]
            // MacBinary I has no CRC or secondary header. II/III require their header CRC.
            guard version == 0 || version == 129 || version == 130 else { throw .malformedArchive }
            if version != 0 {
                guard try file.u16(124) == crc16(UnsafeRawBufferPointer(rebasing: bytes[0..<124])),
                      bytes[123] == 129 else { throw .malformedArchive }
                if version == 130 {
                    guard try file.u32(102) == 0x6D42_494E else { throw .malformedArchive }
                }
            }
            let secondary = version == 0 ? 0 : UInt64(try file.u16(120))
            let dataStart = (128 + secondary + 127) / 128 * 128
            let dataLength = UInt64(try file.u32(83))
            let resourceLength = UInt64(try file.u32(87))
            guard dataLength <= 0x7FFF_FFFF, resourceLength <= 0x7FFF_FFFF else {
                throw .malformedArchive
            }
            let resourceStart = (dataStart + dataLength + 127) / 128 * 128
            return MacBinaryForks(
                name: try file.slice(2, UInt64(bytes[1])),
                dataFork: try file.slice(dataStart, dataLength),
                resourceFork: try file.slice(resourceStart, resourceLength)
            )
        } catch {
            throw .malformedArchive
        }
    }

    private static func crc16(_ bytes: UnsafeRawBufferPointer) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 != 0 ? (crc &<< 1) ^ 0x1021 : crc &<< 1
            }
        }
        return crc
    }
}
