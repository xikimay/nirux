// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NiruxCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "NiruxCore", targets: ["NiruxCore"])],
    targets: [
        .target(name: "NiruxCore"),
        // The nightly's changelog step (scripts/nightly-changelog.sh).
        .executableTarget(name: "nirux-changelog", dependencies: ["NiruxCore"]),
        .testTarget(name: "NiruxCoreTests", dependencies: ["NiruxCore"])
    ]
)
