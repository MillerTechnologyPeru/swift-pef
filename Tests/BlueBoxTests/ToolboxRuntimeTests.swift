import CMORA
import PEFKit
import Testing
@testable import BlueBox

@Suite struct ToolboxRuntimeTests {
    private func symbol(_ name: String, library: String = "InterfaceLib",
                        kind: PEFSymbolClass = .tVector) -> GuestImport {
        GuestImport(library: library, symbol: name, symbolClass: kind)
    }

    @Test func bridgesClockReturnValues() {
        var runtime = ToolboxRuntime(ticks: { 0xFEDCBA98 })
        var frame = MORAInvocationFrame()
        #expect(runtime.dispatch(symbol("TickCount"), frame: &frame))
        #expect(frame.returnGPR == 0xFEDCBA98)
        #expect(runtime.dispatch(symbol("GetDblTime"), frame: &frame))
        #expect(frame.returnGPR == 30)
        #expect(runtime.dispatch(symbol("GetCaretTime"), frame: &frame))
        #expect(frame.returnGPR == 30)
        #expect(runtime.handledImportCount == 3)
    }

    @Test func keepsCursorStatePerRuntime() {
        var runtime = ToolboxRuntime()
        let other = ToolboxRuntime()
        var frame = MORAInvocationFrame()
        #expect(runtime.dispatch(symbol("HideCursor"), frame: &frame))
        #expect(runtime.dispatch(symbol("HideCursor"), frame: &frame))
        #expect(runtime.dispatch(symbol("ShowCursor"), frame: &frame))
        #expect(!runtime.cursor.isVisible)
        #expect(other.cursor.isVisible)
        #expect(runtime.dispatch(symbol("InitCursor"), frame: &frame))
        #expect(runtime.cursor.isVisible)
        #expect(runtime.cursor.hideCount == 0)
    }

    @Test func flushesOnlySelectedEventsBeforeStopEvent() {
        var runtime = ToolboxRuntime()
        runtime.pendingEventKinds = [1, 4, 3, 1]
        var frame = MORAInvocationFrame()
        withUnsafeMutableBytes(of: &frame.gpr) { bytes in
            let registers = bytes.bindMemory(to: UInt32.self)
            registers[0] = 0xFFFF0002 // Only the low 16 bits of an EventMask are significant.
            registers[1] = 1 << 3
        }
        #expect(runtime.dispatch(symbol("FlushEvents"), frame: &frame))
        #expect(runtime.pendingEventKinds == [4, 3, 1])
        withUnsafeMutableBytes(of: &frame.gpr) { bytes in
            let registers = bytes.bindMemory(to: UInt32.self)
            registers[0] = 0xFFFF
            registers[1] = 0
        }
        #expect(runtime.dispatch(symbol("FlushEvents"), frame: &frame))
        #expect(runtime.pendingEventKinds.isEmpty)
    }

    @Test func preservesEventsGeneratedOutsideLowLevelQueue() {
        var runtime = ToolboxRuntime()
        runtime.pendingEventKinds = [1, 6, 8, 15, 23]
        var frame = MORAInvocationFrame()
        withUnsafeMutableBytes(of: &frame.gpr) { $0.bindMemory(to: UInt32.self)[0] = 0xFFFF }
        #expect(runtime.dispatch(symbol("FlushEvents"), frame: &frame))
        #expect(runtime.pendingEventKinds == [6, 8, 15, 23])
    }

    @Test func rejectsUnknownLibrariesSymbolsAndDataImports() {
        var runtime = ToolboxRuntime()
        var frame = MORAInvocationFrame()
        frame.returnGPR = 0x1234
        #expect(!runtime.dispatch(symbol("TickCount", library: "OtherLib"), frame: &frame))
        #expect(!runtime.dispatch(symbol("UnknownToolboxCall"), frame: &frame))
        #expect(!runtime.dispatch(symbol("TickCount", kind: .data), frame: &frame))
        #expect(frame.returnGPR == 0x1234)
        #expect(runtime.handledImportCount == 0)
    }

