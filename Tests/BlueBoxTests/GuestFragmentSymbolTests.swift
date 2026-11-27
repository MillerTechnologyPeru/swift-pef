import CMORA
import Testing
@testable import BlueBox

@Suite struct GuestFragmentSymbolTests {
    private final class Guest {
        var runtime: ToolboxRuntime
        var bytes: [UInt32: UInt8] = [:]
        var deniedWrite: UInt32?
        init(symbols: GuestFragmentSymbols? = nil) { runtime = ToolboxRuntime(fragmentSymbols: symbols) }
        func put(_ address: UInt32, _ data: [UInt8]) {
            for (index, byte) in data.enumerated() { bytes[address + UInt32(index)] = byte }
        }
        func read(_ address: UInt32, _ count: Int) -> [UInt8]? {
            guard UInt64(address) + UInt64(count) <= 1 << 32 else { return nil }
            let data = (0..<count).compactMap { bytes[address + UInt32($0)] }
            return data.count == count ? data : nil
        }
        func call(_ name: String, _ arguments: [UInt32], handled: Bool = true) -> UInt32 {
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
            return frame.returnGPR
        }
    }

    @Test func namesAreExactBytesAndOutputsUseGuestWidths() {
        let guest = Guest(symbols: GuestFragmentSymbols(symbols: [
            .init(name: [0x80, 0xFF], address: 0xFEDCBA98, symbolClass: 2)
        ]))
        guest.put(0x100, [2, 0x80, 0xFF])
        guest.put(0x204, [0xAA, 0xBB])
        #expect(guest.call("FindSymbol", [1, 0x100, 0x200, 0x204]) == 0)
        #expect(guest.read(0x200, 4) == [0xFE, 0xDC, 0xBA, 0x98])
        #expect(guest.read(0x204, 2) == [2, 0xBB])
        #expect(guest.call("CountSymbols", [1, 0x208]) == 0)
        #expect(guest.read(0x208, 4) == [0, 0, 0, 1])
        let empty = Guest(symbols: GuestFragmentSymbols(symbols: []))
        #expect(empty.call("CountSymbols", [1, 0x200]) == 0)
        #expect(empty.read(0x200, 4) == [0, 0, 0, 0])
    }

    @Test func missingSymbolsAndConnectionsPreserveOutputs() {
        let guest = Guest(symbols: GuestFragmentSymbols(symbols: [
            .init(name: Array("Name".utf8), address: 42, symbolClass: 1)
        ]))
        guest.put(0x100, [4] + Array("name".utf8))
        guest.put(0x200, [1, 2, 3, 4, 5])
        #expect(Int32(bitPattern: guest.call("FindSymbol", [1, 0x100, 0x200, 0x204])) == -2802)
        #expect(Int32(bitPattern: guest.call("FindSymbol", [0, 0xFFFFFFFF, 0x200, 0x204])) == -2801)
        #expect(guest.read(0x200, 5) == [1, 2, 3, 4, 5])
        let unprepared = Guest()
        #expect(Int32(bitPattern: unprepared.call("CountSymbols", [1, 0x200])) == -2801)
        #expect(unprepared.bytes.isEmpty)
    }

    @Test func invalidGuestNamesAndOutputsStopWithMemoryFaults() {
        for address: UInt32 in [0x100, 0x200, 0x204] {
            let guest = Guest(symbols: GuestFragmentSymbols(symbols: [
                .init(name: [65], address: 42, symbolClass: 1)
            ]))
            if address != 0x100 { guest.put(0x100, [1, 65]); guest.deniedWrite = address }
            _ = guest.call("FindSymbol", [1, 0x100, 0x200, 0x204], handled: false)
            #expect(guest.runtime.guestMemoryFault == ToolboxMemoryFault(address: address, write: address != 0x100))
            #expect(guest.runtime.handledImportCount == 0)
        }
    }
}
