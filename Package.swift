// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Nirux",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(
            url: "https://github.com/xikimay/libghostty-spm.git",
            revision: "c6843ec0762923357f8c2905381d0a556caa50c1"
        ),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Nirux",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Nirux",
            resources: [
                .copy("EditorAssets")
            ]
        ),
        .testTarget(
            name: "NiruxTests",
            dependencies: ["Nirux"],
            path: "Tests/NiruxTests"
        )
    ]
)
