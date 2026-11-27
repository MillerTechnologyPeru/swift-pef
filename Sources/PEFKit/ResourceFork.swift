/// Checked byte access shared by the Foundation-free resource and archive parsers.
struct ForkBytes {
    let bytes: UnsafeRawBufferPointer

    func slice(_ offset: UInt64, _ length: UInt64) throws(PEFError) -> UnsafeRawBufferPointer {
        guard offset <= UInt64(bytes.count), length <= UInt64(bytes.count) - offset else {
            throw .malformedResourceFork
        }
        return UnsafeRawBufferPointer(rebasing: bytes[Int(offset)..<Int(offset + length)])
    }

    func u16(_ offset: Int) throws(PEFError) -> UInt16 {
        let value = try slice(UInt64(offset), 2)
        return UInt16(value[0]) << 8 | UInt16(value[1])
    }

    func u32(_ offset: Int) throws(PEFError) -> UInt32 {
        let value = try slice(UInt64(offset), 4)
        return UInt32(value[0]) << 24 | UInt32(value[1]) << 16
            | UInt32(value[2]) << 8 | UInt32(value[3])
    }
}

/// A resource's raw MacRoman name (without its Pascal length byte), attributes, and payload.
/// Pointers borrow the original resource fork; keep its backing storage alive and unchanged.
public struct ResourceEntry {
    public let type: UInt32
    public let id: Int16
    public let attributes: UInt8
    public let name: UnsafeRawBufferPointer?
    public let data: UnsafeRawBufferPointer
}

/// Validated zero-copy view of a classic Resource Manager fork.
/// Noncopyability does not extend the lifetime of the caller-owned bytes.
public struct ResourceFork: ~Copyable {
    private let view: ResourceForkView
    public var typeCount: Int { view.typeCount }
    public var attributes: UInt16 { view.attributes }

    public init(bytes: UnsafeRawBufferPointer) throws(PEFError) {
        view = try ResourceForkView(bytes: bytes)
    }

    public func type(at index: Int) throws(PEFError) -> UInt32 {
        try view.type(at: index)
    }

    public func resourceCount(atTypeIndex index: Int) throws(PEFError) -> Int {
        try view.resourceCount(atTypeIndex: index)
    }

    public func resource(atTypeIndex index: Int, resourceIndex: Int) throws(PEFError) -> ResourceEntry {
        try view.resource(atTypeIndex: index, resourceIndex: resourceIndex)
    }

    public func find(type: UInt32, id: Int16) throws(PEFError) -> ResourceEntry? {
        try view.find(type: type, id: id)
    }
}

private struct ResourceForkView {
    private let data: ForkBytes
    private let map: ForkBytes
    private let typeOffset: Int
    private let nameOffset: Int
    public let typeCount: Int
    public let attributes: UInt16

    public init(bytes: UnsafeRawBufferPointer) throws(PEFError) {
        let file = ForkBytes(bytes: bytes)
        let dataOffset = UInt64(try file.u32(0))
        let mapOffset = UInt64(try file.u32(4))
        let dataLength = UInt64(try file.u32(8))
        let mapLength = UInt64(try file.u32(12))
        guard dataOffset >= 16, mapOffset >= 16, mapLength >= 28,
              dataOffset + dataLength <= mapOffset || mapOffset + mapLength <= dataOffset else {
            throw .malformedResourceFork
        }
        data = ForkBytes(bytes: try file.slice(dataOffset, dataLength))
        map = ForkBytes(bytes: try file.slice(mapOffset, mapLength))
        attributes = try map.u16(22)
        typeOffset = Int(try map.u16(24))
        nameOffset = Int(try map.u16(26))
        guard typeOffset >= 28, nameOffset <= map.bytes.count else {
            throw .malformedResourceFork
        }
        let count = try map.u16(typeOffset)
        typeCount = count == 0xFFFF ? 0 : Int(count) + 1
        _ = try map.slice(UInt64(typeOffset + 2), UInt64(typeCount) * 8)
        guard nameOffset >= typeOffset + 2 + typeCount * 8 else { throw .malformedResourceFork }
        // Reference lists are contiguous in type order and end before the name list.
        var referenceEnd = typeOffset + 2 + typeCount * 8
        for index in 0..<typeCount {
            let count = try resourceCount(atTypeIndex: index)
            let referenceStart = typeOffset + Int(try map.u16(typeOffset + 2 + index * 8 + 6))
            guard referenceStart == referenceEnd, count <= (nameOffset - referenceEnd) / 12 else {
                throw .malformedResourceFork
            }
            referenceEnd += count * 12
            for resourceIndex in 0..<count {
                _ = try resource(atTypeIndex: index, resourceIndex: resourceIndex)
            }
        }
    }

    public func type(at index: Int) throws(PEFError) -> UInt32 {
        guard index >= 0, index < typeCount else { throw .malformedResourceFork }
        return try map.u32(typeOffset + 2 + index * 8)
    }

    public func resourceCount(atTypeIndex index: Int) throws(PEFError) -> Int {
        _ = try type(at: index)
        let count = try map.u16(typeOffset + 2 + index * 8 + 4)
        return count == 0xFFFF ? 0 : Int(count) + 1
    }

    public func resource(atTypeIndex index: Int, resourceIndex: Int) throws(PEFError) -> ResourceEntry {
        let type = try type(at: index)
        let count = try resourceCount(atTypeIndex: index)
        guard resourceIndex >= 0, resourceIndex < count else { throw .malformedResourceFork }
        let references = typeOffset + Int(try map.u16(typeOffset + 2 + index * 8 + 6))
        guard references >= typeOffset + 2 + typeCount * 8 else { throw .malformedResourceFork }
        let reference = references + resourceIndex * 12
        _ = try map.slice(UInt64(reference), 12)
        let id = Int16(bitPattern: try map.u16(reference))
        let nameIndex = try map.u16(reference + 2)
        let attributesAndOffset = try map.u32(reference + 4)
        let payloadOffset = Int(attributesAndOffset & 0x00FF_FFFF)
        let length = UInt64(try data.u32(payloadOffset))
        let payload = try data.slice(UInt64(payloadOffset) + 4, length)
        let name: UnsafeRawBufferPointer?
        if nameIndex == 0xFFFF {
            name = nil
        } else {
            let start = nameOffset + Int(nameIndex)
            let length = try map.slice(UInt64(start), 1)[0]
            name = try map.slice(UInt64(start + 1), UInt64(length))
        }
        return ResourceEntry(type: type, id: id, attributes: UInt8(attributesAndOffset >> 24),
                             name: name, data: payload)
    }

    public func find(type: UInt32, id: Int16) throws(PEFError) -> ResourceEntry? {
        for index in 0..<typeCount where try self.type(at: index) == type {
            for resourceIndex in 0..<(try resourceCount(atTypeIndex: index)) {
                let entry = try resource(atTypeIndex: index, resourceIndex: resourceIndex)
                if entry.id == id { return entry }
            }
        }
        return nil
    }
}
