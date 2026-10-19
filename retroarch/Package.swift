// swift-tools-version: 6.2
import PackageDescription

// The bundled RetroArch: its session over MCP, the cores downloaded per
// console, the BIOS check and the Settings > Consoles model
let package = Package(
    name: "RetroArchKit",
    defaultLocalization: "en",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "RetroArchKit", targets: ["RetroArchKit"]),
    ],
    targets: [
        .target(
            name: "RetroArchKit",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Stands in for RetroArch in the tests that need no real build
        .executableTarget(
            name: "fake-retroarch",
            path: "Tests/fake-retroarch",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RetroArchKitTests",
            dependencies: ["RetroArchKit", "fake-retroarch"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
