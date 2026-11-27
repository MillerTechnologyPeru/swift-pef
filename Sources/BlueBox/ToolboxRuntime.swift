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
    let appleEventHandlers = GuestAppleEventHandlers()
    private var routineDescriptors: Set<UInt32> = []
    private var fileManager: GuestFileManager
    private var appleEventDescriptors = GuestAppleEventDescriptors()
    private var launchEventAvailable = true
    private var deliveredAppleEventRecord: [UInt8]?
    private var appleEventCallbackActive = false
    private var callbackRecords: UInt32?
    private(set) var pendingAppleEventCallback: GuestPPCInvocation?


    /// Low-level event kinds in chronological order; host input delivery is still pending.
    var pendingEventKinds: [UInt16] = []

    /// Supplied screen memory must outlive this runtime and its QuickDraw objects.
    init(screenPixels: UnsafeMutableRawPointer? = nil,
         resources: ResourceFile? = nil,
         files: [GuestFile] = [],
         ticks: @escaping () -> UInt32 = { SystemClock.ticks }) {
        self.ticks = ticks
        self.resources = resources
        fileManager = GuestFileManager(files: files)
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
        case "FSpOpenDF", "FSpOpenRF", "FSClose", "FSRead", "GetEOF", "GetFPos", "SetFPos", "FSMakeFSSpec":
            guard let readGuest, let writeGuest else { return false }
            do {
                try dispatchFileManager(symbol.symbol, frame: &frame, read: readGuest, write: writeGuest)
            } catch let fault as ToolboxMemoryFault {
                guestMemoryFault = fault
                return false
            } catch let error as MacError {
                frame.returnGPR = UInt32(bitPattern: error.code)
            } catch { return false }
        case "GetCurrentISA":
            frame.returnGPR = 1
        case "NewRoutineDescriptor":
            guard let writeGuest else { return false }
            let a = withUnsafeBytes(of: frame.gpr) { Array($0.bindMemory(to: UInt32.self).prefix(3)) }
            guard UInt8(truncatingIfNeeded: a[2]) == 1 else { return false }
            if a[0] == 0 { frame.returnGPR = 0; break }
            let pointer = heap.newPointer(size: Int32(GuestRoutineDescriptor.byteCount), clear: false, write: writeGuest)
            frame.returnGPR = pointer
            if pointer != 0 {
                guard writeGuest(pointer, GuestRoutineDescriptor.bytes(vector: a[0], procInfo: a[1])) else {
                    heap.disposePointer(pointer)
                    guestMemoryFault = ToolboxMemoryFault(address: pointer, write: true)
                    return false
                }
                routineDescriptors.insert(pointer)
            }
        case "DisposeRoutineDescriptor":
            let pointer = withUnsafeBytes(of: frame.gpr) { $0.bindMemory(to: UInt32.self)[0] }
            if routineDescriptors.remove(pointer) != nil { heap.disposePointer(pointer) }
        case "AECreateDesc", "AEDuplicateDesc", "AEDisposeDesc", "AEGetDescData", "AEGetDescDataSize",
             "AECreateList", "AECountItems", "AEPutDesc", "AEPutPtr", "AEGetNthDesc", "AEDeleteItem",
             "AEGetAttributeDesc", "AEGetParamDesc", "AEGetAttributePtr", "AEGetParamPtr", "AECreateAppleEvent", "AEProcessAppleEvent",
             "GetNextEvent", "EventAvail", "WaitNextEvent":
            guard let readGuest, let writeGuest else { return false }
            if symbol.symbol == "WaitNextEvent" {
                let arguments = withUnsafeBytes(of: frame.gpr) { Array($0.bindMemory(to: UInt32.self)) }
                guard arguments[2] == 0, arguments[3] == 0 else { return false }
            }
            do {
                try dispatchAppleEvent(symbol.symbol, frame: &frame, read: readGuest, write: writeGuest)
            } catch let fault as ToolboxMemoryFault {
                guestMemoryFault = fault
                return false
            } catch let error as MacError {
                frame.returnGPR = UInt32(bitPattern: error.code)
            } catch {
                return false
            }
        case "AEInstallEventHandler", "AEGetEventHandler", "AERemoveEventHandler":
            let arguments = withUnsafeBytes(of: frame.gpr) { Array($0.bindMemory(to: UInt32.self).prefix(5)) }
            do throws(MacError) {
                switch symbol.symbol {
                case "AEInstallEventHandler":
                    try appleEventHandlers.install(eventClass: arguments[0], eventID: arguments[1],
                        procedure: arguments[2], referenceConstant: arguments[3],
                        isSystem: UInt8(truncatingIfNeeded: arguments[4]) != 0)
                case "AERemoveEventHandler":
                    try appleEventHandlers.remove(eventClass: arguments[0], eventID: arguments[1],
                        procedure: arguments[2], isSystem: UInt8(truncatingIfNeeded: arguments[3]) != 0)
                default:
                    guard let entry = appleEventHandlers.entry(eventClass: arguments[0], eventID: arguments[1],
                        isSystem: UInt8(truncatingIfNeeded: arguments[4]) != 0) else { throw MacError.handlerNotFound }
                    guard let writeGuest else { return false }
                    for (address, value) in [(arguments[2], UInt32(entry.procedure)),
                                              (arguments[3], UInt32(entry.referenceConstant))] {
                        var writer = BigEndianWriter(capacity: 4)
                        writer.write(value)
                        guard writeGuest(address, writer.bytes) else {
                            guestMemoryFault = ToolboxMemoryFault(address: address, write: true)
                            return false
                        }
                    }
                }
                frame.returnGPR = 0
            } catch {
                frame.returnGPR = UInt32(bitPattern: error.code)
            }
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
            case "DisposePtr", "DisposPtr":
                heap.disposePointer(address)
                if heap.lastError == 0 { routineDescriptors.remove(address) }
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

// MARK: Guest AppleEvent descriptors and the initial host launch event
extension ToolboxRuntime {
    mutating func takeAppleEventCallback() -> GuestPPCInvocation? {
        defer { pendingAppleEventCallback = nil }
        return pendingAppleEventCallback
    }

    mutating func completeAppleEventCallback(read: (UInt32, Int) -> [UInt8]?,
                                            write: (UInt32, [UInt8]) -> Bool) {
        defer { callbackRecords = nil; appleEventCallbackActive = false }
        guard let records = callbackRecords else { return }
        for address in [records, records + 8] {
            do { try appleEventDescriptors.dispose(at: address, heap: &heap, read: read, write: write) }
            catch let fault as ToolboxMemoryFault { guestMemoryFault = fault }
            catch { /* A guest may already have disposed a borrowed descriptor. */ }
        }
        heap.disposePointer(records)
    }

    private mutating func dispatchAppleEvent(_ name: String, frame: inout MORAInvocationFrame,
        read: (UInt32, Int) -> [UInt8]?, write: (UInt32, [UInt8]) -> Bool) throws {
        typealias Coding = GuestAppleEventDescriptors
        let a = withUnsafeBytes(of: frame.gpr) { Array($0.bindMemory(to: UInt32.self)) }
        frame.returnGPR = 0
        switch name {
        case "GetNextEvent", "EventAvail", "WaitNextEvent":
            // Headless retrieval only: sleeping and mouse-region transitions require a host event source.
            if name == "WaitNextEvent", a[2] != 0 || a[3] != 0 { throw MacError.unimplemented }
            let found = launchEventAvailable && UInt16(truncatingIfNeeded: a[0]) & 0x0400 != 0
            let record: [UInt8] = found
                ? [0, 23] + Coding.word(AppleEvent.Core.eventClass.rawValue) + Coding.word(ticks())
                    + Coding.word(AppleEvent.Core.openApplication.rawValue) + [0, 0]
                : [0, 0] + Coding.word(0) + Coding.word(ticks()) + [0, 0, 0, 0, 0, 0]
            try Coding.write(a[1], bytes: record, using: write)
            if found, name != "EventAvail" {
                launchEventAvailable = false
                deliveredAppleEventRecord = record
            }
            frame.returnGPR = found ? 1 : 0
        case "AECreateDesc":
            try Coding.write(a[3], bytes: Coding.word(DescriptorType.null.rawValue) + Coding.word(0), using: write)
            guard Int32(bitPattern: a[2]) >= 0 else { throw MacError.parameter }
            // Structured descriptors require their specific creation APIs.
            let type = FourCharCode(a[0])
            guard type != DescriptorType.appleEvent, type != DescriptorType.list,
                  type != DescriptorType.record else { throw MacError.unimplemented }
            let bytes = a[2] == 0 || type == DescriptorType.null ? []
                : try Coding.read(a[1], count: Int(a[2]), using: read)
            try appleEventDescriptors.store(Descriptor(type: type, bytes: bytes), at: a[3], heap: &heap, write: write)
        case "AECreateList":
            try Coding.write(a[3], bytes: Coding.word(DescriptorType.null.rawValue) + Coding.word(0), using: write)
            guard Int32(bitPattern: a[1]) >= 0 else { throw MacError.parameter }
            guard a[1] == 0 else { throw MacError.unimplemented } // Factored arrays require a separate bridge.
            let value = UInt8(truncatingIfNeeded: a[2]) == 0 ? Descriptor.list() : Descriptor.record()
            try appleEventDescriptors.store(value, at: a[3], heap: &heap, write: write)
        case "AECountItems":
            let value = try appleEventDescriptors.load(at: a[0], heap: &heap, read: read)
            guard value.isList || value.isRecord else { throw MacError.wrongDataType }
            try Coding.write(a[1], bytes: Coding.word(UInt32(value.count)), using: write)
        case "AEPutDesc", "AEPutPtr", "AEDeleteItem":
            var value = try appleEventDescriptors.load(at: a[0], heap: &heap, read: read)
            guard value.isList else { throw MacError.wrongDataType }
            let index = Int(Int32(bitPattern: a[1]))
            if name == "AEDeleteItem" { try value.removeItem(at: index) }
            else {
                let item: Descriptor
                if name == "AEPutDesc" {
                    item = try appleEventDescriptors.load(at: a[2], heap: &heap, read: read)
                } else {
                    guard Int32(bitPattern: a[4]) >= 0 else { throw MacError.parameter }
                    let type = FourCharCode(a[2])
                    guard type != DescriptorType.list, type != DescriptorType.record,
                          type != DescriptorType.appleEvent else { throw MacError.unimplemented }
                    let bytes = a[4] == 0 || type == DescriptorType.null ? []
                        : try Coding.read(a[3], count: Int(a[4]), using: read)
                    item = Descriptor(type: type, bytes: bytes)
                }
                try value.put(item, at: index)
            }
            try appleEventDescriptors.update(value, at: a[0], heap: &heap, read: read)
        case "AEGetNthDesc":
            let value = try appleEventDescriptors.load(at: a[0], heap: &heap, read: read)
            guard value.isList || value.isRecord else { throw MacError.wrongDataType }
            let item = try value.item(at: Int(Int32(bitPattern: a[1])))
            guard a[2] == DescriptorType.wildCard.rawValue || a[2] == item.descriptor.type.rawValue else {
                throw MacError.coercionFailed
            }
            if a[3] != 0 { try Coding.write(a[3], bytes: Coding.word(item.keyword.rawValue), using: write) }
            try appleEventDescriptors.store(item.descriptor, at: a[4], heap: &heap, write: write)
        case "AEDuplicateDesc":
            let value = try appleEventDescriptors.load(at: a[0], heap: &heap, read: read)
            try appleEventDescriptors.store(value, at: a[1], heap: &heap, write: write)
        case "AEDisposeDesc":
            try appleEventDescriptors.dispose(at: a[0], heap: &heap, read: read, write: write)
        case "AEGetDescData", "AEGetDescDataSize":
            let value = try appleEventDescriptors.load(at: a[0], heap: &heap, read: read)
            guard !value.isAppleEvent, !value.isList, !value.isKeyed else { throw MacError.unimplemented }
            if name == "AEGetDescDataSize" { frame.returnGPR = UInt32(value.bytes.count) }
            else {
                guard Int32(bitPattern: a[2]) >= 0 else { throw MacError.parameter }
                let bytes = Array(value.bytes.prefix(Int(a[2])))
                if !bytes.isEmpty { try Coding.write(a[1], bytes: bytes, using: write) }
            }
        case "AECreateAppleEvent":
            let target = try appleEventDescriptors.load(at: a[2], heap: &heap, read: read)
            let event = AppleEvent(eventClass: FourCharCode(a[0]), eventID: FourCharCode(a[1]), target: target,
                                   returnID: Int16(truncatingIfNeeded: a[3]), transactionID: Int32(bitPattern: a[4]))
            try appleEventDescriptors.store(event.descriptor, at: a[5], heap: &heap, write: write)
        case "AEGetAttributeDesc", "AEGetParamDesc", "AEGetAttributePtr", "AEGetParamPtr":
            let value = try appleEventDescriptors.load(at: a[0], heap: &heap, read: read)
            let attribute = name.hasPrefix("AEGetAttribute")
            guard value.isAppleEvent else { throw MacError.notAppleEvent }
            guard let item = attribute ? value.attribute(FourCharCode(a[1])) : value[FourCharCode(a[1])] else {
                throw MacError.descriptorNotFound
            }
            guard a[2] == DescriptorType.wildCard.rawValue || a[2] == item.type.rawValue else { throw MacError.coercionFailed }
            // Graphite stores scalar attributes in host order; guest records are big-endian.
            var guestItem = item
            if attribute, [AppleEvent.Attribute.eventClass, AppleEvent.Attribute.eventID].contains(FourCharCode(a[1])),
               let code = item.code { guestItem.bytes = Coding.word(code.rawValue) }
            if attribute, FourCharCode(a[1]) == AppleEvent.Attribute.returnID {
                let id = UInt16(bitPattern: item.load(as: Int16.self) ?? 0)
                guestItem.bytes = [UInt8(id >> 8), UInt8(truncatingIfNeeded: id)]
            }
            if attribute, FourCharCode(a[1]) == AppleEvent.Attribute.transactionID {
                guestItem.bytes = Coding.word(UInt32(bitPattern: item.load(as: Int32.self) ?? 0))
            }
            if name.hasSuffix("Ptr") {
                guard Int32(bitPattern: a[5]) >= 0 else { throw MacError.parameter }
                try Coding.write(a[3], bytes: Coding.word(guestItem.type.rawValue), using: write)
                try Coding.write(a[6], bytes: Coding.word(UInt32(guestItem.bytes.count)), using: write)
                let bytes = Array(guestItem.bytes.prefix(Int(a[5])))
                if !bytes.isEmpty { try Coding.write(a[4], bytes: bytes, using: write) }
            } else {
                try appleEventDescriptors.store(guestItem, at: a[3], heap: &heap, write: write)
            }
        case "AEProcessAppleEvent":
            guard !appleEventCallbackActive else { throw MacError.unimplemented }
            let record = try Coding.read(a[0], count: 16, using: read)
            guard record == deliveredAppleEventRecord else { throw MacError.eventNotHandled }
            deliveredAppleEventRecord = nil
            let event = AppleEvent(eventClass: AppleEvent.Core.eventClass, eventID: AppleEvent.Core.openApplication)
            guard let handler = appleEventHandlers.handler(for: event) else { throw MacError.eventNotHandled }
            let records = heap.newPointer(size: 16, clear: true, write: write)
            if let fault = heap.memoryFault { throw fault }
            guard records != 0 else { throw MacError(Int32(heap.lastError)) }
            do {
                try appleEventDescriptors.store(event.descriptor, at: records, heap: &heap, write: write)
                do {
                    try appleEventDescriptors.store(AppleEvent.reply(to: event).descriptor, at: records + 8, heap: &heap, write: write)
                } catch {
                    try? appleEventDescriptors.dispose(at: records, heap: &heap, read: read, write: write)
                    throw error
                }
            } catch { heap.disposePointer(records); throw error }
            callbackRecords = records
            appleEventCallbackActive = true
            pendingAppleEventCallback = GuestPPCInvocation(vector: UInt32(handler.procedure),
                arguments: [records, records + 8, UInt32(handler.referenceConstant)],
                procInfo: GuestRoutineDescriptor.appleEventHandlerProcInfo)
        default: throw MacError.unimplemented
        }
    }
}

// MARK: Read-only File Manager
extension ToolboxRuntime {
    private mutating func dispatchFileManager(_ name: String, frame: inout MORAInvocationFrame,
        read: (UInt32, Int) -> [UInt8]?, write: (UInt32, [UInt8]) -> Bool) throws {
        typealias Coding = GuestAppleEventDescriptors
        let a = withUnsafeBytes(of: frame.gpr) { Array($0.bindMemory(to: UInt32.self)) }
        let reference = Int16(truncatingIfNeeded: a[0])
        frame.returnGPR = 0
        switch name {
        case "FSpOpenDF", "FSpOpenRF":
            let spec = try GuestFileManager.spec(Coding.read(a[0], count: 70, using: read))
            let reference = try fileManager.open(spec, permission: Int8(truncatingIfNeeded: a[1]), resource: name == "FSpOpenRF")
            let bits = UInt16(bitPattern: reference)
            do { try Coding.write(a[2], bytes: [UInt8(bits >> 8), UInt8(truncatingIfNeeded: bits)], using: write) }
            catch { try? fileManager.close(reference); throw error }
        case "FSClose": try fileManager.close(reference)
        case "GetEOF", "GetFPos":
            let value = try name == "GetEOF" ? fileManager.size(reference) : fileManager.position(reference)
            try Coding.write(a[1], bytes: Coding.word(value), using: write)
        case "SetFPos":
            try fileManager.seek(reference, mode: UInt16(truncatingIfNeeded: a[1]), offset: Int32(bitPattern: a[2]))
        case "FSRead":
            let count = Int32(bitPattern: Coding.word(try Coding.read(a[1], count: 4, using: read)))
            let eof = try fileManager.read(reference, count: count, output: { bytes in
                if !bytes.isEmpty { try Coding.write(a[2], bytes: bytes, using: write) }
                try Coding.write(a[1], bytes: Coding.word(UInt32(bytes.count)), using: write)
            })
            if eof { frame.returnGPR = UInt32(bitPattern: MacError.endOfFile.code) }
        case "FSMakeFSSpec":
            let length = try Coding.read(a[2], count: 1, using: read)[0]
            guard length <= 63 else { throw MacError.badName }
            let bytes = try Coding.read(a[2], count: Int(length) + 1, using: read)
            let spec = FileSpec(volume: reference == 0 ? GuestFileManager.volume : reference,
                                parent: DirectoryID(a[1] == 0 ? 2 : a[1]), name: PascalString(bytes: Array(bytes.dropFirst())))
            try Coding.write(a[3], bytes: GuestFileManager.bytes(spec), using: write)
            try fileManager.validate(spec)
        default: throw MacError.unimplemented
        }
    }
}
