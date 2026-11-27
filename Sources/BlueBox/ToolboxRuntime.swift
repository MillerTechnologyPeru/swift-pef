import CMORA
import Graphite

struct ToolboxMemoryFault: Equatable {
    let address: UInt32
    let write: Bool
}

/// Per-fragment Toolbox state. Guest pointers are never treated as host pointers.
struct ToolboxRuntime {
    private let ticks: () -> UInt32
    let quickDraw: QuickDraw
    var cursor: CursorState { quickDraw.cursor }
    private(set) var handledImportCount: UInt64 = 0
    private(set) var guestMemoryFault: ToolboxMemoryFault?
    private(set) var globalsAddress: UInt32?
    private(set) var fonts: FontRegistry?
    private(set) var windowManagerPort: Port?
    private(set) var menuManager: HeadlessMenuManager?
    private(set) var textEditScrapLength: UInt32?
    private(set) var dialogs: DialogManagerState?

    /// Low-level event kinds in chronological order; host input delivery is still pending.
    var pendingEventKinds: [UInt16] = []

    /// Supplied screen memory must outlive this runtime and its QuickDraw objects.
    init(screenPixels: UnsafeMutableRawPointer? = nil,
         ticks: @escaping () -> UInt32 = { SystemClock.ticks }) {
        self.ticks = ticks
        let bounds = GuestQuickDrawGlobals.screenBounds
        let pixels = screenPixels.map {
            PixelBuffer(wrapping: $0, rowBytes: GuestQuickDrawGlobals.screenRowBytes,
                        bounds: bounds, format: .indexed(depth: 1))
        } ?? PixelBuffer(bounds: bounds, format: .indexed(depth: 1))
        quickDraw = QuickDraw(screens: [GraphicsDevice(bounds: bounds, pixels: pixels, isScreen: true)])
    }

