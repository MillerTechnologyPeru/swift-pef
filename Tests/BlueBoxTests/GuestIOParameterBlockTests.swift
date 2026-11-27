import CMORA
import Graphite
import Testing
@testable import BlueBox

@Suite struct GuestIOParameterBlockTests {
    private final class Guest {
        var runtime: ToolboxRuntime
        var memory: [UInt32: UInt8] = [:]
        var deniedWrite: UInt32?

        init() {
            let name = PascalString(bytes: Array("Fixture".utf8))
            runtime = ToolboxRuntime(files: [GuestFile(name: name, dataFork: [10, 20, 30, 40, 50])])
            put(0x100, GuestFileManager.bytes(FileSpec(volume: -100, parent: .root, name: name)))
            #expect(call("FSpOpenDF", [0x100, 1, 0x200]).returnGPR == 0)
        }

        func put(_ address: UInt32, _ bytes: [UInt8]) {
            for (index, byte) in bytes.enumerated() { memory[address + UInt32(index)] = byte }
        }
        func read(_ address: UInt32, _ count: Int) -> [UInt8]? {
            guard UInt64(address) + UInt64(count) <= 1 << 32 else { return nil }
            let bytes = (0..<count).compactMap { memory[address + UInt32($0)] }
            return bytes.count == count ? bytes : nil
        }
        func word(_ address: UInt32) -> UInt32 { GuestAppleEventDescriptors.word(read(address, 4) ?? [0, 0, 0, 0]) }
        func call(_ name: String, _ arguments: [UInt32], handled: Bool = true) -> MORAInvocationFrame {
            var frame = MORAInvocationFrame()
            withUnsafeMutableBytes(of: &frame.gpr) { bytes in
                let registers = bytes.bindMemory(to: UInt32.self)
                for (index, value) in arguments.enumerated() { registers[index] = value }
            }
            let result = runtime.dispatch(GuestImport(library: "InterfaceLib", symbol: name, symbolClass: .tVector),
                frame: &frame, readGuest: read, writeGuest: { address, bytes in
                    guard address != self.deniedWrite else { return false }
                    self.put(address, bytes)
                    return true
                })
            #expect(result == handled)
            return frame
        }
        func request(count: Int32, mode: UInt16 = 0, offset: Int32 = 0, reference: UInt16 = 128) {
            put(0x1000, [UInt8](repeating: 0xA5, count: 50))
            put(0x1018, [UInt8(reference >> 8), UInt8(truncatingIfNeeded: reference)])
            put(0x1020, GuestAppleEventDescriptors.word(0x2000))
            put(0x1024, GuestAppleEventDescriptors.word(UInt32(bitPattern: count)))
            put(0x102C, [UInt8(mode >> 8), UInt8(truncatingIfNeeded: mode)])
            put(0x102E, GuestAppleEventDescriptors.word(UInt32(bitPattern: offset)))
        }
        func position() -> UInt32 {
            #expect(call("GetFPos", [128, 0x3000]).returnGPR == 0)
            return word(0x3000)
        }
    }

    @Test func packedPositionedReadPreservesInputsAndIgnoresSyncCompletion() {
        let guest = Guest()
        guest.request(count: 2, mode: 1, offset: 1)
        let before = guest.read(0x1000, 50)
        #expect(guest.call("PBReadSync", [0x1000]).returnGPR == 0)
        #expect(guest.read(0x2000, 2) == [20, 30])
        #expect(guest.word(0x1028) == 2)
        #expect(guest.word(0x102E) == 3)
        #expect(guest.read(0x1010, 2) == [0, 0])
        #expect(guest.position() == 3)
        let after = guest.read(0x1000, 50)
        for index in 0..<50 where ![16, 17, 40, 41, 42, 43, 46, 47, 48, 49].contains(index) {
            #expect(before?[index] == after?[index])
        }
    }

    @Test func partialEOFAndZeroLengthReadReturnMatchingResults() {
        let guest = Guest()
        guest.request(count: 4, mode: 2, offset: -2)
        #expect(Int32(bitPattern: guest.call("PBRead", [0x1000, 0xFFFFFF00]).returnGPR) == -39)
        #expect(guest.read(0x1010, 2) == [0xFF, 0xD9])
        #expect(guest.word(0x1028) == 2)
        #expect(guest.word(0x102E) == 5)
        #expect(guest.read(0x2000, 2) == [40, 50])
        guest.request(count: 0, offset: Int32.max)
        guest.put(0x1020, [0xFF, 0xFF, 0xFF, 0xFF])
        #expect(guest.call("PBReadSync", [0x1000]).returnGPR == 0)
        #expect(guest.word(0x1028) == 0)
        #expect(guest.position() == 5)
    }

    @Test func normalErrorsUpdateResultAndClearActualCount() {
        for (count, mode, offset, reference, error): (Int32, UInt16, Int32, UInt16, Int32) in [
            (-1, 0, 0, 128, -50), (1, 1, -1, 128, -40), (1, 1, 6, 128, -39),
            (1, 0x40, 0, 128, -4), (1, 0, 0, 0xFFFF, -51)
        ] {
            let guest = Guest()
            guest.request(count: count, mode: mode, offset: offset, reference: reference)
            #expect(Int32(bitPattern: guest.call("PBReadSync", [0x1000]).returnGPR) == error)
            let bits = UInt16(truncatingIfNeeded: error)
            #expect(guest.read(0x1010, 2) == [UInt8(bits >> 8), UInt8(truncatingIfNeeded: bits)])
            #expect(guest.word(0x1028) == 0)
            #expect(guest.position() == 0)
        }
    }

    @Test func outputFaultsDoNotMoveTheFileMark() {
        for denied: UInt32 in [0x2000, 0x1028, 0x102E, 0x1010] {
            let guest = Guest()
            guest.request(count: 2, mode: 1, offset: 2)
            guest.deniedWrite = denied
            _ = guest.call("PBReadSync", [0x1000], handled: false)
            #expect(guest.runtime.guestMemoryFault == ToolboxMemoryFault(address: denied, write: true))
            guest.deniedWrite = nil
            #expect(guest.position() == 0)
        }
    }

    @Test func asynchronousAndInvalidBlocksStopExplicitly() {
        let guest = Guest()
        guest.request(count: 1)
        let before = guest.read(0x1000, 50)
        _ = guest.call("PBRead", [0x1000, 1], handled: false)
        #expect(guest.read(0x1000, 50) == before)
        #expect(guest.position() == 0)
        for address: UInt32 in [0, 0xFFFFFFF0] {
            _ = guest.call("PBReadSync", [address], handled: false)
            #expect(guest.runtime.guestMemoryFault == ToolboxMemoryFault(address: address, write: false))
        }
    }
}
