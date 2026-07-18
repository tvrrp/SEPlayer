// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SEPlayer",
    platforms: [.iOS(.v15), .macOS(.v12), .macCatalyst(.v15), .tvOS(.v15), .visionOS(.v1)],
    products: [
        .library(name: "SEPlayerCommon", targets: ["SEPlayerCommon"]),
        .library(name: "DataSource", targets: ["DataSource"]),
        .library(name: "Extractor", targets: ["Extractor"]),
        .library(name: "Decoder", targets: ["Decoder"]),
        .library(name: "SEPlayer", targets: ["SEPlayer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", exact: "1.3.1"),
    ],
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
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableExperimentalFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("MemberImportVisibility"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .target(
            name: "Extractor",
            dependencies: [
                "SEPlayerCommon",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .target(
            name: "Decoder",
            dependencies: [
                "SEPlayerCommon",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableUpcomingFeature("MemberImportVisibility"),
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
                .enableExperimentalFeature("Lifetimes"),
                .enableUpcomingFeature("MemberImportVisibility"),
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
