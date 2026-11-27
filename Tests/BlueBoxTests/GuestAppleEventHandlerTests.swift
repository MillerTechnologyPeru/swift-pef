import CMORA
import Graphite
import Testing
@testable import BlueBox

@Suite struct GuestAppleEventHandlerTests {
    private let eventClass: UInt32 = 0x61657674 // aevt
    private let eventID: UInt32 = 0x6F617070 // oapp

    @Test func replacesHandlersInSeparatePerRuntimeTables() throws {
        let table = GuestAppleEventHandlers()
        let other = GuestAppleEventHandlers()
        try table.install(eventClass: eventClass, eventID: eventID, procedure: 0x1000,
                          referenceConstant: 0xFFFFFFFF, isSystem: false)
        try table.install(eventClass: eventClass, eventID: eventID, procedure: 0x2000,
                          referenceConstant: 7, isSystem: true)
        #expect(table.entry(eventClass: eventClass, eventID: eventID, isSystem: false)?.referenceConstant == 0xFFFFFFFF)
        try table.install(eventClass: eventClass, eventID: eventID, procedure: 0x3000,
                          referenceConstant: 8, isSystem: false)
        #expect(table.entry(eventClass: eventClass, eventID: eventID, isSystem: false)?.procedure == 0x3000)
        #expect(table.entry(eventClass: eventClass, eventID: eventID, isSystem: true)?.procedure == 0x2000)
        #expect(other.entry(eventClass: eventClass, eventID: eventID, isSystem: false) == nil)
    }

    @Test func validatesProceduresAndRemovesOnlyMatchingEntry() throws {
        let table = GuestAppleEventHandlers()
        for procedure: UInt32 in [0, 0x1001] {
            #expect(throws: MacError.parameter) {
                try table.install(eventClass: eventClass, eventID: eventID, procedure: procedure,
                                  referenceConstant: 0, isSystem: false)
            }
        }
        try table.install(eventClass: eventClass, eventID: eventID, procedure: 0x1000,
                          referenceConstant: 0, isSystem: false)
        #expect(throws: MacError.handlerNotFound) {
            try table.remove(eventClass: eventClass, eventID: eventID, procedure: 0x2000, isSystem: false)
        }
        try table.remove(eventClass: eventClass, eventID: eventID, procedure: 0, isSystem: false)
        #expect(table.entry(eventClass: eventClass, eventID: eventID, isSystem: false) == nil)
    }

    @Test func lookupIsExactAndGuestDeliveryRemainsExplicitlyUnavailable() throws {
        let table = GuestAppleEventHandlers()
        try table.install(eventClass: 0x2A2A2A2A, eventID: 0x2A2A2A2A, procedure: 0x1000,
                          referenceConstant: 0, isSystem: false)
        #expect(table.entry(eventClass: eventClass, eventID: eventID, isSystem: false) == nil)
        let entry = try #require(table.entry(eventClass: 0x2A2A2A2A, eventID: 0x2A2A2A2A, isSystem: false))
        var reply = Descriptor(type: "null")
        let event = AppleEvent(eventClass: "aevt", eventID: "oapp")
        #expect(throws: MacError.unimplemented) { try entry.handler(event, &reply) }
        #expect(GuestGestalt.makeTable()["evnt"] == nil)
    }

    private func call(_ name: String, arguments: [UInt32], runtime: inout ToolboxRuntime,
                      write: ((UInt32, [UInt8]) -> Bool)? = nil) -> MORAInvocationFrame {
        var frame = MORAInvocationFrame()
        withUnsafeMutableBytes(of: &frame.gpr) { bytes in
            let registers = bytes.bindMemory(to: UInt32.self)
            for (index, value) in arguments.enumerated() { registers[index] = value }
        }
        #expect(runtime.dispatch(GuestImport(library: "InterfaceLib", symbol: name, symbolClass: .tVector),
                                 frame: &frame, writeGuest: write))
        return frame
    }

    @Test func bridgeWritesOpaqueGuestProcedureAndRefconInBigEndian() {
        var runtime = ToolboxRuntime()
        let installed = call("AEInstallEventHandler", arguments: [eventClass, eventID, 0x01002000, 0xFEDCBA98, 0xFFFFFF00],
                             runtime: &runtime)
        #expect(installed.returnGPR == 0)
        var writes: [UInt32: [UInt8]] = [:]
        let queried = call("AEGetEventHandler", arguments: [eventClass, eventID, 0x100, 0x104, 0], runtime: &runtime,
                           write: { address, bytes in writes[address] = bytes; return true })
        #expect(queried.returnGPR == 0)
        #expect(writes[0x100] == [1, 0, 0x20, 0])
        #expect(writes[0x104] == [0xFE, 0xDC, 0xBA, 0x98])
        let removed = call("AERemoveEventHandler", arguments: [eventClass, eventID, 0x01002000, 0], runtime: &runtime)
        #expect(removed.returnGPR == 0)
    }

    @Test func bridgeReturnsSignedErrorsWithoutWritingMissingHandlerOutputs() {
        var runtime = ToolboxRuntime()
        let invalid = call("AEInstallEventHandler", arguments: [eventClass, eventID, 1, 0, 0], runtime: &runtime)
        #expect(Int32(bitPattern: invalid.returnGPR) == -50)
        var wrote = false
        let queried = call("AEGetEventHandler", arguments: [eventClass, eventID, 0x100, 0x104, 0], runtime: &runtime,
                           write: { _, _ in wrote = true; return true })
        #expect(Int32(bitPattern: queried.returnGPR) == -1717)
        #expect(!wrote)
    }

    @Test func invalidLookupDestinationReportsMemoryFault() {
        var runtime = ToolboxRuntime()
        _ = call("AEInstallEventHandler", arguments: [eventClass, eventID, 0x1000, 0, 0], runtime: &runtime)
        var frame = MORAInvocationFrame()
        withUnsafeMutableBytes(of: &frame.gpr) { bytes in
            let registers = bytes.bindMemory(to: UInt32.self)
            registers[0] = eventClass
            registers[1] = eventID
            registers[2] = 0x100
            registers[3] = 0
        }
        #expect(!runtime.dispatch(GuestImport(library: "InterfaceLib", symbol: "AEGetEventHandler", symbolClass: .tVector),
                                  frame: &frame, writeGuest: { address, _ in address != 0 }))
        #expect(runtime.guestMemoryFault == ToolboxMemoryFault(address: 0, write: true))
        #expect(runtime.handledImportCount == 1)
    }
}
