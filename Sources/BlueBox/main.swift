import Foundation
import PEFKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

let usage = "Usage: bluebox [--max-instructions N] [--entry main|init|term] <PEF-or-MacBinary-path>"
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    print(usage)
    exit(0)
}

do {
    var path: String?
    var limit = 100_000
    var entry = BlueBoxEntry.main
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--max-instructions" || argument == "--entry" {
            index += 1
            guard index < arguments.count else { throw BlueBoxError.invalidArguments(usage) }
            if argument == "--max-instructions" {
                guard let value = Int(arguments[index]), value > 0 else {
                    throw BlueBoxError.invalidArguments("Instruction limit must be a positive integer")
                }
                limit = value
            } else {
                guard let value = BlueBoxEntry(rawValue: arguments[index]) else {
                    throw BlueBoxError.invalidArguments("Entry must be main, init, or term")
                }
                entry = value
            }
        } else {
            guard !argument.hasPrefix("--"), path == nil else { throw BlueBoxError.invalidArguments(usage) }
            path = argument
        }
        index += 1
    }
    guard let path else { throw BlueBoxError.invalidArguments(usage) }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let report = try data.withUnsafeBytes { bytes in
        if bytes.count >= 8, Array(bytes.prefix(8)) == Array("Joy!peff".utf8) {
            return try BlueBoxRunner.run(bytes: bytes, entry: entry, maxInstructions: limit)
        }
        let archive = try MacBinaryReader.parse(bytes)
        return try BlueBoxRunner.run(bytes: archive.dataFork, entry: entry, maxInstructions: limit)
    }
    print("Loaded \(report.sectionCount) sections; entry=\(hex(report.codeAddress)), toc=\(hex(report.toc)), sp=\(hex(report.initialStackPointer))")
    print(report.diagnostic)
    print("Serviced \(report.handledImportCount) Toolbox imports")
    switch report.execution.stop {
    case .returned: exit(0)
    case .instructionLimit: exit(124)
    default: exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("bluebox: \(error)\n".utf8))
    exit(2)
}