    /// Dispatch only callable InterfaceLib imports. Unsupported symbols remain visible to the runner.
    mutating func dispatch(_ symbol: GuestImport, frame: inout MORAInvocationFrame,
                           readGuest: ((UInt32, Int) -> [UInt8]?)? = nil,
                           writeGuest: ((UInt32, [UInt8]) -> Bool)? = nil) -> Bool {
        guard symbol.library == "InterfaceLib",
              symbol.symbolClass == .tVector || symbol.symbolClass == .code || symbol.symbolClass == .glue else {
            return false
        }
        switch symbol.symbol {
        case "InitDialogs":
            let resume = withUnsafeBytes(of: frame.gpr) { $0.bindMemory(to: UInt32.self)[0] }
            dialogs = DialogManagerState(resumeProcedure: resume)
        case "SetDialogFont", "SetDAFont":
            guard dialogs != nil else { return false }
            dialogs?.font = withUnsafeBytes(of: frame.gpr) { Int16(truncatingIfNeeded: $0.bindMemory(to: UInt32.self)[0]) }
        case "ParamText":
            guard var dialogs, let readGuest else { return false }
            let addresses = withUnsafeBytes(of: frame.gpr) { Array($0.bindMemory(to: UInt32.self).prefix(4)) }
            var parameters: [PascalString] = []
            for address in addresses {
                guard let header = readGuest(address, 1), let length = header.first,
                      let bytes = readGuest(address, Int(length) + 1), bytes.count == Int(length) + 1 else {
                    guestMemoryFault = ToolboxMemoryFault(address: address, write: false)
                    return false
                }
                parameters.append(PascalString(lengthPrefixed: bytes))
            }
            dialogs.parameterText = parameters
            self.dialogs = dialogs
        case "TEInit":
            if textEditScrapLength == nil {
                guard let writeGuest else { return false }
                guard writeGuest(GuestTextEdit.scrapHandle, GuestTextEdit.initialBytes) else {
                    guestMemoryFault = ToolboxMemoryFault(address: GuestTextEdit.scrapHandle, write: true)
                    return false
                }
                textEditScrapLength = 0
            }
        case "TEScrapHandle", "TEGetScrapHandle":
            guard textEditScrapLength != nil else { return false }
            frame.returnGPR = GuestTextEdit.scrapHandle
        case "TEGetScrapLength":
            guard let textEditScrapLength else { return false }
            frame.returnGPR = textEditScrapLength
        case "InitMenus":
            guard windowManagerPort != nil, let screen = quickDraw.mainDevice else { return false }
            if let menuManager {
                menuManager.drawMenuBar()
            } else {
                menuManager = HeadlessMenuManager(screen: screen)
            }
        case "GetMBarHeight":
            frame.returnGPR = UInt32(HeadlessMenuManager.barHeight)
        case "DrawMenuBar":
            guard let menuManager else { return false }
            menuManager.drawMenuBar()
        case "ClearMenuBar":
            guard let menuManager else { return false }
            menuManager.clearMenuBar()
        case "InitWindows":
            if windowManagerPort == nil {
                guard let writeGuest, let screen = quickDraw.mainDevice else { return false }
                guard writeGuest(GuestWindowManager.address, GuestWindowManager.initialBytes()) else {
                    guestMemoryFault = ToolboxMemoryFault(address: GuestWindowManager.address, write: true)
                    return false
                }
                let port = Port(pixels: screen.pixels)
                port.device = screen
                windowManagerPort = port
            }
        case "GetWMgrPort":
            guard windowManagerPort != nil, let writeGuest else { return false }
            let address = withUnsafeBytes(of: frame.gpr) { $0.bindMemory(to: UInt32.self)[0] }
            var writer = BigEndianWriter(capacity: 4)
            writer.write(GuestWindowManager.address)
            guard writeGuest(address, writer.bytes) else {
                guestMemoryFault = ToolboxMemoryFault(address: address, write: true)
                return false
            }
        case "FrontWindow":
            guard windowManagerPort != nil else { return false }
            frame.returnGPR = 0 // The supported initial state has no application windows.
        case "InitFonts":
            _ = initializeFonts()
        case "GetSysFont":
            frame.returnGPR = UInt32(UInt16(bitPattern: FontRegistry.systemFont))
        case "GetAppFont":
            // The application-font alias (1) maps to Geneva's actual family ID (3).
            frame.returnGPR = 3
        case "GetDefFontSize":
            frame.returnGPR = UInt32(SystemFont.nativeSize)
        case "GetFontName":
            guard let writeGuest else { return false }
            let arguments = withUnsafeBytes(of: frame.gpr) { bytes in
                let registers = bytes.bindMemory(to: UInt32.self)
                return (Int16(truncatingIfNeeded: registers[0]), registers[1])
            }
            let name = initializeFonts().name(of: arguments.0) ?? ""
            let bytes = (PascalString(name) ?? PascalString()).lengthPrefixed
            guard writeGuest(arguments.1, bytes) else {
                guestMemoryFault = ToolboxMemoryFault(address: arguments.1, write: true)
                return false
            }
        case "InitGraf":
            guard let writeGuest else { return false }
            let thePort = withUnsafeBytes(of: frame.gpr) { $0.bindMemory(to: UInt32.self)[0] }
            guard thePort >= GuestQuickDrawGlobals.publicPrefixLength else {
                guestMemoryFault = ToolboxMemoryFault(address: thePort, write: true)
                return false
            }
            let start = thePort - GuestQuickDrawGlobals.publicPrefixLength
            guard writeGuest(start, GuestQuickDrawGlobals.initialBytes()) else {
                guestMemoryFault = ToolboxMemoryFault(address: start, write: true)
                return false
            }
            globalsAddress = start
            quickDraw.currentPort = nil
            quickDraw.currentDevice = quickDraw.mainDevice
            quickDraw.random = QuickDrawRandom(seed: 1)
        case "TickCount":
            frame.returnGPR = ticks()
        case "GetDblTime":
            frame.returnGPR = SystemClock.doubleClickTicks
        case "GetCaretTime":
            frame.returnGPR = SystemClock.caretBlinkTicks
        case "InitCursor":
            quickDraw.cursor.initialize()
        case "HideCursor":
            quickDraw.cursor.hide()
        case "ShowCursor":
            quickDraw.cursor.show()
        case "FlushEvents":
            let masks = withUnsafeBytes(of: frame.gpr) { bytes in
                let registers = bytes.bindMemory(to: UInt32.self)
                return (UInt16(truncatingIfNeeded: registers[0]), UInt16(truncatingIfNeeded: registers[1]))
            }
            flushEvents(whichMask: masks.0, stopMask: masks.1)
        default:
            return false
        }
        handledImportCount += 1
        return true
    }

    /// Load the built-in fallback once per fragment; resource and host font loading are separate.
    /// https://dev.os9.ca/techpubs/mac/Text/Text-277.html
    private mutating func initializeFonts() -> FontRegistry {
        if let fonts { return fonts }
        let registry = FontRegistry()
        _ = registry.face(family: FontRegistry.systemFont)
        fonts = registry
        return registry
    }

    /// Apple's FlushEvents scans up to the first stop-mask event, preserving that event and its tail.
    /// https://dev.os9.ca/techpubs/mac/Toolbox/Toolbox-56.html
    private mutating func flushEvents(whichMask: UInt16, stopMask: UInt16) {
        var stopped = false
        pendingEventKinds.removeAll { kind in
            // Update, activate and OS events are generated outside the low-level queue.
            guard !stopped, kind < 16, kind != 6, kind != 8, kind != 15 else { return false }
            let mask = UInt16(1) << kind
            if stopMask & mask != 0 {
                stopped = true
                return false
            }
            return whichMask & mask != 0
        }
    }
}
