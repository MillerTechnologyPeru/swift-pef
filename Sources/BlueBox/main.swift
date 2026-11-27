import Foundation
import PEFKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

let usage = "Usage: bluebox [--max-instructions N] [--entry main|init|term] [--framebuffer output.ppm] <PEF-or-MacBinary-path>"
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    print(usage)
    exit(0)
}

do {
    var path: String?
    var limit = 100_000
    var entry = BlueBoxEntry.main
    var framebufferPath: String?
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--max-instructions" || argument == "--entry" || argument == "--framebuffer" {
            index += 1
            guard index < arguments.count else { throw BlueBoxError.invalidArguments(usage) }
            if argument == "--max-instructions" {
                guard let value = Int(arguments[index]), value > 0 else {
                    throw BlueBoxError.invalidArguments("Instruction limit must be a positive integer")
                }
                limit = value
            } else if argument == "--framebuffer" {
                framebufferPath = arguments[index]
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
    let application = try BlueBoxApplication.load(path: path)
    let report = try application.dataFork.withUnsafeBytes { bytes in
        try BlueBoxRunner.run(bytes: bytes, resourceFork: application.resourceFork,
                             captureFramebuffer: framebufferPath != nil,
                             entry: entry, maxInstructions: limit)
    }
    print("Loaded \(report.sectionCount) sections; entry=\(hex(report.codeAddress)), toc=\(hex(report.toc)), sp=\(hex(report.initialStackPointer))")
    print(report.diagnostic)
    print("Serviced \(report.handledImportCount) Toolbox imports")
    if let framebufferPath, let ppm = report.framebufferPPM {
        try Data(ppm).write(to: URL(fileURLWithPath: framebufferPath))
        print("Framebuffer written to \(framebufferPath)")
    }
    switch report.execution.stop {
    case .returned: exit(0)
    case .instructionLimit: exit(124)
    default: exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("bluebox: \(error)\n".utf8))
    exit(2)
}
