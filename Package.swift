// swift-tools-version: 6.4
import PackageDescription

// PEFKit includes fragment preparation, format parsers, relocation, and resource-fork readers.
// BlueBox maps prepared sections into its emulated guest address space and runs bounded calls.
// PEFKit is Foundation-free. CResourceIO isolates platform xattr calls from the format parsers.
// Embedded Swift is not enabled or validated yet; it also needs BinaryParsingEmbedded.

let package = Package(
    name: "swift-pef",
    platforms: [.macOS(.v26)],
    products: [
        .library(
            name: "PEFKit",
            targets: ["PEFKit"]
        ),
        .library(
            name: "PPC32Core",
            targets: ["PPC32Core"]
        ),
        .executable(
            name: "bluebox",
            targets: ["BlueBox"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/PureSwift/Graphite.git", branch: "master"),
        .package(url: "https://github.com/apple/swift-binary-parsing.git", .upToNextMinor(from: "0.0.4"))
    ],
    targets: [
        .target(
            name: "CMORA",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CMusashi",
            publicHeadersPath: "include",
            cSettings: [
                .define("MUSASHI_CNF", to: "\"m68kconf.h\"")
            ]
        ),
        .target(
            name: "CResourceIO",
            publicHeadersPath: "include"
        ),
        .target(
            name: "PEFKit",
            dependencies: [
                "CResourceIO",
                .product(name: "BinaryParsing", package: "swift-binary-parsing")
            ]
        ),
        // Clean-room user-mode PowerPC 32-bit interpreter. Standard library only (no Foundation).
        .target(
            name: "PPC32Core"
        ),
        .executableTarget(
            name: "BlueBox",
            dependencies: [
                "PEFKit",
                "PPC32Core",
                "CMORA",
                "CMusashi",
                .product(name: "Graphite", package: "Graphite")
            ]
        ),
        .testTarget(
            name: "PEFKitTests",
            dependencies: [
                "PEFKit",
                .product(name: "BinaryParsing", package: "swift-binary-parsing")
            ]
        ),
        .testTarget(
            name: "PPC32CoreTests",
            dependencies: ["PPC32Core"]
        ),
        .testTarget(
            name: "BlueBoxTests",
            dependencies: ["BlueBox", "CMORA"]
        )
    ]
)
