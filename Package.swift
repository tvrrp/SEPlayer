// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SEPlayer",
    platforms: [.iOS(.v15), .macOS(.v12), .macCatalyst(.v15), .tvOS(.v15), .visionOS(.v1)],
    products: [
        .library(name: "SEPlayerCommon", targets: ["SEPlayerCommon"]),
        .library(name: "DataSource", targets: ["DataSource"]),
        .library(name: "Extractor", targets: ["Extractor"]),
        .library(name: "SEPlayer", targets: ["SEPlayer"]),
    ],
    traits: createExtractorTraits(),
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", .upToNextMajor(from: "1.6.0")),
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
//                .product(name: "Atomics", package: "swift-atomics"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
//                .enableExperimentalFeature("NonisolatedNonsendingByDefault"),
//                .enableUpcomingFeature("MemberImportVisibility"),
//                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .target(
            name: "Extractor",
            dependencies: [
                "SEPlayerCommon",
                .product(name: "OrderedCollections", package: "swift-collections"),
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
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableExperimentalFeature("Lifetimes"),
//                .enableUpcomingFeature("MemberImportVisibility"),
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
        ),
    ]
)

func createExtractorTraits() -> Set<Trait> {
    let extractors = [
        "ExtractorMP4",
        "ExtractorFMP4",
        "ExtractorTS",
    ]

    var traits: Set<Trait> = .init(
        extractors.map {
            Trait.trait(name: $0)
        }
    )
    traits.insert(.default(enabledTraits: .init(extractors)))

    return traits
}
