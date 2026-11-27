import CMORA
import Graphite
import Testing
@testable import BlueBox

@Suite struct GuestFileManagerTests {
    private var file: GuestFile {
        GuestFile(name: PascalString(bytes: Array("Read Me".utf8)), dataFork: [1, 2, 3, 4], resourceFork: [9, 8])
    }
    private var spec: FileSpec {
        FileSpec(volume: -100, parent: .root, name: PascalString(bytes: Array("read me".utf8)))
    }

    @Test func packedSpecAndIndependentForkMarks() throws {
        var manager = GuestFileManager(files: [file])
        let packed = GuestFileManager.bytes(spec)
        #expect(packed.count == 70)
        #expect(packed.prefix(7) == [0xFF, 0x9C, 0, 0, 0, 2, 7])
        #expect(try GuestFileManager.spec(packed) == spec)
        let first = try manager.open(spec, permission: 0, resource: false)
        let second = try manager.open(spec, permission: 1, resource: false)
        let resource = try manager.open(spec, permission: 1, resource: true)
        #expect(first != second)
        var bytes: [UInt8] = []
        let eof = try manager.read(first, count: 2) { bytes = $0 }
        #expect(!eof)
        #expect(bytes == [1, 2])
        #expect(try manager.position(first) == 2)
        #expect(try manager.position(second) == 0)
        #expect(try manager.size(resource) == 2)
        let partial = try manager.read(resource, count: 4) { bytes = $0 }
        #expect(partial)
        #expect(bytes == [9, 8])
        #expect(try manager.position(resource) == 2)
        try manager.close(first)
        #expect(throws: MacError.referenceNumber) { try manager.size(first) }
    }

    @Test func seeksAndFailedOutputPreservePosition() throws {
        var manager = GuestFileManager(files: [file])
        let reference = try manager.open(spec, permission: 1, resource: false)
        try manager.seek(reference, mode: 2, offset: -1)
        #expect(try manager.position(reference) == 3)
        #expect(throws: ToolboxMemoryFault(address: 0, write: true)) {
            try manager.read(reference, count: 1) { _ in throw ToolboxMemoryFault(address: 0, write: true) }
        }
        #expect(try manager.position(reference) == 3)
        try manager.seek(reference, mode: 3, offset: -2)
        try manager.seek(reference, mode: 0, offset: Int32.max)
        #expect(try manager.position(reference) == 1)
        #expect(throws: MacError.position) { try manager.seek(reference, mode: 1, offset: -1) }
        #expect(throws: MacError.endOfFile) { try manager.seek(reference, mode: 1, offset: 5) }
        #expect(throws: MacError.parameter) { try manager.read(reference, count: -1) { _ in } }
        #expect(try manager.position(reference) == 1)
    }

    @Test func catalogAndPermissionsReturnSpecificErrors() throws {
        var manager = GuestFileManager(files: [file])
        for permission: Int8 in [2, 3, 4] {
            #expect(throws: MacError.permission) { try manager.open(spec, permission: permission, resource: false) }
        }
        var invalid = spec
        invalid.volume = -1
        #expect(throws: MacError.noSuchVolume) { try manager.validate(invalid) }
        invalid = spec
        invalid.parent = DirectoryID(99)
        #expect(throws: MacError.directoryNotFound) { try manager.validate(invalid) }
        invalid = spec
        invalid.name = PascalString(bytes: Array("Missing".utf8))
        #expect(throws: MacError.fileNotFound) { try manager.validate(invalid) }
        invalid.name = PascalString(bytes: Array("::secret".utf8))
        #expect(throws: MacError.badName) { try manager.validate(invalid) }
        var references: [Int16] = []
        for _ in 0..<256 { references.append(try manager.open(spec, permission: 1, resource: false)) }
        #expect(throws: MacError.tooManyFilesOpen) { try manager.open(spec, permission: 1, resource: false) }
        try manager.close(references[0])
        #expect(try manager.open(spec, permission: 1, resource: false) == references[0])
    }

    @Test func runtimeWritesReferenceCountAndPartialEOFInGuestByteOrder() {
        var runtime = ToolboxRuntime(files: [file])
        var memory: [UInt32: UInt8] = [:]
        func put(_ address: UInt32, _ bytes: [UInt8]) {
            for (index, byte) in bytes.enumerated() { memory[address + UInt32(index)] = byte }
        }
        func get(_ address: UInt32, _ count: Int) -> [UInt8]? {
            let bytes = (0..<count).compactMap { memory[address + UInt32($0)] }
            return bytes.count == count ? bytes : nil
        }
        func call(_ name: String, _ arguments: [UInt32]) -> UInt32 {
            var frame = MORAInvocationFrame()
            withUnsafeMutableBytes(of: &frame.gpr) { bytes in
                let registers = bytes.bindMemory(to: UInt32.self)
                for (index, value) in arguments.enumerated() { registers[index] = value }
            }
            #expect(runtime.dispatch(GuestImport(library: "InterfaceLib", symbol: name, symbolClass: .tVector), frame: &frame,
                readGuest: get, writeGuest: { address, bytes in put(address, bytes); return true }))
            return frame.returnGPR
        }
        put(0x100, GuestFileManager.bytes(spec))
        #expect(call("FSpOpenDF", [0x100, 1, 0x200]) == 0)
        #expect(get(0x200, 2) == [0, 128])
        put(0x204, [0, 0, 0, 6])
        #expect(Int32(bitPattern: call("FSRead", [128, 0x204, 0x300])) == -39)
        #expect(get(0x204, 4) == [0, 0, 0, 4])
        #expect(get(0x300, 4) == [1, 2, 3, 4])
        #expect(call("GetFPos", [128, 0x208]) == 0)
        #expect(get(0x208, 4) == [0, 0, 0, 4])
        #expect(call("FSClose", [128]) == 0)
        #expect(Int32(bitPattern: call("FSClose", [128])) == -51)
    }
}
