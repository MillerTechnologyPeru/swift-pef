import CMORA
import Graphite

struct ToolboxMemoryFault: Error, Equatable {
    let address: UInt32
    let write: Bool
}

private struct GuestResourceKey: Hashable {
    let type: FourCharCode
    let id: Int16
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
    private(set) var heap = GuestHeap()
    private let gestalt = GuestGestalt.makeTable()
    private let resources: ResourceFile?
    private(set) var lastResourceError: Int32 = 0
    private var resourceHandles: [GuestResourceKey: UInt32] = [:]
    private(set) var pendingAlert: GuestAlert?

    /// Low-level event kinds in chronological order; host input delivery is still pending.
    var pendingEventKinds: [UInt16] = []

    /// Supplied screen memory must outlive this runtime and its QuickDraw objects.
    init(screenPixels: UnsafeMutableRawPointer? = nil,
         resources: ResourceFile? = nil,
         ticks: @escaping () -> UInt32 = { SystemClock.ticks }) {
        self.ticks = ticks
        self.resources = resources
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
        case "StopAlert":
            guard let resources, let dialogs, let screen = quickDraw.mainDevice else { return false }
            let arguments = withUnsafeBytes(of: frame.gpr) { bytes in
                let registers = bytes.bindMemory(to: UInt32.self)
                return (Int16(truncatingIfNeeded: registers[0]), registers[1])
            }
            guard arguments.1 == 0 else { return false } // A guest filter requires callback execution.
            do {
                let alert = try GuestAlert(id: arguments.0, resources: resources, parameters: dialogs.parameterText)
                alert.draw(on: screen, fonts: initializeFonts(), font: dialogs.font)
                pendingAlert = alert
                return false // Suspend at the import; do not return an invented item number.
            } catch {
                lastResourceError = error.code
                return false
            }
        case "GetResource", "Get1Resource", "GetString":
            guard let writeGuest else { return false }
            let arguments = withUnsafeBytes(of: frame.gpr) { bytes in
                let registers = bytes.bindMemory(to: UInt32.self)
                return (registers[0], registers[1])
            }
            let key = GuestResourceKey(type: symbol.symbol == "GetString" ? "STR " : FourCharCode(arguments.0),
                                       id: Int16(truncatingIfNeeded: symbol.symbol == "GetString" ? arguments.0 : arguments.1))
            frame.returnGPR = loadResource(key, write: writeGuest)
        case "ReleaseResource", "DetachResource":
            let handle = withUnsafeBytes(of: frame.gpr) { $0.bindMemory(to: UInt32.self)[0] }
            if resourceHandles.values.contains(handle) {
                if symbol.symbol == "ReleaseResource" {
                    guard let writeGuest else { return false }
                    heap.disposeHandle(handle, write: writeGuest)
                }
                if heap.memoryFault == nil {
                    resourceHandles = resourceHandles.filter { $0.value != handle }
                    lastResourceError = 0
                }
            } else {
                lastResourceError = MacError.resourceNotFound.code
            }
        case "BlockMove", "BlockMoveData", "BlockMoveUncached", "BlockMoveDataUncached":
            guard let readGuest, let writeGuest else { return false }
            let arguments = withUnsafeBytes(of: frame.gpr) { bytes in
                let registers = bytes.bindMemory(to: UInt32.self)
                return (registers[0], registers[1], registers[2])
            }
            do {
                try GuestBlockMove.copy(source: arguments.0, destination: arguments.1, count: arguments.2,
                                        read: readGuest, write: writeGuest)
            } catch {
                guestMemoryFault = error
                return false
            }
        case "p2cstr", "P2CStr", "c2pstr", "C2PStr",
             "p2cstrcpy", "c2pstrcpy", "CopyPascalStringToC", "CopyCStringToPascal":
            guard let readGuest, let writeGuest else { return false }
            let arguments = withUnsafeBytes(of: frame.gpr) { bytes in
                let registers = bytes.bindMemory(to: UInt32.self)
                return (registers[0], registers[1])
            }
            let inPlace = ["p2cstr", "P2CStr", "c2pstr", "C2PStr"].contains(symbol.symbol)
            let destinationFirst = symbol.symbol == "p2cstrcpy" || symbol.symbol == "c2pstrcpy"
            let source = destinationFirst ? arguments.1 : arguments.0
            let destination = inPlace ? arguments.0 : (destinationFirst ? arguments.0 : arguments.1)
            do {
                if ["p2cstr", "P2CStr", "p2cstrcpy", "CopyPascalStringToC"].contains(symbol.symbol) {
                    try GuestStringConversion.pascalToC(source: source, destination: destination,
                                                       read: readGuest, write: writeGuest)
                } else {
                    try GuestStringConversion.cToPascal(source: source, destination: destination,
                                                       read: readGuest, write: writeGuest)
                }
                if inPlace { frame.returnGPR = arguments.0 }
            } catch {
                guestMemoryFault = error
                return false
            }
        case "GetIndString":
            guard let writeGuest else { return false }
            let arguments = withUnsafeBytes(of: frame.gpr) { bytes in
                let registers = bytes.bindMemory(to: UInt32.self)
                return (registers[0], Int16(truncatingIfNeeded: registers[1]), Int16(truncatingIfNeeded: registers[2]))
            }
            let string: PascalString
            do throws(MacError) {
                guard let resources else { throw MacError.resourceNotFound }
                let list = try StringList(bytes: resources.bytes(type: StringList.resourceType, id: arguments.1))
                string = list[Int(arguments.2)]
                lastResourceError = 0
            } catch {
                lastResourceError = error.code
                string = PascalString()
            }
            guard writeGuest(arguments.0, string.lengthPrefixed) else {
                guestMemoryFault = ToolboxMemoryFault(address: arguments.0, write: true)
                return false
            }
        case "ResError":
            frame.returnGPR = UInt32(bitPattern: lastResourceError)
        case "Gestalt":
            let arguments = withUnsafeBytes(of: frame.gpr) { bytes in
                let registers = bytes.bindMemory(to: UInt32.self)
                return (FourCharCode(rawValue: registers[0]), registers[1])
            }
            do {
                let response = try gestalt.response(for: arguments.0)
                guard let writeGuest else { return false }
                var writer = BigEndianWriter(capacity: 4)
                writer.write(response)
                guard writeGuest(arguments.1, writer.bytes) else {
                    guestMemoryFault = ToolboxMemoryFault(address: arguments.1, write: true)
                    return false
                }
                frame.returnGPR = 0
            } catch {
                frame.returnGPR = UInt32(bitPattern: error.code)
            }
        case "MaxApplZone":
            heap.maximizeApplicationZone()
        case "MoreMasters":
            guard let writeGuest else { return false }
            heap.moreMasters(write: writeGuest)
        case "NewPtr", "NewPtrClear", "NewHandle", "NewHandleClear", "NewEmptyHandle":
            guard let writeGuest else { return false }
            let size = withUnsafeBytes(of: frame.gpr) { Int32(bitPattern: $0.bindMemory(to: UInt32.self)[0]) }
            if symbol.symbol == "NewPtr" || symbol.symbol == "NewPtrClear" {
                frame.returnGPR = heap.newPointer(size: size, clear: symbol.symbol == "NewPtrClear", write: writeGuest)
            } else {
                frame.returnGPR = heap.newHandle(size: symbol.symbol == "NewEmptyHandle" ? 0 : size,
                                               clear: symbol.symbol == "NewHandleClear", write: writeGuest)
            }
        case "DisposePtr", "DisposPtr", "DisposeHandle", "DisposHandle", "GetPtrSize", "GetHandleSize":
            let address = withUnsafeBytes(of: frame.gpr) { $0.bindMemory(to: UInt32.self)[0] }
            switch symbol.symbol {
            case "DisposePtr", "DisposPtr": heap.disposePointer(address)
            case "DisposeHandle", "DisposHandle":
                guard let writeGuest else { return false }
                heap.disposeHandle(address, write: writeGuest)
                if heap.memoryFault == nil, heap.lastError == 0 {
                    resourceHandles = resourceHandles.filter { $0.value != address }
                }
            case "GetPtrSize": frame.returnGPR = UInt32(bitPattern: heap.pointerSize(address))
            default: frame.returnGPR = UInt32(bitPattern: heap.handleSize(address))
            }
        case "MemError":
            frame.returnGPR = UInt32(bitPattern: Int32(heap.lastError))
        case "FreeMem":
            frame.returnGPR = heap.freeBytes
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
        if let fault = heap.memoryFault {
            guestMemoryFault = fault
            return false
        }
        handledImportCount += 1
        return true
    }

    /// Keep one loaded guest handle per application resource until release or detach.
    private mutating func loadResource(_ key: GuestResourceKey, write: (UInt32, [UInt8]) -> Bool) -> UInt32 {
        if let handle = resourceHandles[key] {
            lastResourceError = 0
            return handle
        }
        do throws(MacError) {
            guard let resources else { throw MacError.resourceNotFound }
            let bytes = try resources.bytes(type: key.type, id: key.id)
            let handle = heap.loadedHandle(bytes: bytes, write: write)
            guard handle != 0 else {
                lastResourceError = heap.lastError == 0 ? -108 : Int32(heap.lastError)
                return 0
            }
            resourceHandles[key] = handle
            lastResourceError = 0
            return handle
        } catch {
            lastResourceError = error.code
            return 0
        }
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
