// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CygnusCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CygnusEngine", targets: ["CygnusEngine"]),
        .executable(name: "cygnus", targets: ["cygnus"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "601.0.0"..<"700.0.0"),
    ],
    targets: [
        // Pure model. Depends on nothing; everyone depends on it.
        .target(name: "CygnusGraph"),

        // The only target allowed to import GRDB.
        .target(name: "CygnusStore", dependencies: [
            "CygnusGraph",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),

        // Providers expose observable facts; they never interpret.
        .target(name: "CygnusProviders", dependencies: ["CygnusGraph"]),

        // Observation types + extractor seam + pipeline orchestration.
        .target(name: "CygnusObservation", dependencies: ["CygnusGraph", "CygnusProviders"]),

        // Extractors emit observations; they never touch the store.
        .target(name: "CygnusExtractorSwift", dependencies: [
            "CygnusGraph",
            "CygnusObservation",
            .product(name: "SwiftSyntax", package: "swift-syntax"),
            .product(name: "SwiftParser", package: "swift-syntax"),
        ]),
        // tree-sitter runtime + python/c grammars land here (pinned) in E0 spike.
        .target(name: "CygnusExtractorTS", dependencies: ["CygnusGraph", "CygnusObservation"]),

        // Reads the graph, writes derived-layer facts only.
        .target(name: "CygnusDerive", dependencies: ["CygnusGraph"]),

        // Query surface: subgraph fetch, projections, search, diff.
        .target(name: "CygnusQuery", dependencies: ["CygnusGraph", "CygnusStore"]),

        // Facade the app-side kit and the CLI consume.
        .target(name: "CygnusEngine", dependencies: [
            "CygnusGraph", "CygnusStore", "CygnusProviders", "CygnusObservation",
            "CygnusExtractorSwift", "CygnusExtractorTS", "CygnusDerive", "CygnusQuery",
        ]),

        .executableTarget(name: "cygnus", dependencies: ["CygnusEngine"]),

        .testTarget(name: "GraphTests", dependencies: ["CygnusGraph"]),
        .testTarget(name: "StoreTests", dependencies: ["CygnusStore"]),
    ]
)
