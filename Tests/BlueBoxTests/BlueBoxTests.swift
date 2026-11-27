import Testing
@testable import BlueBox

@Suite struct BlueBoxTests {
    @Test func guestMemoryAndReturn() throws {
        let memory = try GuestAddressSpace()
        try memory.commit(at: 0x10000, byteCount: 8)
        memory.writeBigEndian(UInt32(0x3860002A), at: 0x10000) // li r3,42
        memory.writeBigEndian(UInt32(0x4E800020), at: 0x10004) // blr
        #expect(memory.hostPointer(for: 0x10000).load(as: UInt8.self) == 0x38)
        #expect(memory.readBigEndian(UInt32.self, at: 0x10000) == 0x3860002A)
        let result = EmulatedPPCBackend.call(
            codeAddress: 0x10000, toc: 0, stackPointer: 0,
            in: memory, maxInstructions: 4,
            dispatchImport: { _, _ in false }
        )
        #expect(result.result == .returnToHost)
        #expect(result.r3 == 42)
    }

    @Test func importDispatchAndReturn() throws {
        let memory = try GuestAddressSpace()
        var symbol: UInt32?
        let result = EmulatedPPCBackend.call(
            codeAddress: 0xF000001C, toc: 0, stackPointer: 0,
            in: memory, maxInstructions: 4,
            dispatchImport: { index, frame in
                symbol = index
                frame.returnGPR = 123
                frame.returnFPR = 1.5
                return true
            }
        )
        #expect(symbol == 7)
        #expect(result.result == .returnToHost)
        #expect(result.r3 == 123)
        #expect(result.f1 == 1.5)
    }

    @Test func invalidRanges() throws {
        let memory = try GuestAddressSpace()
        #expect(throws: BlueBoxError.self) {
            try memory.commit(at: 0xF0000000, byteCount: 4)
        }
        #expect(throws: BlueBoxError.self) {
            try memory.commit(at: 0xEFFFFFFF, byteCount: 2)
        }
        #expect(throws: BlueBoxError.self) {
            try memory.commit(at: 0, byteCount: 0)
        }
    }
}
