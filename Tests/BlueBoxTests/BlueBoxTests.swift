import Testing
import PPC32Core
@testable import BlueBox

@Suite struct BlueBoxTests {
    @Test func callbackVectorUsesTOCArgumentsAndBoundedExecution() throws {
        let memory = try GuestAddressSpace()
        try memory.commit(at: 0x10000, byteCount: 256)
        // lwz r5,0(r2); add r3,r3,r4; add r3,r3,r5; blr
        for (index, word) in [UInt32(0x80A20000), 0x7C632214, 0x7C632A14, 0x4E800020].enumerated() {
            memory.writeBigEndian(word, at: 0x10000 + UInt32(index * 4))
        }
        memory.writeBigEndian(UInt32(0x10000), at: 0x10020)
        memory.writeBigEndian(UInt32(0x10028), at: 0x10024)
        memory.writeBigEndian(UInt32(30), at: 0x10028)
        let regions = [PPC32MemoryRegion(address: 0x10000, byteCount: 16, writable: false, executable: true),
                       PPC32MemoryRegion(address: 0x10020, byteCount: 12, writable: false),
                       PPC32MemoryRegion(address: 0x10080, byteCount: 64, writable: true)]
        try regions.withUnsafeBufferPointer { regions in
            let result = try EmulatedPPCBackend.callVector(
                at: 0x10020, arguments: [7, 5], stackPointer: 0x10080,
                in: memory, maxInstructions: 8, memoryRegions: regions, dispatchImport: { _, _ in false })
            #expect(result.stop == .returned)
            #expect(result.r3 == 42)
            #expect(result.toc == 0x10028)
            #expect(memory.readBigEndian(UInt32.self, at: 0x10094) == 0x10028)
            let bounded = try EmulatedPPCBackend.callVector(
                at: 0x10020, arguments: [], stackPointer: 0x10080,
                in: memory, maxInstructions: 2, memoryRegions: regions, dispatchImport: { _, _ in false })
            #expect(bounded.stop == .instructionLimit)
            #expect(bounded.instructions == 2)
            for vector: UInt32 in [0, 0x10021, 0x10028, 0xFFFFFFFC] {
                #expect(throws: EmulatedPPCBackend.CallbackError.invalidVector) {
                    try EmulatedPPCBackend.callVector(at: vector, arguments: [], stackPointer: 0x10080,
                        in: memory, maxInstructions: 8, memoryRegions: regions, dispatchImport: { _, _ in false })
                }
            }
            #expect(throws: EmulatedPPCBackend.CallbackError.invalidStack) {
                try EmulatedPPCBackend.callVector(at: 0x10020, arguments: [], stackPointer: 0x10090,
                    in: memory, maxInstructions: 8, memoryRegions: regions, dispatchImport: { _, _ in false })
            }
            #expect(throws: EmulatedPPCBackend.CallbackError.tooManyArguments) {
                try EmulatedPPCBackend.callVector(at: 0x10020, arguments: Array(repeating: 0, count: 9), stackPointer: 0x10080,
                    in: memory, maxInstructions: 8, memoryRegions: regions, dispatchImport: { _, _ in false })
            }
        }
    }

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
