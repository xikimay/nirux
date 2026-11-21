// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NiruxCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "NiruxCore", targets: ["NiruxCore"])],
    targets: [
        .target(name: "NiruxCore"),
        .testTarget(name: "NiruxCoreTests", dependencies: ["NiruxCore"])
    ]
)
