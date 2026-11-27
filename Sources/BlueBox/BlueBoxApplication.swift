import Foundation
import PEFKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Owns both forks while the runner prepares guest memory. Native forks take precedence over sidecars.
struct BlueBoxApplication {
    let dataFork: Data
    let resourceFork: [UInt8]?

    static func load(path: String) throws -> BlueBoxApplication {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        if data.prefix(8) != Data("Joy!peff".utf8) {
            return try data.withUnsafeBytes { bytes in
                let archive = try MacBinaryReader.parse(bytes)
                return BlueBoxApplication(dataFork: Data(archive.dataFork),
                                          resourceFork: archive.resourceFork.isEmpty ? nil : Array(archive.resourceFork))
            }
        }
        if let native = try nativeResourceFork(path: path) {
            return BlueBoxApplication(dataFork: data, resourceFork: native)
        }
        let sidecar = url.deletingLastPathComponent().appendingPathComponent("._" + url.lastPathComponent)
        guard FileManager.default.fileExists(atPath: sidecar.path) else {
            return BlueBoxApplication(dataFork: data, resourceFork: nil)
        }
        let fork = try Data(contentsOf: sidecar).withUnsafeBytes { bytes in
            try AppleDoubleReader.resourceFork(in: bytes).map { Array($0) }
        }
        return BlueBoxApplication(dataFork: data, resourceFork: fork)
    }

    private static func nativeResourceFork(path: String) throws -> [UInt8]? {
        do {
            return try path.withCString { path in
                let count = try XattrResourceReader.byteCount(path: path)
                guard count > 0 else { return nil }
                var bytes = [UInt8](repeating: 0, count: count)
                let read = try bytes.withUnsafeMutableBytes { try XattrResourceReader.read(path: path, into: $0) }
                return Array(bytes.prefix(read))
            }
        } catch PEFError.resourceIOFailed(let code) {
            #if canImport(Darwin)
            if code == ENOATTR || code == ENOTSUP { return nil }
            #elseif canImport(Glibc)
            if code == ENODATA || code == ENOTSUP { return nil }
            #endif
            throw PEFError.resourceIOFailed(code)
        }
    }
}
