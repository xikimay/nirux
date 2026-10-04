// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Nirux",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Exact: TerminalScreenText reaches private parts of this version.
        .package(
            url: "https://github.com/Lakr233/libghostty-spm.git",
            exact: "1.3.1"
        ),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Nirux",
            dependencies: [
                .product(name: "GhosttyKit", package: "libghostty-spm"),
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Nirux",
            resources: [
                .copy("EditorAssets")
            ],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        // Runs NiruxTests' TestBootstrap as the test bundle loads: Swift
        // has no load-time hook, and a SwiftPM test bundle no principal class.
        .target(
            name: "NiruxTestBootstrap",
            path: "Tests/NiruxTestBootstrap"
        ),
        .testTarget(
            name: "NiruxTests",
            dependencies: ["Nirux", "NiruxTestBootstrap"],
            path: "Tests/NiruxTests"
        )
    ]
)
