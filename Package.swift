// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SEPlayer",
    platforms: [ .iOS(.v15)],
    products: [
        .library(name: "Common", targets: ["Common"]),
        .library(name: "SEPlayer", targets: ["SEPlayer"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Common",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "SEPlayer",
            dependencies: [
                "Common",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableExperimentalFeature("Lifetimes")
            ]
        ),
        .testTarget(
            name: "SEPlayerTests",
            dependencies: [
                "SEPlayer",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        )
    ]
)
