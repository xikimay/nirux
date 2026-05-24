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
            revision: "91efe702f1afb06e5b4c1e6c40351c5f6b900e98"
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
