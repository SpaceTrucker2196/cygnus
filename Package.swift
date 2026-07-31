// swift-tools-version: 6.0
// CygnusKit — app-side headless adapter between CygnusCore and the
// SwiftUI shell. The app imports only this package; the engine is
// reached through the GraphEngine seam (WorkspaceGraphEngine wraps
// the real CygnusWorkspace, FixtureGraphEngine serves tests/demos).
import PackageDescription

let package = Package(
    name: "CygnusKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CygnusKit", targets: ["CygnusKit"]),
    ],
    dependencies: [
        .package(path: "CygnusCore"),
    ],
    targets: [
        .target(name: "CygnusKit", dependencies: [
            .product(name: "CygnusEngine", package: "CygnusCore"),
            .product(name: "CygnusGraph", package: "CygnusCore"),
            .product(name: "CygnusStore", package: "CygnusCore"),
            .product(name: "CygnusQuery", package: "CygnusCore"),
            .product(name: "CygnusObservation", package: "CygnusCore"),
            .product(name: "CygnusProviders", package: "CygnusCore"),
        ],
        // The in-app help reference ships as markdown, not string
        // literals — prose stays reviewable in a diff.
        resources: [.copy("Resources/Help")]),
        .testTarget(name: "CygnusKitTests", dependencies: ["CygnusKit"]),
    ]
)
