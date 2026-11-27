import Graphite

/// Classic AEDesc records contain a big-endian type and guest Handle, never a host pointer.
/// Structured descriptors live in Graphite; their handle payload is intentionally opaque.
struct GuestAppleEventDescriptors {
    private struct Value {
        let descriptor: Descriptor
        let generation: UInt64?
    }
    private var values: [UInt32: Value] = [:]

    static func word(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    static func word(_ bytes: [UInt8], _ offset: Int = 0) -> UInt32 {
        bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func read(_ address: UInt32, count: Int, using read: (UInt32, Int) -> [UInt8]?) throws -> [UInt8] {
        guard let bytes = read(address, count), bytes.count == count else {
            throw ToolboxMemoryFault(address: address, write: false)
        }
        return bytes
    }

    static func write(_ address: UInt32, bytes: [UInt8], using write: (UInt32, [UInt8]) -> Bool) throws {
        guard write(address, bytes) else { throw ToolboxMemoryFault(address: address, write: true) }
    }

    func load(at address: UInt32, heap: inout GuestHeap,
              read: (UInt32, Int) -> [UInt8]?) throws -> Descriptor {
        let record = try Self.read(address, count: 8, using: read)
        let type = FourCharCode(Self.word(record))
        let handle = Self.word(record, 4)
        if type == DescriptorType.null, handle == 0 { return .null }
        guard let owned = values[handle], owned.generation == heap.handleGeneration(handle),
              owned.generation != nil, owned.descriptor.type == type else { throw MacError.notDescriptor }
        var value = owned.descriptor
        let size = heap.handleSize(handle)
        guard heap.lastError == 0 else { throw MacError.notDescriptor }
        if !value.isAppleEvent, !value.isList, !value.isKeyed {
            let master = try Self.read(handle, count: 4, using: read)
            value.bytes = size == 0 ? [] : try Self.read(Self.word(master), count: Int(size), using: read)
        }
        return value
    }

    mutating func store(_ value: Descriptor, at address: UInt32, heap: inout GuestHeap,
                        write: (UInt32, [UInt8]) -> Bool) throws {
        if value.isNull {
            try Self.write(address, bytes: Self.word(value.type.rawValue) + Self.word(0), using: write)
            return
        }
        let handle = heap.loadedHandle(bytes: value.bytes, write: write)
        if let fault = heap.memoryFault { throw fault }
        guard handle != 0 else { throw MacError(Int32(heap.lastError)) }
        do {
            try Self.write(address, bytes: Self.word(value.type.rawValue) + Self.word(handle), using: write)
        } catch {
            heap.disposeHandle(handle, write: write)
            throw error
        }
        values[handle] = Value(descriptor: value, generation: heap.handleGeneration(handle))
    }

    mutating func dispose(at address: UInt32, heap: inout GuestHeap,
                          read: (UInt32, Int) -> [UInt8]?, write: (UInt32, [UInt8]) -> Bool) throws {
        _ = try load(at: address, heap: &heap, read: read)
        let record = try Self.read(address, count: 8, using: read)
        let handle = Self.word(record, 4)
        // Validate the output before releasing ownership, so a protected record stays live.
        try Self.write(address, bytes: Self.word(DescriptorType.null.rawValue) + Self.word(0), using: write)
        if handle != 0 {
            heap.disposeHandle(handle, write: write)
            if let fault = heap.memoryFault { throw fault }
            values.removeValue(forKey: handle)
        }
    }

    /// Replace structured contents while preserving the guest record and master pointer.
    mutating func update(_ value: Descriptor, at address: UInt32, heap: inout GuestHeap,
                         read: (UInt32, Int) -> [UInt8]?) throws {
        let existing = try load(at: address, heap: &heap, read: read)
        guard existing.type == value.type, value.isList || value.isRecord else { throw MacError.wrongDataType }
        // Bound host-side trees as well as the guest heap. Copies can otherwise nest indefinitely.
        var remaining = 4096
        var remainingBytes = Int(GuestHeap.byteCount)
        func validate(_ descriptor: Descriptor, depth: Int) throws {
            guard depth <= 32, remaining > 0, descriptor.bytes.count <= remainingBytes else { throw MacError(-108) }
            remaining -= 1
            remainingBytes -= descriptor.bytes.count
            for item in descriptor.items { try validate(item.descriptor, depth: depth + 1) }
            for item in descriptor.attributes { try validate(item.descriptor, depth: depth + 1) }
        }
        try validate(value, depth: 0)
        let record = try Self.read(address, count: 8, using: read)
        let handle = Self.word(record, 4)
        values[handle] = Value(descriptor: value, generation: heap.handleGeneration(handle))
    }
}
