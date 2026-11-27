import CMORA
import Graphite
import Testing
@testable import BlueBox

@Suite struct ResourceRuntimeTests {
    private let call = GuestImport(library: "InterfaceLib", symbol: "GetIndString", symbolClass: .tVector)
    private let errorCall = GuestImport(library: "InterfaceLib", symbol: "ResError", symbolClass: .tVector)

    private func runtime(payload: [UInt8] = [0, 2, 1, 0x8E, 2, 65, 66]) throws -> ToolboxRuntime {
        let file = try ResourceFile(bytes: ResourceMap.write([
            (resource: Resource(type: "STR#", id: -7), bytes: payload)
        ]))
        return ToolboxRuntime(resources: file)
    }

    private func frame(id: UInt32 = 0xFFFFFFF9, index: UInt32 = 1) -> MORAInvocationFrame {
        var frame = MORAInvocationFrame()
        withUnsafeMutableBytes(of: &frame.gpr) { bytes in
            let registers = bytes.bindMemory(to: UInt32.self)
            registers[0] = 0x01000000
            registers[1] = id
            registers[2] = index
        }
        return frame
    }

    @Test func copiesIndexedMacRomanStringWithSignedResourceID() throws {
        var runtime = try runtime()
        var frame = frame()
        var result: [UInt8] = []
        let handled = runtime.dispatch(call, frame: &frame, writeGuest: { address, bytes in
            #expect(address == 0x01000000)
            result = bytes
            return true
        })
        #expect(handled)
        #expect(result == [1, 0x8E])
        #expect(runtime.dispatch(errorCall, frame: &frame))
        #expect(frame.returnGPR == 0)
    }

    @Test func missingAndOutOfRangeStringsAreEmpty() throws {
        for index: UInt32 in [0, 3, 0xFFFFFFFF] {
            var runtime = try runtime()
            var frame = frame(index: index)
            var output: [UInt8] = [255]
            #expect(runtime.dispatch(call, frame: &frame, writeGuest: { _, bytes in output = bytes; return true }))
            #expect(output == [0])
            #expect(runtime.lastResourceError == 0)
        }
        var runtime = try runtime()
        var frame = frame(id: 123)
        var output: [UInt8] = []
        #expect(runtime.dispatch(call, frame: &frame, writeGuest: { _, bytes in output = bytes; return true }))
        #expect(output == [0])
        #expect(runtime.dispatch(errorCall, frame: &frame))
        #expect(Int32(bitPattern: frame.returnGPR) == MacError.resourceNotFound.code)
    }

    @Test func malformedStringListReportsResourceError() throws {
        var runtime = try runtime(payload: [0, 2, 1, 65])
        var frame = frame()
        var output: [UInt8] = []
        #expect(runtime.dispatch(call, frame: &frame, writeGuest: { _, bytes in output = bytes; return true }))
        #expect(output == [0])
        #expect(runtime.lastResourceError == MacError.mapRead.code)
    }

    @Test func rejectedGuestDestinationStopsWithoutReportingImportSuccess() throws {
        var runtime = try runtime()
        var frame = frame()
        #expect(!runtime.dispatch(call, frame: &frame, writeGuest: { _, _ in false }))
        #expect(runtime.guestMemoryFault == ToolboxMemoryFault(address: 0x01000000, write: true))
        #expect(runtime.handledImportCount == 0)
    }
}
