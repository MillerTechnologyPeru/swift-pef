import CMORA
import Graphite
import PPC32Core
import Testing
@testable import BlueBox

@Suite struct GuestAppleEventDescriptorTests {
    private final class Memory {
        var bytes: [UInt32: UInt8] = [:]
        var deniedWrite: UInt32?
        func read(_ address: UInt32, _ count: Int) -> [UInt8]? {
            guard count >= 0, UInt64(address) + UInt64(count) <= 1 << 32 else { return nil }
            var result: [UInt8] = []
            for index in 0..<count {
                guard let byte = bytes[address + UInt32(index)] else { return nil }
                result.append(byte)
            }
            return result
        }
        func write(_ address: UInt32, _ value: [UInt8]) -> Bool {
            guard address != deniedWrite else { return false }
            for (index, byte) in value.enumerated() { bytes[address + UInt32(index)] = byte }
            return true
        }
        func word(_ address: UInt32) -> UInt32 { GuestAppleEventDescriptors.word(read(address, 4) ?? [0, 0, 0, 0]) }
    }

    private func call(_ name: String, _ arguments: [UInt32], _ runtime: inout ToolboxRuntime,
                      _ memory: Memory) -> UInt32 {
        var frame = MORAInvocationFrame()
        withUnsafeMutableBytes(of: &frame.gpr) { bytes in
            let registers = bytes.bindMemory(to: UInt32.self)
            for (index, argument) in arguments.enumerated() { registers[index] = argument }
        }
        #expect(runtime.dispatch(GuestImport(library: "InterfaceLib", symbol: name, symbolClass: .tVector),
                                 frame: &frame, readGuest: memory.read, writeGuest: memory.write))
        return frame.returnGPR
    }

    @Test func descriptorCopiesGuestBytesAndDisposesToNull() {
        var runtime = ToolboxRuntime()
        let memory = Memory()
        _ = memory.write(0x100, [0x12, 0x34, 0x56, 0x78])
        #expect(call("AECreateDesc", [0x6C6F6E67, 0x100, 4, 0x200], &runtime, memory) == 0)
        #expect(memory.word(0x200) == 0x6C6F6E67)
        let handle = memory.word(0x204)
        #expect(handle >= GuestHeap.address)
        #expect(memory.read(memory.word(handle), 4) == [0x12, 0x34, 0x56, 0x78])
        _ = memory.write(0x100, [0, 0, 0, 0])
        #expect(call("AEDuplicateDesc", [0x200, 0x208], &runtime, memory) == 0)
        #expect(memory.word(0x20C) != handle)
        #expect(call("AEDisposeDesc", [0x200], &runtime, memory) == 0)
        #expect(memory.read(0x200, 8) == Array("null".utf8) + [0, 0, 0, 0])
        #expect(call("AEDisposeDesc", [0x200], &runtime, memory) == 0)
        #expect(call("AEGetDescDataSize", [0x208], &runtime, memory) == 4)
        #expect(call("AEGetDescData", [0x208, 0x300, 2], &runtime, memory) == 0)
        #expect(memory.read(0x300, 2) == [0x12, 0x34])
    }

    @Test func nullEmptyInvalidAndRecycledDescriptors() {
        var runtime = ToolboxRuntime()
        let memory = Memory()
        #expect(call("AECreateDesc", [0x6E756C6C, 0xFFFFFFFF, 0, 0x200], &runtime, memory) == 0)
        #expect(memory.word(0x204) == 0)
        #expect(call("AECreateDesc", [0x54455854, 0xFFFFFFFF, 0, 0x208], &runtime, memory) == 0)
        #expect(memory.word(0x20C) != 0)
        #expect(call("AEGetDescData", [0x208, 0xFFFFFFFF, 0], &runtime, memory) == 0)
        #expect(Int32(bitPattern: call("AECreateDesc", [0x54455854, 0, 0xFFFFFFFF, 0x210], &runtime, memory)) == -50)
        let handle = memory.word(0x20C)
        #expect(call("DisposeHandle", [handle], &runtime, memory) == 0)
        #expect(call("NewEmptyHandle", [], &runtime, memory) == handle)
        #expect(Int32(bitPattern: call("AEGetDescDataSize", [0x208], &runtime, memory)) == -1704)
    }

    @Test func creationRollsBackAllocationOnProtectedOutput() throws {
        var heap = GuestHeap()
        var descriptors = GuestAppleEventDescriptors()
        let memory = Memory()
        heap.moreMasters(write: memory.write)
        let free = heap.freeBytes
        let masters = heap.availableMasterPointers
        memory.deniedWrite = 0x200
        #expect(throws: ToolboxMemoryFault(address: 0x200, write: true)) {
            try descriptors.store(Descriptor(type: "TEXT", bytes: [1, 2]), at: 0x200,
                                  heap: &heap, write: memory.write)
        }
        #expect(heap.freeBytes == free)
        #expect(heap.availableMasterPointers == masters)
    }

    @Test func attributesUseGuestByteOrderAndMissingParametersReturnErrors() {
        var runtime = ToolboxRuntime()
        let memory = Memory()
        #expect(call("AECreateDesc", [0x6E756C6C, 0, 0, 0x200], &runtime, memory) == 0)
        #expect(call("AECreateAppleEvent", [0x61657674, 0x6F617070, 0x200, 0x1234, 0x89ABCDEF, 0x208], &runtime, memory) == 0)
        for (keyword, expected): (UInt32, [UInt8]) in [
            (0x6576636C, Array("aevt".utf8)), (0x65766964, Array("oapp".utf8)),
            (0x72746964, [0x12, 0x34]), (0x7472616E, [0x89, 0xAB, 0xCD, 0xEF])
        ] {
            #expect(call("AEGetAttributeDesc", [0x208, keyword, 0x2A2A2A2A, 0x220], &runtime, memory) == 0)
            #expect(call("AEGetDescData", [0x220, 0x300, 4], &runtime, memory) == 0)
            #expect(memory.read(0x300, expected.count) == expected)
            #expect(call("AEDisposeDesc", [0x220], &runtime, memory) == 0)
        }
        #expect(call("AEGetAttributePtr", [0x208, 0x65766964, 0x74797065, 0x310, 0x320, 2, 0x314], &runtime, memory) == 0)
        #expect(memory.word(0x310) == 0x74797065)
        #expect(memory.word(0x314) == 4)
        #expect(memory.read(0x320, 2) == Array("oa".utf8))
        #expect(Int32(bitPattern: call("AEGetParamDesc", [0x208, 0x2D2D2D2D, 0x2A2A2A2A, 0x220], &runtime, memory)) == -1701)
        #expect(Int32(bitPattern: call("AEGetAttributeDesc", [0x208, 0x65766964, 0x54455854, 0x220], &runtime, memory)) == -1700)
    }

    @Test func launchEventPeekMaskAndSingleDelivery() {
        var runtime = ToolboxRuntime(ticks: { 42 })
        let memory = Memory()
        #expect(call("EventAvail", [0x0400, 0x100], &runtime, memory) == 1)
        let record = memory.read(0x100, 16)
        #expect(record == [0, 23] + Array("aevt".utf8) + [0, 0, 0, 42] + Array("oapp".utf8) + [0, 0])
        #expect(call("GetNextEvent", [0, 0x100], &runtime, memory) == 0)
        #expect(call("GetNextEvent", [0x0400, 0x100], &runtime, memory) == 1)
        #expect(Int32(bitPattern: call("AEProcessAppleEvent", [0x100], &runtime, memory)) == -1708)
        #expect(call("GetNextEvent", [0xFFFF, 0x100], &runtime, memory) == 0)
        #expect(GuestGestalt.makeTable()["evnt"] == nil)
    }

    @Test func deliveryOwnsBorrowedDescriptorsUntilCallbackCompletion() throws {
        var runtime = ToolboxRuntime(ticks: { 1 })
        let memory = Memory()
        _ = call("MoreMasters", [], &runtime, memory)
        let free = runtime.heap.freeBytes
        let masters = runtime.heap.availableMasterPointers
        try runtime.appleEventHandlers.install(eventClass: 0x61657674, eventID: 0x6F617070,
                                               procedure: 0x1000, referenceConstant: 0xFFFFFFFF, isSystem: false)
        #expect(call("GetNextEvent", [0x0400, 0x100], &runtime, memory) == 1)
        #expect(call("AEProcessAppleEvent", [0x100], &runtime, memory) == 0)
        let pending = runtime.takeAppleEventCallback()
        let callback = try #require(pending)
        #expect(callback.vector == 0x1000)
        #expect(callback.arguments.count == 3)
        #expect(callback.arguments[2] == 0xFFFFFFFF)
        #expect(memory.word(callback.arguments[0]) == 0x61657674)
        #expect(memory.word(callback.arguments[1]) == 0x61657674)
        #expect(call("AEGetAttributePtr", [callback.arguments[0], 0x65766964, 0x2A2A2A2A,
                                          0x200, 0x208, 4, 0x204], &runtime, memory) == 0)
        #expect(memory.read(0x208, 4) == Array("oapp".utf8))
        #expect(Int32(bitPattern: call("AEProcessAppleEvent", [0x100], &runtime, memory)) == -4)
        runtime.completeAppleEventCallback(read: memory.read, write: memory.write)
        #expect(runtime.heap.freeBytes == free)
        #expect(runtime.heap.availableMasterPointers == masters)
        let completed = runtime.takeAppleEventCallback()
        #expect(completed == nil)
        #expect(Int32(bitPattern: call("AEProcessAppleEvent", [0x100], &runtime, memory)) == -1708)
    }

    @Test func invalidGuestReadsStopWithMemoryDiagnostics() {
        var runtime = ToolboxRuntime()
        let memory = Memory()
        var frame = MORAInvocationFrame()
        withUnsafeMutableBytes(of: &frame.gpr) { bytes in
            let registers = bytes.bindMemory(to: UInt32.self)
            registers[0] = 0x54455854
            registers[1] = 0xDEADBEEF
            registers[2] = 4
            registers[3] = 0x200
        }
        #expect(!runtime.dispatch(GuestImport(library: "InterfaceLib", symbol: "AECreateDesc", symbolClass: .tVector),
                                  frame: &frame, readGuest: memory.read, writeGuest: memory.write))
        #expect(runtime.guestMemoryFault == ToolboxMemoryFault(address: 0xDEADBEEF, write: false))
        #expect(memory.read(0x200, 8) == Array("null".utf8) + [0, 0, 0, 0])
        #expect(runtime.handledImportCount == 0)
    }

    @Test func listsCopyItemsPreserveIdentityAndUseOneBasedIndices() {
        var runtime = ToolboxRuntime()
        let memory = Memory()
        #expect(call("AECreateList", [0xFFFFFFFF, 0, 0xFFFFFF00, 0x100], &runtime, memory) == 0)
        #expect(memory.word(0x100) == 0x6C697374)
        let handle = memory.word(0x104)
        _ = memory.write(0x200, [1, 2, 3])
        #expect(call("AECreateDesc", [0x54455854, 0x200, 3, 0x108], &runtime, memory) == 0)
        #expect(call("AEPutDesc", [0x100, 0, 0x108], &runtime, memory) == 0)
        #expect(call("AEDisposeDesc", [0x108], &runtime, memory) == 0)
        _ = memory.write(0x200, [4, 5])
        #expect(call("AEPutPtr", [0x100, 2, 0x54455854, 0x200, 2], &runtime, memory) == 0)
        #expect(memory.word(0x104) == handle)
        #expect(call("AECountItems", [0x100, 0x220], &runtime, memory) == 0)
        #expect(memory.word(0x220) == 2)
        #expect(call("AEGetNthDesc", [0x100, 1, 0x2A2A2A2A, 0x224, 0x108], &runtime, memory) == 0)
        #expect(memory.word(0x224) == 0)
        #expect(call("AEGetDescData", [0x108, 0x230, 3], &runtime, memory) == 0)
        #expect(memory.read(0x230, 3) == [1, 2, 3])
        #expect(call("AEDuplicateDesc", [0x100, 0x110], &runtime, memory) == 0)
        #expect(call("AEDeleteItem", [0x100, 1], &runtime, memory) == 0)
        #expect(call("AECountItems", [0x110, 0x220], &runtime, memory) == 0)
        #expect(memory.word(0x220) == 2)
        #expect(call("AECountItems", [0x100, 0x220], &runtime, memory) == 0)
        #expect(memory.word(0x220) == 1)
        #expect(call("AEPutPtr", [0x100, 1, 0x54455854, 0x200, 2], &runtime, memory) == 0)
        #expect(call("AECountItems", [0x100, 0x220], &runtime, memory) == 0)
        #expect(memory.word(0x220) == 1)
    }

    @Test func invalidListRequestsReturnErrorsWithoutChangingContents() {
        var runtime = ToolboxRuntime()
        let memory = Memory()
        #expect(call("AECreateList", [0, 0, 1, 0x100], &runtime, memory) == 0)
        #expect(memory.word(0x100) == 0x7265636F)
        #expect(call("AECountItems", [0x100, 0x200], &runtime, memory) == 0)
        #expect(memory.word(0x200) == 0)
        #expect(call("AEDisposeDesc", [0x100], &runtime, memory) == 0)
        #expect(Int32(bitPattern: call("AECreateList", [0, 1, 0, 0x100], &runtime, memory)) == -4)
        #expect(memory.word(0x100) == 0x6E756C6C)
        #expect(Int32(bitPattern: call("AECreateList", [0, 0xFFFFFFFF, 0, 0x100], &runtime, memory)) == -50)
        #expect(call("AECreateList", [0, 0, 0, 0x100], &runtime, memory) == 0)
        for index: UInt32 in [0, 1, 0xFFFFFFFF] {
            #expect(Int32(bitPattern: call("AEDeleteItem", [0x100, index], &runtime, memory)) == -1719)
        }
        #expect(Int32(bitPattern: call("AEPutPtr", [0x100, 2, 0x54455854, 0xFFFFFFFF, 0], &runtime, memory)) == -1719)
        #expect(Int32(bitPattern: call("AEGetNthDesc", [0x100, 1, 0x2A2A2A2A, 0, 0x108], &runtime, memory)) == -1719)
        #expect(call("AECountItems", [0x100, 0x200], &runtime, memory) == 0)
        #expect(memory.word(0x200) == 0)
    }

    @Test func nestedListLimitRejectsMutationAndRetainsTheLastValidTree() {
        var runtime = ToolboxRuntime()
        let memory = Memory()
        #expect(call("AECreateList", [0, 0, 0, 0x100], &runtime, memory) == 0)
        for _ in 0..<32 { #expect(call("AEPutDesc", [0x100, 1, 0x100], &runtime, memory) == 0) }
        #expect(Int32(bitPattern: call("AEPutDesc", [0x100, 1, 0x100], &runtime, memory)) == -108)
        #expect(call("AECountItems", [0x100, 0x200], &runtime, memory) == 0)
        #expect(memory.word(0x200) == 1)
        #expect(call("AEDisposeDesc", [0x100], &runtime, memory) == 0)
    }

    @Test func routineDescriptorAllocationLayoutAndDisposal() {
        var runtime = ToolboxRuntime()
        let memory = Memory()
        let free = runtime.heap.freeBytes
        #expect(call("GetCurrentISA", [], &runtime, memory) == 1)
        #expect(call("NewRoutineDescriptor", [0, 0xFE0, 1], &runtime, memory) == 0)
        #expect(runtime.heap.freeBytes == free)
        let pointer = call("NewRoutineDescriptor", [0x01002000, 0xFE0, 0xFFFFFF01], &runtime, memory)
        #expect(pointer != 0)
        #expect(memory.read(pointer, 32) == [0xAA, 0xFE, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0x0F, 0xE0, 0, 1, 0, 0, 1, 0, 0x20, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(call("GetPtrSize", [pointer], &runtime, memory) == 32)
        _ = call("DisposeRoutineDescriptor", [pointer], &runtime, memory)
        #expect(runtime.heap.freeBytes == free)
        let unrelated = call("NewPtr", [32], &runtime, memory)
        #expect(unrelated == pointer)
        _ = call("DisposeRoutineDescriptor", [pointer], &runtime, memory)
        #expect(call("GetPtrSize", [unrelated], &runtime, memory) == 32)
        let direct = call("NewRoutineDescriptor", [0x01002000, 0xFE0, 1], &runtime, memory)
        _ = call("DisposePtr", [direct], &runtime, memory)
        let reused = call("NewPtr", [32], &runtime, memory)
        #expect(reused == direct)
        _ = call("DisposeRoutineDescriptor", [direct], &runtime, memory)
        #expect(call("GetPtrSize", [reused], &runtime, memory) == 32)
    }

    @Test func routineDescriptorDecoderRejectsUnsupportedForms() throws {
        let memory = Memory()
        let bytes = GuestRoutineDescriptor.bytes(vector: 0x1000, procInfo: 0xFE0)
        _ = memory.write(0x200, bytes)
        #expect(try GuestRoutineDescriptor.resolve(0x200, expectedProcInfo: 0xFE0, read: memory.read) == 0x1000)
        #expect(throws: GuestCallbackError.unsupportedRoutineDescriptor) {
            try GuestRoutineDescriptor.resolve(0x200, expectedProcInfo: 0x1234, read: memory.read)
        }
        for (offset, value): (Int, UInt8) in [(2, 6), (3, 1), (11, 1), (17, 0), (19, 1), (19, 2), (28, 1)] {
            var invalid = bytes
            invalid[offset] = value
            _ = memory.write(0x200, invalid)
            #expect(throws: GuestCallbackError.unsupportedRoutineDescriptor) {
                try GuestRoutineDescriptor.resolve(0x200, expectedProcInfo: 0xFE0, read: memory.read)
            }
        }
        _ = memory.write(0x200, [0xAA, 0xFE])
        #expect(throws: GuestCallbackError.invalidVector) {
            try GuestRoutineDescriptor.resolve(0x200, expectedProcInfo: nil, read: { address, count in
                count <= 2 ? memory.read(address, count) : nil
            })
        }
        _ = memory.write(0x200, [1, 0, 0, 0])
        #expect(try GuestRoutineDescriptor.resolve(0x200, expectedProcInfo: nil, read: memory.read) == 0x200)
    }
}
