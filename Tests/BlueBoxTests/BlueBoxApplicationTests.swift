import Foundation
import Graphite
import Testing
@testable import BlueBox
#if canImport(Darwin)
import Darwin
#endif

@Suite struct BlueBoxApplicationTests {
    private func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    private func withFile(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("App")
        try Data("Joy!peff".utf8).write(to: path)
        try body(path)
    }

    private func sidecar(_ fork: [UInt8]) -> Data {
        Data(be32(0x00051607) + be32(0x00020000) + [UInt8](repeating: 0, count: 16)
             + [0, 1] + be32(2) + be32(38) + be32(UInt32(fork.count)) + fork)
    }

    @Test func loadsAppleDoubleResourceFork() throws {
        try withFile { url in
            let fork = ResourceMap.emptyFork
            try sidecar(fork).write(to: url.deletingLastPathComponent().appendingPathComponent("._App"))
            let app = try BlueBoxApplication.load(path: url.path)
            #expect(app.dataFork == Data("Joy!peff".utf8))
            #expect(app.resourceFork == fork)
        }
    }

    @Test func handlesAbsentForkAndRejectsMalformedSidecar() throws {
        try withFile { url in
            let app = try BlueBoxApplication.load(path: url.path)
            #expect(app.resourceFork == nil)
            try Data([1, 2, 3]).write(to: url.deletingLastPathComponent().appendingPathComponent("._App"))
            #expect(throws: (any Error).self) { try BlueBoxApplication.load(path: url.path) }
        }
    }

    @Test func loadsBothMacBinaryForks() throws {
        try withFile { url in
            let fork = ResourceMap.emptyFork
            var header = [UInt8](repeating: 0, count: 128)
            header[1] = 3
            header.replaceSubrange(2..<5, with: Array("App".utf8))
            header.replaceSubrange(83..<87, with: be32(8))
            header.replaceSubrange(87..<91, with: be32(UInt32(fork.count)))
            let bytes = header + Array("Joy!peff".utf8) + [UInt8](repeating: 0, count: 120) + fork
            try Data(bytes).write(to: url)
            let app = try BlueBoxApplication.load(path: url.path)
            #expect(app.dataFork == Data("Joy!peff".utf8))
            #expect(app.resourceFork == fork)
        }
    }

    #if canImport(Darwin)
    @Test func nativeResourceForkTakesPrecedenceOverSidecar() throws {
        try withFile { url in
            let fork = ResourceMap.emptyFork
            let result = url.path.withCString { path in
                fork.withUnsafeBytes { Darwin.setxattr(path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, 0) }
            }
            #expect(result == 0)
            try Data([1, 2, 3]).write(to: url.deletingLastPathComponent().appendingPathComponent("._App"))
            let app = try BlueBoxApplication.load(path: url.path)
            #expect(app.resourceFork == fork)
        }
    }
    #endif
}
