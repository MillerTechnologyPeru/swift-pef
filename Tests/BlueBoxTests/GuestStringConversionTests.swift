import CMORA
import Testing
@testable import BlueBox

@Suite struct GuestStringConversionTests {
    @Test(arguments: ["p2cstr", "P2CStr", "c2pstr", "C2PStr", "p2cstrcpy", "c2pstrcpy",
                      "CopyPascalStringToC", "CopyCStringToPascal"])
    func convertsAliasesWithCorrectArgumentOrderAndOverlap(_ name: String) {
        let toC = ["p2cstr", "P2CStr", "p2cstrcpy", "CopyPascalStringToC"].contains(name)
        let inPlace = ["p2cstr", "P2CStr", "c2pstr", "C2PStr"].contains(name)
        let destinationFirst = name == "p2cstrcpy" || name == "c2pstrcpy"
        let source: UInt32 = 32
        let destination: UInt32 = inPlace ? source : source + 1
        var memory = [UInt8](repeating: 0xCC, count: 512)
        let input: [UInt8] = toC ? [2, 0x8E, 65] : [0x8E, 65, 0]
        memory.replaceSubrange(32..<35, with: input)
        var frame = MORAInvocationFrame()
        withUnsafeMutableBytes(of: &frame.gpr) { bytes in
            let registers = bytes.bindMemory(to: UInt32.self)
            registers[0] = destinationFirst ? destination : source
            registers[1] = destinationFirst ? source : destination
        }
        var runtime = ToolboxRuntime()
        let handled = runtime.dispatch(GuestImport(library: "InterfaceLib", symbol: name, symbolClass: .tVector),
                                       frame: &frame, readGuest: { address, count in
            guard Int(address) <= memory.count, count <= memory.count - Int(address) else { return nil }
            return Array(memory[Int(address)..<Int(address) + count])
        }, writeGuest: { address, bytes in
            guard Int(address) <= memory.count, bytes.count <= memory.count - Int(address) else { return false }
            memory.replaceSubrange(Int(address)..<Int(address) + bytes.count, with: bytes)
            return true
        })
        #expect(handled)
        let expected: [UInt8] = toC ? [0x8E, 65, 0] : [2, 0x8E, 65]
        #expect(Array(memory[Int(destination)..<Int(destination) + expected.count]) == expected)
        #expect(memory[Int(destination) + expected.count] == 0xCC)
        if inPlace { #expect(frame.returnGPR == source) }
    }

    @Test func handlesEmptyAndMaximumLengthWithoutReadingBeyondLimit() throws {
        var output: [UInt8] = []
        try GuestStringConversion.pascalToC(source: 100, destination: 200, read: { _, _ in [0] },
                                           write: { _, bytes in output = bytes; return true })
        #expect(output == [0])
        try GuestStringConversion.cToPascal(source: 100, destination: 200, read: { _, _ in [0] },
                                           write: { _, bytes in output = bytes; return true })
        #expect(output == [0])
        var reads = 0
        try GuestStringConversion.cToPascal(source: 100, destination: 500, read: { address, count in
            #expect(address < 355)
            #expect(count == 1)
            reads += 1
            return [65]
        }, write: { _, bytes in output = bytes; return true })
        #expect(reads == 255)
        #expect(output == [255] + Array(repeating: 65, count: 255))
    }

    @Test func reportsReadAndWriteFaultsWithoutPartialWrites() {
        var writes = 0
        #expect(throws: ToolboxMemoryFault(address: 100, write: false)) {
            try GuestStringConversion.pascalToC(source: 100, destination: 200,
                read: { _, count in count == 1 ? [5] : nil },
                write: { _, _ in writes += 1; return true })
        }
        #expect(writes == 0)
        #expect(throws: ToolboxMemoryFault(address: 102, write: false)) {
            try GuestStringConversion.cToPascal(source: 100, destination: 200,
                read: { address, _ in address < 102 ? [65] : nil },
                write: { _, _ in writes += 1; return true })
        }
        #expect(writes == 0)
        #expect(throws: ToolboxMemoryFault(address: 200, write: true)) {
            try GuestStringConversion.pascalToC(source: 100, destination: 200,
                read: { _, _ in [0] }, write: { _, _ in false })
        }
    }

    @Test func rejectsAddressWraparound() {
        #expect(throws: ToolboxMemoryFault(address: UInt32.max, write: false)) {
            try GuestStringConversion.cToPascal(source: UInt32.max, destination: 200,
                                               read: { _, _ in [65] }, write: { _, _ in true })
        }
    }
}
