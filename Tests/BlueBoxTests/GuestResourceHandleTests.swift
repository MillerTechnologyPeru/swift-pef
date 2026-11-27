import CMORA
import Graphite
import Testing
@testable import BlueBox

@Suite struct GuestResourceHandleTests {
    private func call(_ name: String, _ arguments: [UInt32], runtime: inout ToolboxRuntime,
                      write: @escaping (UInt32, [UInt8]) -> Bool) -> UInt32 {
        var frame = MORAInvocationFrame()
        withUnsafeMutableBytes(of: &frame.gpr) { bytes in
            let registers = bytes.bindMemory(to: UInt32.self)
            for (index, value) in arguments.enumerated() { registers[index] = value }
        }
        #expect(runtime.dispatch(GuestImport(library: "InterfaceLib", symbol: name, symbolClass: .tVector),
                                 frame: &frame, writeGuest: write))
        return frame.returnGPR
    }

    private func runtime() throws -> ToolboxRuntime {
        let fork = try ResourceMap.write([(resource: Resource(type: "TEST", id: -7), bytes: [1, 2, 3])])
        return ToolboxRuntime(resources: try ResourceFile(bytes: fork))
    }

    @Test func loadsPayloadAndCachesStableHandleAcrossGetVariants() throws {
        var runtime = try runtime()
        var writes: [(UInt32, [UInt8])] = []
        let write = { (address: UInt32, bytes: [UInt8]) in writes.append((address, bytes)); return true }
        let handle = call("GetResource", [0x54455354, 0xFFFFFFF9], runtime: &runtime, write: write)
        #expect(handle != 0)
        #expect(writes.last?.1 == [1, 2, 3])
        #expect(writes.contains { $0.0 == handle && $0.1 == [0x40, 0, 1, 0] })
        let count = writes.count
        let free = runtime.heap.freeBytes
        #expect(call("Get1Resource", [0x54455354, 0xFFFFFFF9], runtime: &runtime, write: write) == handle)
        #expect(writes.count == count)
        #expect(runtime.heap.freeBytes == free)
        #expect(call("GetHandleSize", [handle], runtime: &runtime, write: write) == 3)
    }

    @Test func releasesReloadsDetachesAndInvalidatesDisposedResourceHandles() throws {
        var runtime = try runtime()
        var payloadLoads = 0
        let write = { (_: UInt32, bytes: [UInt8]) in
            if bytes == [1, 2, 3] { payloadLoads += 1 }
            return true
        }
        let handle = call("GetResource", [0x54455354, 0xFFFFFFF9], runtime: &runtime, write: write)
        let free = runtime.heap.freeBytes
        _ = call("ReleaseResource", [handle], runtime: &runtime, write: write)
        #expect(runtime.heap.freeBytes == free + 16)
        let detached = call("GetResource", [0x54455354, 0xFFFFFFF9], runtime: &runtime, write: write)
        #expect(payloadLoads == 2)
        _ = call("DetachResource", [detached], runtime: &runtime, write: write)
        #expect(call("GetHandleSize", [detached], runtime: &runtime, write: write) == 3)
        let replacement = call("GetResource", [0x54455354, 0xFFFFFFF9], runtime: &runtime, write: write)
        #expect(replacement != detached)
        #expect(payloadLoads == 3)
        _ = call("ReleaseResource", [detached], runtime: &runtime, write: write)
        #expect(runtime.lastResourceError == MacError.resourceNotFound.code)
        _ = call("DisposeHandle", [replacement], runtime: &runtime, write: write)
        _ = call("GetResource", [0x54455354, 0xFFFFFFF9], runtime: &runtime, write: write)
        #expect(payloadLoads == 4)
        #expect(runtime.lastResourceError == 0)
    }

    @Test func missingResourceReturnsNilAndResourceError() throws {
        var runtime = try runtime()
        let free = runtime.heap.freeBytes
        #expect(call("GetResource", [0x54455354, 123], runtime: &runtime, write: { _, _ in true }) == 0)
        #expect(runtime.lastResourceError == MacError.resourceNotFound.code)
        #expect(runtime.heap.freeBytes == free)
    }

    @Test func loadsStringAndZeroLengthResourceHandles() throws {
        let fork = try ResourceMap.write([
            (resource: Resource(type: "STR ", id: 5), bytes: [1, 65]),
            (resource: Resource(type: "TEST", id: 6), bytes: [])
        ])
        var runtime = ToolboxRuntime(resources: try ResourceFile(bytes: fork))
        var writes: [UInt32: [UInt8]] = [:]
        let write = { (address: UInt32, bytes: [UInt8]) in writes[address] = bytes; return true }
        let string = call("GetString", [5], runtime: &runtime, write: write)
        #expect(string != 0)
        #expect(writes.values.contains([1, 65]))
        let empty = call("GetResource", [0x54455354, 6], runtime: &runtime, write: write)
        #expect(empty != 0)
        #expect(writes[empty] == [0, 0, 0, 0])
        #expect(call("GetHandleSize", [empty], runtime: &runtime, write: write) == 0)
    }
}
