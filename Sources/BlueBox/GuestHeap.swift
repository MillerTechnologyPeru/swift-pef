/// Bounded first-fit application heap. Metadata stays on the host; payloads and master pointers are guest addresses.
/// Blocks do not move yet. Resizing, purging, grow-zone callbacks and system zones are unsupported.
struct GuestHeap {
    static let address: UInt32 = 0x4000_0000
    static let byteCount: UInt32 = 16 * 1024 * 1024

    private struct Range {
        var address: UInt32
        var length: UInt32
    }
    private enum Kind { case pointer, handleData, masters }
    private struct Block {
        let size: Int32
        let span: UInt32
        let kind: Kind
    }
    private var free: [Range]
    private var blocks: [UInt32: Block] = [:]
    private var handles: [UInt32: UInt32] = [:]
    private var masters: [UInt32] = []
    private var handleGenerations: [UInt32: UInt64] = [:]
    private var nextHandleGeneration: UInt64 = 0
    func handleGeneration(_ handle: UInt32) -> UInt64? { handleGenerations[handle] }
    private(set) var lastError: Int16 = 0
    private(set) var memoryFault: ToolboxMemoryFault?
    var freeBytes: UInt32 { free.reduce(0) { $0 + $1.length } }
    var availableMasterPointers: Int { masters.count }

    init(capacity: UInt32 = Self.byteCount) {
        free = capacity == 0 ? [] : [Range(address: Self.address, length: min(capacity, Self.byteCount))]
    }

    /// The fixed application zone is already committed to its limit; expansion cannot purge live blocks.
    mutating func maximizeApplicationZone() { lastError = 0 }

    mutating func moreMasters(write: (UInt32, [UInt8]) -> Bool) {
        let address = allocate(size: 256, kind: .masters)
        guard address != 0 else { return }
        guard write(address, [UInt8](repeating: 0, count: 256)) else {
            release(address)
            memoryFault = ToolboxMemoryFault(address: address, write: true)
            return
        }
        masters.append(contentsOf: (0..<64).reversed().map { address + UInt32($0 * 4) })
    }

    mutating func newPointer(size: Int32, clear: Bool, write: (UInt32, [UInt8]) -> Bool) -> UInt32 {
        let pointer = allocate(size: size, kind: .pointer)
        guard pointer != 0 else { return 0 }
        if clear, size > 0, !write(pointer, [UInt8](repeating: 0, count: Int(size))) {
            release(pointer)
            memoryFault = ToolboxMemoryFault(address: pointer, write: true)
            return 0
        }
        return pointer
    }

    mutating func newHandle(size: Int32, clear: Bool, write: (UInt32, [UInt8]) -> Bool) -> UInt32 {
        guard size >= 0 else { lastError = -108; return 0 }
        if masters.isEmpty { moreMasters(write: write) }
        guard memoryFault == nil, let handle = masters.last else { return 0 }
        let pointer = size == 0 ? 0 : allocate(size: size, kind: .handleData)
        guard size == 0 || pointer != 0 else { return 0 }
        if clear, size > 0, !write(pointer, [UInt8](repeating: 0, count: Int(size))) {
            release(pointer)
            memoryFault = ToolboxMemoryFault(address: pointer, write: true)
            return 0
        }
        let bytes = [UInt8(pointer >> 24), UInt8(truncatingIfNeeded: pointer >> 16),
                     UInt8(truncatingIfNeeded: pointer >> 8), UInt8(truncatingIfNeeded: pointer)]
        guard write(handle, bytes) else {
            if pointer != 0 { release(pointer) }
            memoryFault = ToolboxMemoryFault(address: handle, write: true)
            return 0
        }
        masters.removeLast()
        handles[handle] = pointer
        nextHandleGeneration += 1
        handleGenerations[handle] = nextHandleGeneration
        lastError = 0
        return handle
    }

    mutating func disposePointer(_ pointer: UInt32) {
        guard blocks[pointer]?.kind == .pointer else { lastError = -111; return }
        release(pointer)
        lastError = 0
    }

    /// Create a loaded handle without exposing a partially populated resource to the guest.
    mutating func loadedHandle(bytes: [UInt8], write: (UInt32, [UInt8]) -> Bool) -> UInt32 {
        guard bytes.count <= Int32.max else { lastError = -108; return 0 }
        let handle = newHandle(size: Int32(bytes.count), clear: false, write: write)
        guard handle != 0, let pointer = handles[handle] else { return 0 }
        if !bytes.isEmpty, !write(pointer, bytes) {
            disposeHandle(handle, write: write)
            memoryFault = ToolboxMemoryFault(address: pointer, write: true)
            return 0
        }
        return handle
    }

    mutating func disposeHandle(_ handle: UInt32, write: (UInt32, [UInt8]) -> Bool) {
        guard let pointer = handles[handle] else { lastError = handle == 0 ? -109 : -111; return }
        guard write(handle, [0, 0, 0, 0]) else {
            memoryFault = ToolboxMemoryFault(address: handle, write: true)
            return
        }
        if pointer != 0 { release(pointer) }
        handles.removeValue(forKey: handle)
        handleGenerations.removeValue(forKey: handle)
        masters.append(handle)
        lastError = 0
    }

    mutating func pointerSize(_ pointer: UInt32) -> Int32 {
        guard let block = blocks[pointer], block.kind == .pointer else { lastError = -111; return 0 }
        lastError = 0
        return block.size
    }

    mutating func handleSize(_ handle: UInt32) -> Int32 {
        guard let pointer = handles[handle] else { lastError = handle == 0 ? -109 : -111; return 0 }
        lastError = 0
        return pointer == 0 ? 0 : blocks[pointer]?.size ?? 0
    }

    private mutating func allocate(size: Int32, kind: Kind) -> UInt32 {
        guard size >= 0 else { lastError = -108; return 0 }
        let span = (UInt32(max(1, size)) + 15) / 16 * 16
        guard let index = free.firstIndex(where: { $0.length >= span }) else { lastError = -108; return 0 }
        let address = free[index].address
        free[index].address += span
        free[index].length -= span
        if free[index].length == 0 { free.remove(at: index) }
        blocks[address] = Block(size: size, span: span, kind: kind)
        lastError = 0
        return address
    }

    private mutating func release(_ address: UInt32) {
        guard let block = blocks.removeValue(forKey: address) else { return }
        free.append(Range(address: address, length: block.span))
        free.sort { $0.address < $1.address }
        var merged: [Range] = []
        for range in free {
            if let last = merged.last, last.address + last.length == range.address {
                merged[merged.count - 1].length += range.length
            } else {
                merged.append(range)
            }
        }
        free = merged
    }
}
