import CMORA
import Testing
@testable import BlueBox

@Suite struct GuestBlockMoveTests {
    @Test(arguments: ["BlockMove", "BlockMoveData", "BlockMoveUncached", "BlockMoveDataUncached"])
    func copiesOverlappingAndSeparateRanges(_ name: String) {
        for (source, destination) in [(0, 1), (1, 0), (0, 0), (0, 8)] {
            var memory = Array(UInt8(0)..<UInt8(16))
            let original = memory
            var frame = MORAInvocationFrame()
            withUnsafeMutableBytes(of: &frame.gpr) { bytes in
                let registers = bytes.bindMemory(to: UInt32.self)
                registers[0] = UInt32(source)
                registers[1] = UInt32(destination)
                registers[2] = 6
            }
            var runtime = ToolboxRuntime()
            let handled = runtime.dispatch(GuestImport(library: "InterfaceLib", symbol: name, symbolClass: .tVector),
                                           frame: &frame, readGuest: { address, count in
                Array(memory[Int(address)..<Int(address) + count])
            }, writeGuest: { address, bytes in
                memory.replaceSubrange(Int(address)..<Int(address) + bytes.count, with: bytes)
                return true
            })
            var expected = original
            expected.replaceSubrange(destination..<destination + 6, with: original[source..<source + 6])
            #expect(handled)
            #expect(memory == expected)
            #expect(runtime.handledImportCount == 1)
        }
    }

    @Test func zeroLengthDoesNotAccessEitherPointer() throws {
        var accesses = 0
        try GuestBlockMove.copy(source: UInt32.max, destination: 0, count: 0,
                                read: { _, _ in accesses += 1; return nil },
                                write: { _, _ in accesses += 1; return false })
        #expect(accesses == 0)
    }

    @Test func rejectsInvalidRangesAndTruncatedReadsBeforeWriting() {
        var accesses = 0
        for (source, destination, count, expected): (UInt32, UInt32, UInt32, ToolboxMemoryFault) in [
            (.max, 0, 2, ToolboxMemoryFault(address: .max, write: false)),
            (0, .max, 2, ToolboxMemoryFault(address: .max, write: true)),
            (0, 0, .max, ToolboxMemoryFault(address: 0, write: false))
        ] {
            #expect(throws: expected) {
                try GuestBlockMove.copy(source: source, destination: destination, count: count,
                                        read: { _, _ in accesses += 1; return [] },
                                        write: { _, _ in accesses += 1; return true })
            }
        }
        #expect(accesses == 0)
        #expect(throws: ToolboxMemoryFault(address: 100, write: false)) {
            try GuestBlockMove.copy(source: 100, destination: 200, count: 4,
                                    read: { _, _ in [1, 2] }, write: { _, _ in accesses += 1; return true })
        }
        #expect(accesses == 0)
        #expect(throws: ToolboxMemoryFault(address: 200, write: true)) {
            try GuestBlockMove.copy(source: 100, destination: 200, count: 4,
                                    read: { _, _ in [1, 2, 3, 4] }, write: { _, _ in false })
        }
    }
}
