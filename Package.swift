// swift-tools-version: 6.4
import PackageDescription

// PEFKit is not built with Embedded Swift for now. It stays Foundation-free (it imports only
// BinaryParsing and the standard library) so Embedded can be re-enabled on it later by adding
// `.enableExperimentalFeature("Embedded")` and depending on `BinaryParsingEmbedded`.

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
            name: "PEFKit",
            dependencies: [
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
