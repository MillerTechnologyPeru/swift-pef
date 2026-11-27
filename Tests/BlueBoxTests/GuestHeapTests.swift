import Testing
@testable import BlueBox

@Suite struct GuestHeapTests {
    @Test func boundsAllocationsAndCoalescesFreedRanges() {
        var heap = GuestHeap(capacity: 64)
        let a = heap.newPointer(size: 17, clear: false, write: { _, _ in true })
        let b = heap.newPointer(size: 32, clear: false, write: { _, _ in true })
        #expect(a == GuestHeap.address)
        #expect(b == a + 32)
        #expect(heap.pointerSize(a) == 17)
        #expect(heap.freeBytes == 0)
        #expect(heap.newPointer(size: 1, clear: false, write: { _, _ in true }) == 0)
        #expect(heap.lastError == -108)
        heap.disposePointer(a)
        heap.disposePointer(b)
        #expect(heap.freeBytes == 64)
        #expect(heap.newPointer(size: 64, clear: false, write: { _, _ in true }) == a)
    }

    @Test func clearsReusedPointersAndKeepsLogicalZeroSize() {
        var heap = GuestHeap(capacity: 64)
        let a = heap.newPointer(size: 12, clear: false, write: { _, _ in true })
        heap.disposePointer(a)
        var bytes: [UInt8] = []
        var destination: UInt32 = 0
        let b = heap.newPointer(size: 12, clear: true, write: { address, data in
            destination = address
            bytes = data
            return true
        })
        #expect(b == a)
        #expect(destination == a)
        #expect(bytes == Array(repeating: 0, count: 12))
        let zero = heap.newPointer(size: 0, clear: false, write: { _, _ in true })
        #expect(zero != 0)
        #expect(heap.pointerSize(zero) == 0)
        #expect(heap.lastError == 0)
    }

    @Test func handlesHaveBigEndianMasterPointersAndRecycle() {
        var heap = GuestHeap(capacity: 512)
        var writes: [UInt32: [UInt8]] = [:]
        let handle = heap.newHandle(size: 32, clear: true, write: { address, data in
            writes[address] = data
            return true
        })
        #expect(handle == GuestHeap.address)
        #expect(writes[handle] == [0x40, 0, 1, 0])
        #expect(writes[GuestHeap.address + 256] == Array(repeating: 0, count: 32))
        #expect(heap.handleSize(handle) == 32)
        #expect(heap.availableMasterPointers == 63)
        heap.disposeHandle(handle, write: { address, data in writes[address] = data; return true })
        #expect(writes[handle] == [0, 0, 0, 0])
        #expect(heap.availableMasterPointers == 64)
        #expect(heap.freeBytes == 256)
        let empty = heap.newHandle(size: 0, clear: false, write: { address, data in writes[address] = data; return true })
        #expect(empty == handle)
        #expect(writes[empty] == [0, 0, 0, 0])
        #expect(heap.handleSize(empty) == 0)
    }

    @Test func rejectsInvalidSizesAndWrongAllocationKinds() {
        var heap = GuestHeap(capacity: 512)
        #expect(heap.newPointer(size: -1, clear: false, write: { _, _ in true }) == 0)
        #expect(heap.lastError == -108)
        #expect(heap.newPointer(size: .max, clear: true, write: { _, _ in true }) == 0)
        #expect(heap.freeBytes == 512)
        let handle = heap.newHandle(size: 16, clear: false, write: { _, _ in true })
        heap.disposePointer(handle)
        #expect(heap.lastError == -111)
        #expect(heap.handleSize(handle) == 16)
        #expect(heap.pointerSize(GuestHeap.address + 256) == 0) // Handle data is not a NewPtr block.
        #expect(heap.lastError == -111)
        heap.disposeHandle(0, write: { _, _ in true })
        #expect(heap.lastError == -109)
    }

    @Test func moreMastersConsumesSpaceAndMaxApplZonePreservesLiveBlocks() {
        var heap = GuestHeap(capacity: 512)
        let pointer = heap.newPointer(size: 16, clear: false, write: { _, _ in true })
        heap.moreMasters(write: { _, _ in true })
        #expect(heap.availableMasterPointers == 64)
        #expect(heap.freeBytes == 240)
        heap.maximizeApplicationZone()
        #expect(heap.pointerSize(pointer) == 16)
        #expect(heap.freeBytes == 240)
    }

    @Test func failedWritesRollBackHeapStorage() {
        var heap = GuestHeap(capacity: 512)
        #expect(heap.newPointer(size: 64, clear: true, write: { _, _ in false }) == 0)
        #expect(heap.freeBytes == 512)
        #expect(heap.memoryFault == ToolboxMemoryFault(address: GuestHeap.address, write: true))
        var handles = GuestHeap(capacity: 512)
        // Permit master-block initialization and data clear, reject publishing the master pointer.
        #expect(handles.newHandle(size: 32, clear: true, write: { _, data in data.count != 4 }) == 0)
        #expect(handles.freeBytes == 256)
        #expect(handles.availableMasterPointers == 64)
        #expect(handles.memoryFault == ToolboxMemoryFault(address: GuestHeap.address, write: true))
    }

    @Test func growsMasterPoolAndDetectsDataExhaustion() {
        var heap = GuestHeap(capacity: 512)
        var handles: [UInt32] = []
        for _ in 0..<65 {
            handles.append(heap.newHandle(size: 0, clear: false, write: { _, _ in true }))
        }
        #expect(Set(handles).count == 65)
        #expect(!handles.contains(0))
        #expect(heap.availableMasterPointers == 63)
        #expect(heap.freeBytes == 0)
        #expect(heap.newHandle(size: 1, clear: false, write: { _, _ in true }) == 0)
        #expect(heap.lastError == -108)
        #expect(heap.availableMasterPointers == 63)
        #expect(heap.handleSize(handles[0]) == 0)
    }
}