    @Test func initializesPackedGlobalsFromThePortPointer() {
        var runtime = ToolboxRuntime()
        var frame = MORAInvocationFrame()
        let pointer: UInt32 = 0x01000202
        withUnsafeMutableBytes(of: &frame.gpr) { $0.bindMemory(to: UInt32.self)[0] = pointer }
        var writes: [(UInt32, [UInt8])] = []
        #expect(runtime.dispatch(symbol("InitGraf"), frame: &frame, writeGuest: { address, bytes in
            writes.append((address, bytes))
            return true
        }))
        #expect(writes.count == 1)
        guard let (address, bytes) = writes.first else { return }
        #expect(address == pointer - 126)
        #expect(bytes.count == 130)
        #expect(Array(bytes[0..<4]) == [0, 0, 0, 1]) // randSeed
        #expect(Array(bytes[4..<10]) == [0x30, 0, 0, 0, 0, 80]) // screenBits address and rowBytes
        #expect(Array(bytes[10..<18]) == [0, 0, 0, 0, 1, 0xE0, 2, 0x80]) // 640 x 480
        #expect(Array(bytes[110..<118]) == Array(repeating: 255, count: 8)) // black
        #expect(Array(bytes[118..<130]) == Array(repeating: 0, count: 12)) // white, nil thePort
        #expect(runtime.globalsAddress == address)
        #expect(runtime.quickDraw.currentPort == nil)
        #expect(runtime.quickDraw.random.seed == 1)
    }

    @Test func initGrafRejectsUnderflowWithoutWriting() {
        var runtime = ToolboxRuntime()
        var frame = MORAInvocationFrame()
        var wrote = false
        #expect(!runtime.dispatch(symbol("InitGraf"), frame: &frame, writeGuest: { _, _ in
            wrote = true
            return true
        }))
        #expect(!wrote)
        #expect(runtime.guestMemoryFault == 0)
        #expect(runtime.globalsAddress == nil)
        #expect(runtime.handledImportCount == 0)
    }

    @Test func graphitesScreenSharesGuestPixels() throws {
        let memory = try GuestAddressSpace()
        try memory.commit(at: GuestQuickDrawGlobals.screenAddress, byteCount: GuestQuickDrawGlobals.screenByteCount)
        let runtime = ToolboxRuntime(screenPixels: memory.hostPointer(for: GuestQuickDrawGlobals.screenAddress))
        let screen = try #require(runtime.quickDraw.mainDevice)
        memory.writeBigEndian(UInt8(0x80), at: GuestQuickDrawGlobals.screenAddress)
        #expect(screen.pixels.value(column: 0, row: 0) == 1)
        #expect(screen.pixels.value(column: 1, row: 0) == 0)
        #expect(screen.pixels.baseAddress == memory.hostPointer(for: GuestQuickDrawGlobals.screenAddress))
    }

    @Test func initializesFontsOncePerRuntime() throws {
        var runtime = ToolboxRuntime()
        var other = ToolboxRuntime()
        var frame = MORAInvocationFrame()
        #expect(runtime.fonts == nil)
        #expect(runtime.dispatch(symbol("InitFonts"), frame: &frame))
        let registry = try #require(runtime.fonts)
        #expect(registry.face(family: 0).familyName == "Chicago")
        #expect(runtime.dispatch(symbol("InitFonts"), frame: &frame))
        #expect(runtime.fonts === registry)
        #expect(other.fonts == nil)
        #expect(other.dispatch(symbol("InitFonts"), frame: &frame))
        #expect(other.fonts !== registry)
    }

    @Test func returnsActualFontFamiliesAndDefaultSize() {
        var runtime = ToolboxRuntime()
        var frame = MORAInvocationFrame()
        #expect(runtime.dispatch(symbol("GetSysFont"), frame: &frame))
        #expect(frame.returnGPR == 0)
        #expect(runtime.dispatch(symbol("GetAppFont"), frame: &frame))
        #expect(frame.returnGPR == 3) // Actual Geneva ID, rather than the application-font alias 1.
        #expect(runtime.dispatch(symbol("GetDefFontSize"), frame: &frame))
        #expect(frame.returnGPR == 12)
    }

    @Test func writesPascalFontNamesAndEmptyUnknownName() {
        var runtime = ToolboxRuntime()
        var frame = MORAInvocationFrame()
        for (family, expected): (UInt32, [UInt8]) in [
            (0, [7] + Array("Chicago".utf8)),
            (1, [6] + Array("Geneva".utf8)),
            (0xFFFFFFFF, [0])
        ] {
            withUnsafeMutableBytes(of: &frame.gpr) { bytes in
                let registers = bytes.bindMemory(to: UInt32.self)
                registers[0] = family
                registers[1] = 0x12345678
            }
            var result: [UInt8] = []
            let handled = runtime.dispatch(symbol("GetFontName"), frame: &frame, writeGuest: { address, bytes in
                #expect(address == 0x12345678)
                result = bytes
                return true
            })
            #expect(handled)
            #expect(result == expected)
        }
    }

    @Test func reportsRejectedFontNameWrite() {
        var runtime = ToolboxRuntime()
        var frame = MORAInvocationFrame()
        withUnsafeMutableBytes(of: &frame.gpr) { $0.bindMemory(to: UInt32.self)[1] = 0x12345678 }
        #expect(!runtime.dispatch(symbol("GetFontName"), frame: &frame, writeGuest: { _, _ in false }))
        #expect(runtime.guestMemoryFault == 0x12345678)
        #expect(runtime.handledImportCount == 0)
    }

    @Test func initializesScreenSizedWindowPortAndGuestRegionHandles() throws {
        var runtime = ToolboxRuntime()
        var frame = MORAInvocationFrame()
        var bytes: [UInt8] = []
        var destination: UInt32 = 0
        let initialized = runtime.dispatch(symbol("InitWindows"), frame: &frame, writeGuest: { address, data in
            destination = address
            bytes = data
            return true
        })
        #expect(initialized)
        #expect(destination == GuestWindowManager.address)
        #expect(bytes.count == 136)
        func word(at offset: Int) -> UInt32 {
            bytes.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        #expect(word(at: 2) == GuestQuickDrawGlobals.screenAddress)
        #expect(Array(bytes[6..<8]) == [0, 80])
        #expect(Array(bytes[16..<24]) == [0, 0, 0, 0, 1, 0xE0, 2, 0x80])
        #expect(word(at: 24) == GuestWindowManager.visibleHandle)
        #expect(word(at: 28) == GuestWindowManager.clipHandle)
        #expect(word(at: 108) == GuestWindowManager.visibleRegion)
        #expect(word(at: 112) == GuestWindowManager.clipRegion)
        #expect(Array(bytes[116..<126]) == [0, 10, 0, 0, 0, 0, 1, 0xE0, 2, 0x80])
        let port = try #require(runtime.windowManagerPort)
        #expect(port.portRect == runtime.quickDraw.mainDevice?.bounds)
        #expect(port.pixels === runtime.quickDraw.mainDevice?.pixels)
        #expect(runtime.dispatch(symbol("InitWindows"), frame: &frame)) // Preserve an existing port.
        #expect(runtime.windowManagerPort === port)
        var returned: [UInt8] = []
        withUnsafeMutableBytes(of: &frame.gpr) { $0.bindMemory(to: UInt32.self)[0] = 0x01000000 }
        let queried = runtime.dispatch(symbol("GetWMgrPort"), frame: &frame, writeGuest: { address, data in
            #expect(address == 0x01000000)
            returned = data
            return true
        })
        #expect(queried)
        #expect(returned == [0x22, 0, 0, 0])
        #expect(runtime.dispatch(symbol("FrontWindow"), frame: &frame))
        #expect(frame.returnGPR == 0)
    }

    @Test func failedWindowInitializationDoesNotPublishPort() {
        var runtime = ToolboxRuntime()
        var frame = MORAInvocationFrame()
        #expect(!runtime.dispatch(symbol("InitWindows"), frame: &frame, writeGuest: { _, _ in false }))
        #expect(runtime.windowManagerPort == nil)
        #expect(runtime.guestMemoryFault == GuestWindowManager.address)
        #expect(runtime.handledImportCount == 0)
    }

    @Test func windowQueriesRequireInitializedManager() {
        var runtime = ToolboxRuntime()
        var frame = MORAInvocationFrame()
        #expect(!runtime.dispatch(symbol("GetWMgrPort"), frame: &frame, writeGuest: { _, _ in true }))
        #expect(!runtime.dispatch(symbol("FrontWindow"), frame: &frame))
        #expect(runtime.handledImportCount == 0)
    }

    @Test func rejectsWindowPortOutputPointer() {
        var runtime = ToolboxRuntime()
        var frame = MORAInvocationFrame()
        #expect(runtime.dispatch(symbol("InitWindows"), frame: &frame, writeGuest: { _, _ in true }))
        withUnsafeMutableBytes(of: &frame.gpr) { $0.bindMemory(to: UInt32.self)[0] = 0x12345678 }
        #expect(!runtime.dispatch(symbol("GetWMgrPort"), frame: &frame, writeGuest: { _, _ in false }))
        #expect(runtime.guestMemoryFault == 0x12345678)
        #expect(runtime.handledImportCount == 1)
    }

    @Test func drawsEmptyMenuBarWithoutChangingDesktopOrCurrentPort() throws {
        var runtime = ToolboxRuntime()
        var frame = MORAInvocationFrame()
        #expect(runtime.dispatch(symbol("InitWindows"), frame: &frame, writeGuest: { _, _ in true }))
        let screen = try #require(runtime.quickDraw.mainDevice)
        screen.pixels.fill(screen.bounds, with: 1)
        runtime.quickDraw.currentPort = runtime.windowManagerPort
        let previousPort = runtime.quickDraw.currentPort
        #expect(runtime.dispatch(symbol("InitMenus"), frame: &frame))
        #expect(screen.pixels.value(column: 10, row: 0) == 0)
        #expect(screen.pixels.value(column: 10, row: 18) == 0)
        #expect(screen.pixels.value(column: 10, row: 19) == 1)
        #expect(screen.pixels.value(column: 10, row: 20) == 1)
        #expect(runtime.quickDraw.currentPort === previousPort)
        #expect(runtime.menuManager?.menuIDs.isEmpty == true)
        let manager = try #require(runtime.menuManager)
        #expect(runtime.dispatch(symbol("InitMenus"), frame: &frame))
        #expect(runtime.menuManager === manager)
        #expect(runtime.dispatch(symbol("GetMBarHeight"), frame: &frame))
        #expect(frame.returnGPR == 20)
    }

    @Test func clearMenuBarWaitsForExplicitRedraw() throws {
        var runtime = ToolboxRuntime()
        var frame = MORAInvocationFrame()
        #expect(runtime.dispatch(symbol("InitWindows"), frame: &frame, writeGuest: { _, _ in true }))
        #expect(runtime.dispatch(symbol("InitMenus"), frame: &frame))
        let screen = try #require(runtime.quickDraw.mainDevice)
        screen.pixels.fill(screen.bounds, with: 1)
        #expect(runtime.dispatch(symbol("ClearMenuBar"), frame: &frame))
        #expect(screen.pixels.value(column: 10, row: 0) == 1)
        #expect(runtime.dispatch(symbol("DrawMenuBar"), frame: &frame))
        #expect(screen.pixels.value(column: 10, row: 0) == 0)
        #expect(screen.pixels.value(column: 10, row: 19) == 1)
    }

    @Test func menuCallsRequireTheirManagerAndRemainPerRuntime() {
        var runtime = ToolboxRuntime()
        var other = ToolboxRuntime()
        var frame = MORAInvocationFrame()
        #expect(!runtime.dispatch(symbol("InitMenus"), frame: &frame))
        #expect(!runtime.dispatch(symbol("DrawMenuBar"), frame: &frame))
        #expect(!runtime.dispatch(symbol("ClearMenuBar"), frame: &frame))
        #expect(runtime.handledImportCount == 0)
        #expect(runtime.dispatch(symbol("InitWindows"), frame: &frame, writeGuest: { _, _ in true }))
        #expect(runtime.dispatch(symbol("InitMenus"), frame: &frame))
        #expect(other.menuManager == nil)
        #expect(!other.dispatch(symbol("DrawMenuBar"), frame: &frame))
    }
}
