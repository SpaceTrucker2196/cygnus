// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CygnusCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CygnusEngine", targets: ["CygnusEngine"]),
        .library(name: "CygnusGraph", targets: ["CygnusGraph"]),
        .library(name: "CygnusStore", targets: ["CygnusStore"]),
        .library(name: "CygnusQuery", targets: ["CygnusQuery"]),
        .executable(name: "cygnus", targets: ["cygnus"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "601.0.0"..<"700.0.0"),
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter.git", from: "0.9.0"),
        // Grammars are pinned exact — runtime/grammar ABI churn is the
        // known papercut (MISSION.md §5). python is held at 0.23.6:
        // 0.25.0's manifest probes src/scanner.c with a relative path
        // that fails under SwiftPM's manifest sandbox, dropping the
        // external scanner and breaking the link.
        .package(url: "https://github.com/tree-sitter/tree-sitter-python.git", exact: "0.23.6"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-c.git", exact: "0.24.2"),
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
            "CygnusProviders",
            .product(name: "SwiftSyntax", package: "swift-syntax"),
            .product(name: "SwiftParser", package: "swift-syntax"),
        ]),
        .target(name: "CygnusExtractorTS", dependencies: [
            "CygnusGraph",
            "CygnusObservation",
            "CygnusProviders",
            .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
            .product(name: "TreeSitterPython", package: "tree-sitter-python"),
            .product(name: "TreeSitterC", package: "tree-sitter-c"),
        ]),

        // Reads the graph, writes derived-layer facts only.
        .target(name: "CygnusDerive", dependencies: ["CygnusGraph"]),

        // Query surface: subgraph fetch, projections, search, diff.
        .target(name: "CygnusQuery", dependencies: ["CygnusGraph", "CygnusStore"]),

        // Facade the app-side kit and the CLI consume.
        .target(name: "CygnusEngine", dependencies: [
            "CygnusGraph", "CygnusStore", "CygnusProviders", "CygnusObservation",
            "CygnusExtractorSwift", "CygnusExtractorTS", "CygnusDerive", "CygnusQuery",
        ]),

        .executableTarget(name: "cygnus", dependencies: ["CygnusEngine", "CygnusStore", "CygnusQuery", "CygnusGraph"]),

        .testTarget(name: "GraphTests", dependencies: ["CygnusGraph"]),
        .testTarget(name: "ExtractorSwiftTests", dependencies: ["CygnusExtractorSwift", "CygnusProviders"]),
        .testTarget(name: "EngineTests", dependencies: ["CygnusEngine", "CygnusQuery"]),
        .testTarget(name: "StoreTests", dependencies: ["CygnusStore"]),
        .testTarget(name: "ProviderTests", dependencies: ["CygnusProviders"]),
        .testTarget(name: "ExtractorTSTests", dependencies: ["CygnusExtractorTS"]),
    ]
)
