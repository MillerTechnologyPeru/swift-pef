import Foundation
import Testing
@testable import PEFKit

private let fixtureRoot = ProcessInfo.processInfo.environment["PEF_FIXTURES_DIR"].map {
    URL(fileURLWithPath: $0, isDirectory: true)
} ?? URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent(".build/fixtures", isDirectory: true)

private let realApplications = [
    "extracted/macgzip/MacGzip/MacGzip",
    "extracted/maczip/MacZip 1.06 crypt final/MacZip crypt (FAT)",
    "extracted/bbedit/volume/BBEdit Lite 6.1/BBEdit Lite 6.1",
    "extracted/bbedit/volume/BBEdit Lite 6.1/BBEdit Lite 6.1 for OS X"
] + [
    "Columnize", "Concatenate", "Convert To ASCII", "Educate Quotes", "Hex Dump",
    "Line Numbers", "Machine Info", "Make Prototypes", "Prefix_Suffix Line",
    "Process Lines Containing", "Sort Lines"
].map { "extracted/bbedit/volume/BBEdit Lite 6.1/BBEdit Lite Support/Plug-Ins/" + $0 }

/// Optional local fixtures: archives remain outside source control under .build/fixtures.
@Suite(.enabled(if: FileManager.default.fileExists(atPath: fixtureRoot.appendingPathComponent("manifest.json").path)))
struct RealApplicationTests {
    @Test(arguments: realApplications)
    func prepareRealFragment(_ relativePath: String) throws {
        let url = fixtureRoot.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        try data.withUnsafeBytes { bytes in
            let container = try PEFContainer(bytes: bytes)
            guard let loader = try container.loaderSection() else {
                Issue.record("Missing loader in \(relativePath)")
                return
            }
            var allocations: [PEFSectionAllocation] = []
            defer {
                for allocation in allocations { allocation.bytes.baseAddress?.deallocate() }
            }
            var nextAddress: UInt64 = 0x0100_0000
            for index in 0..<Int(container.header.instSectionCount) {
                let section = try container.section(at: index)
                guard section.totalLength <= 64 * 1024 * 1024 else {
                    Issue.record("Unexpected fixture section size")
                    return
                }
                let alignment = UInt64(1) << section.alignment
                nextAddress = (nextAddress + alignment - 1) / alignment * alignment
                let length = Int(section.totalLength)
                let pointer = UnsafeMutableRawPointer.allocate(byteCount: max(1, length), alignment: 16)
                allocations.append(PEFSectionAllocation(
                    guestAddress: UInt32(nextAddress),
                    bytes: UnsafeMutableRawBufferPointer(start: pointer, count: length)
                ))
                nextAddress += UInt64(max(1, length))
            }
            var imports = [UInt32](repeating: 0, count: Int(loader.info.totalImportedSymbolCount))
            var symbolIndex: UInt32 = 0
            try imports.withUnsafeMutableBufferPointer { imports in
                try loader.resolveImports(
                    into: imports,
                    resolveLibrary: { (library, _) throws(PEFError) in library.nameOffset },
                    resolveSymbol: { (_, _, _) throws(PEFError) in
                        defer { symbolIndex += 1 }
                        // Relocation placeholders only: these addresses do not implement Toolbox APIs.
                        return 0xF000_0000 + symbolIndex * 4
                    }
                )
            }
            var scratch = [UInt32](repeating: 0, count: allocations.count)
            let entries = try allocations.withUnsafeBufferPointer { allocations in
                try imports.withUnsafeBufferPointer { imports in
                    try scratch.withUnsafeMutableBufferPointer { scratch in
                        try container.prepare(sections: allocations, importedAddresses: imports,
                                              relocationScratch: scratch)
                    }
                }
            }
            // A relocated PPC entry record must point into one of the fragment's code sections.
            for address in [entries.main, entries.initialize, entries.terminate].compactMap({ $0 }) {
                let recordAllocation = allocations.first {
                    UInt64(address) >= UInt64($0.guestAddress)
                        && UInt64(address) + 8 <= UInt64($0.guestAddress) + UInt64($0.bytes.count)
                }
                let allocation = try #require(recordAllocation)
                let offset = Int(address - allocation.guestAddress)
                let codeAddress = UInt32(bigEndian: allocation.bytes.loadUnaligned(
                    fromByteOffset: offset, as: UInt32.self
                ))
                var pointsIntoCode = false
                for index in allocations.indices {
                    let kind = try container.section(at: index).kind
                    if kind != .code && kind != .executableData { continue }
                    let code = allocations[index]
                    if UInt64(codeAddress) >= UInt64(code.guestAddress),
                       UInt64(codeAddress) < UInt64(code.guestAddress) + UInt64(code.bytes.count) {
                        pointsIntoCode = true
                    }
                }
                #expect(pointsIntoCode)
            }
            let addresses = allocations.map(\.guestAddress)
            for index in 0..<Int(loader.info.exportedSymbolCount) {
                let symbol = try loader.exportedSymbol(at: index)
                let exportName = loader.name(of: symbol)
                let name = try #require(exportName)
                let found = name.bindMemory(to: UInt8.self)
                let lookup = loader.findExport(named: found)
                #expect(lookup?.symbolOffset == symbol.symbolOffset)
                _ = try addresses.withUnsafeBufferPointer { addresses in
                    try imports.withUnsafeBufferPointer { imports in
                        try loader.address(of: symbol, sectionAddresses: addresses, importedAddresses: imports)
                    }
                }
            }
            print("PEF prepared: \(relativePath); sections=\(allocations.count), imports=\(imports.count), main=\(String(describing: entries.main))")
        }
    }

    @Test(arguments: realApplications)
    func parseRealResourceFork(_ relativePath: String) throws {
        let url = fixtureRoot.appendingPathComponent(relativePath)
        let sidecar = url.deletingLastPathComponent().appendingPathComponent("._" + url.lastPathComponent)
        let data = try Data(contentsOf: sidecar)
        try data.withUnsafeBytes { bytes in
            let resourceBytes = try AppleDoubleReader.resourceFork(in: bytes)
            let bytes = try #require(resourceBytes)
            let fork = try ResourceFork(bytes: bytes)
            let count = fork.typeCount
            #expect(count > 0)
            for index in 0..<count {
                let resourceCount = try fork.resourceCount(atTypeIndex: index)
                for resource in 0..<resourceCount {
                    _ = try fork.resource(atTypeIndex: index, resourceIndex: resource)
                }
            }
        }
    }
}
