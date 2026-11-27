import Graphite

/// A file explicitly mounted in the initial read-only guest volume.
struct GuestFile {
    let name: PascalString
    let dataFork: [UInt8]
    var resourceFork: [UInt8] = []
}

/// A single root directory of immutable snapshots, with independent marks per open fork.
/// Guest names are catalog keys; they are never interpreted as host filesystem paths.
struct GuestFileManager {
    static let volume: Int16 = -100
    private struct OpenFork {
        let bytes: [UInt8]
        var mark: Int = 0
    }
    private let files: [GuestFile]
    private var forks: [Int16: OpenFork] = [:]

    init(files: [GuestFile] = []) { self.files = files }

    static func spec(_ bytes: [UInt8]) throws(MacError) -> FileSpec {
        guard bytes.count == 70, bytes[6] <= 63 else { throw .badName }
        return FileSpec(volume: Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1])),
                        parent: DirectoryID(GuestAppleEventDescriptors.word(bytes, 2)),
                        name: PascalString(bytes: Array(bytes[7..<7 + Int(bytes[6])])))
    }

    static func bytes(_ spec: FileSpec) -> [UInt8] {
        let volume = UInt16(bitPattern: spec.volume)
        let name = Array(spec.name.bytes.prefix(63))
        return [UInt8(volume >> 8), UInt8(truncatingIfNeeded: volume)]
            + GuestAppleEventDescriptors.word(spec.parent.rawValue) + [UInt8(name.count)]
            + name + [UInt8](repeating: 0, count: 63 - name.count)
    }

    private func lookup(_ spec: FileSpec) throws(MacError) -> GuestFile {
        guard spec.volume == 0 || spec.volume == Self.volume else { throw .noSuchVolume }
        guard spec.parent.rawValue == 0 || spec.parent == .root else { throw .directoryNotFound }
        guard !spec.name.bytes.isEmpty, spec.name.bytes.count <= 63,
              !spec.name.bytes.contains(0), !spec.name.bytes.contains(58) else { throw .badName }
        guard let file = files.first(where: { $0.name.string.lowercased() == spec.name.string.lowercased() }) else {
            throw .fileNotFound
        }
        return file
    }

    func validate(_ spec: FileSpec) throws(MacError) { _ = try lookup(spec) }

    mutating func open(_ spec: FileSpec, permission: Int8, resource: Bool) throws(MacError) -> Int16 {
        guard (0...4).contains(permission) else { throw .parameter }
        let file = try lookup(spec)
        guard permission == 0 || permission == 1 else { throw .permission }
        let bytes = resource ? file.resourceFork : file.dataFork
        guard bytes.count <= Int32.max else { throw MacError(-108) }
        guard let reference = (Int16(128)..<384).first(where: { forks[$0] == nil }) else { throw .tooManyFilesOpen }
        forks[reference] = OpenFork(bytes: bytes)
        return reference
    }

    mutating func close(_ reference: Int16) throws(MacError) {
        guard forks.removeValue(forKey: reference) != nil else { throw .referenceNumber }
    }

    func size(_ reference: Int16) throws(MacError) -> UInt32 {
        guard let fork = forks[reference] else { throw .referenceNumber }
        return UInt32(fork.bytes.count)
    }

    func position(_ reference: Int16) throws(MacError) -> UInt32 {
        guard let fork = forks[reference] else { throw .referenceNumber }
        return UInt32(fork.mark)
    }

    mutating func seek(_ reference: Int16, mode: UInt16, offset: Int32) throws(MacError) {
        guard var fork = forks[reference] else { throw .referenceNumber }
        fork.mark = try positionedMark(fork, mode: mode, offset: offset)
        forks[reference] = fork
    }

    private func positionedMark(_ fork: OpenFork, mode: UInt16, offset: Int32) throws(MacError) -> Int {
        guard mode <= 3 else { throw .parameter }
        let mark: Int64
        switch ForkPosition(mode: mode, offset: Int64(offset)) {
        case .start(let offset): mark = offset
        case .end(let offset): mark = Int64(fork.bytes.count) + offset
        case .mark(let offset): mark = Int64(fork.mark) + offset
        }
        guard mark >= 0 else { throw .position }
        guard mark <= fork.bytes.count else { throw .endOfFile }
        return Int(mark)
    }

    /// Commit the mark only after checked guest output succeeds.
    mutating func read(_ reference: Int16, count: Int32,
                       output: ([UInt8]) throws -> Void) throws -> Bool {
        try readPositioned(reference, count: count, mode: 0, offset: 0) { bytes, _ in try output(bytes) }
    }

    mutating func readPositioned(_ reference: Int16, count: Int32, mode: UInt16, offset: Int32,
                                output: ([UInt8], UInt32) throws -> Void) throws -> Bool {
        guard var fork = forks[reference] else { throw MacError.referenceNumber }
        guard count >= 0 else { throw MacError.parameter }
        fork.mark = try positionedMark(fork, mode: mode, offset: offset)
        let actual = min(Int(count), fork.bytes.count - fork.mark)
        let bytes = Array(fork.bytes[fork.mark..<fork.mark + actual])
        try output(bytes, UInt32(fork.mark + actual))
        fork.mark += actual
        forks[reference] = fork
        return actual < Int(count)
    }
}
