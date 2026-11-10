// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Nirux",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Exact: TerminalScreenText reaches private parts of this version.
        // Temporary pin: libghostty-spm 2.2.2026110702 plus upstream PR #105
        // (Lakr233/libghostty-spm#105, finds the resource bundle in
        // Contents/Resources), one commit on the release tag, same binary.
        // Switch back to Lakr233's release once #105 ships.
        .package(
            url: "https://github.com/ventsislav-georgiev/libghostty-spm.git",
            revision: "634ffdf77f22132fc502374c8fd1819241b5693f"
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
