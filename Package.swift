// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SEPlayer",
    platforms: [ .iOS(.v15)],
    products: [
        .library(name: "SEPlayerCommon", targets: ["SEPlayerCommon"]),
        .library(name: "DataSource", targets: ["DataSource"]),
        .library(name: "Extractor", targets: ["Extractor"]),
        .library(name: "Decoder", targets: ["Decoder"]),
        .library(name: "SEPlayer", targets: ["SEPlayer"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SEPlayerCommon",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("Lifetimes"),
            ]
        ),
        .target(
            name: "DataSource",
            dependencies: [
                "SEPlayerCommon",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .target(
            name: "Extractor",
            dependencies: [
                "SEPlayerCommon",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .target(
            name: "Decoder",
            dependencies: [
                "SEPlayerCommon",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .target(
            name: "SEPlayer",
            dependencies: [
                "SEPlayerCommon",
                "DataSource",
                "Extractor",
                "Decoder",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableExperimentalFeature("Lifetimes")
            ]
        ),
        .testTarget(
            name: "SEPlayerTests",
            dependencies: [
                "SEPlayerCommon",
                "DataSource",
                "Extractor",
                "SEPlayer",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        )
    ]
)
