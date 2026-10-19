// swift-tools-version: 6.2
import PackageDescription

// Windows installer analysis: finds the installer and its parts, checks them,
// and reads what an Inno Setup installer will do, without running it.
let package = Package(
    name: "InstallerKit",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "InstallerKit", targets: ["InstallerKit"]),
        .executable(name: "installer-inspect", targets: ["installer-inspect"]),
    ],
    targets: [
        .target(name: "InstallerKit", swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(
            name: "installer-inspect",
            dependencies: ["InstallerKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Fixtures are read from the source tree by path
        .testTarget(name: "InstallerKitTests", dependencies: ["InstallerKit"], exclude: ["Fixtures"]),
    ]
)
