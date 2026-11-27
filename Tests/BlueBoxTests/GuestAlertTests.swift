import CMORA
import Foundation
import Graphite
import Testing
@testable import BlueBox

@Suite struct GuestAlertTests {
    private func resources(stages: UInt16 = 0x5555, itemType: UInt8 = 0x88, truncate: Bool = false) throws -> ResourceFile {
        var alert = BigEndianWriter()
        alert.write(Rect(top: 10, left: 10, bottom: 100, right: 210))
        alert.write(Int16(128))
        alert.write(stages)
        var list = BigEndianWriter()
        list.write(UInt16(1)) // Two items.
        list.write(UInt32(0))
        list.write(Rect(top: 60, left: 120, bottom: 80, right: 180))
        list.write(UInt8(4))
        list.write(UInt8(2))
        list.write(bytes: Array("OK".utf8))
        list.write(UInt32(0))
        list.write(Rect(top: 10, left: 10, bottom: 50, right: 190))
        list.write(itemType)
        list.write(UInt8(5))
        list.write(bytes: Array("^0 ^1".utf8))
        list.align(to: 2)
        return try ResourceFile(bytes: ResourceMap.write([
            (resource: Resource(type: "ALRT", id: 128), bytes: alert.bytes),
            (resource: Resource(type: "DITL", id: 128), bytes: truncate ? Array(list.bytes.dropLast(3)) : list.bytes)
        ]))
    }

    @Test func parsesAlertAndSubstitutesParametersWithoutRecursion() throws {
        let alert = try GuestAlert(id: 128, resources: resources(),
                                  parameters: [PascalString(bytes: Array("^1".utf8)), PascalString(bytes: [0x8E])])
        #expect(alert.id == 128)
        #expect(alert.items.count == 2)
        #expect(alert.items[0].isButton)
        #expect(alert.items[0].enabled)
        #expect(alert.items[0].text == "OK")
        #expect(alert.items[1].text == "^1 é")
    }

    @Test func rejectsTruncatedAndUnsupportedAlertLayouts() throws {
        let truncated = try resources(truncate: true)
        let stages = try resources(stages: 0)
        let unsupported = try resources(itemType: 0x10) // Editable text needs TextEdit records.
        for file in [truncated, stages, unsupported] {
            #expect(throws: MacError.self) { try GuestAlert(id: 128, resources: file, parameters: []) }
        }
    }

    @Test func rendersPixelsAndExportsPortableSnapshot() throws {
        let alert = try GuestAlert(id: 128, resources: resources(), parameters: [])
        let screen = GraphicsDevice.screen(width: 640, height: 480, depth: 1)
        alert.draw(on: screen, fonts: FontRegistry(), font: 0)
        #expect(screen.pixels.value(column: 10, row: 10) == 1)
        #expect(screen.pixels.value(column: 11, row: 90) == 0)
        let ppm = GuestFramebuffer.ppm(UnsafeRawBufferPointer(start: screen.pixels.baseAddress,
                                                             count: GuestQuickDrawGlobals.screenByteCount))
        let header = Array("P6\n640 480\n255\n".utf8)
        #expect(Array(ppm.prefix(header.count)) == header)
        #expect(ppm.count == header.count + 640 * 480 * 3)
        let black = header.count + (10 * 640 + 10) * 3
        #expect(Array(ppm[black..<black + 3]) == [0, 0, 0])
    }

    @Test func modalAlertRemainsPendingAndGuestFilterIsNotInvoked() throws {
        var runtime = ToolboxRuntime(resources: try resources())
        var frame = MORAInvocationFrame()
        let initialize = GuestImport(library: "InterfaceLib", symbol: "InitDialogs", symbolClass: .tVector)
        let stop = GuestImport(library: "InterfaceLib", symbol: "StopAlert", symbolClass: .tVector)
        #expect(runtime.dispatch(initialize, frame: &frame))
        withUnsafeMutableBytes(of: &frame.gpr) { bytes in
            let registers = bytes.bindMemory(to: UInt32.self)
            registers[0] = 128
            registers[1] = 0x12345678
        }
        #expect(!runtime.dispatch(stop, frame: &frame))
        #expect(runtime.pendingAlert == nil)
        withUnsafeMutableBytes(of: &frame.gpr) { $0.bindMemory(to: UInt32.self)[1] = 0 }
        frame.returnGPR = 0xDEADBEEF
        #expect(!runtime.dispatch(stop, frame: &frame))
        #expect(runtime.pendingAlert?.id == 128)
        #expect(frame.returnGPR == 0xDEADBEEF)
        #expect(runtime.handledImportCount == 1)
    }
}
