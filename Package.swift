// swift-tools-version: 6.0
import PackageDescription

let embeddedSwiftSettings: [SwiftSetting] = [
    // Embedded Swift only applies on the Linux ppc32 target; Darwin hosts build PEFKit normally.
    .enableExperimentalFeature("Embedded", .when(platforms: [.linux])),
    .unsafeFlags(["-wmo", "-Xfrontend", "-disable-stack-protector"], .when(platforms: [.linux]))
]

let package = Package(
    name: "swift-pef",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "PEFKit",
            targets: ["PEFKit"]
        ),
        .executable(
            name: "bluebox",
            targets: ["BlueBox"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/PureSwift/Graphite.git", branch: "master")
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
            swiftSettings: embeddedSwiftSettings
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
            dependencies: ["PEFKit"]
        ),
        .testTarget(
            name: "BlueBoxTests",
            dependencies: ["BlueBox", "CMORA"]
        )
    ]
)
