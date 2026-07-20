// swift-tools-version: 6.0
// CygnusKit — app-side headless adapter between CygnusCore and the
// SwiftUI shell. Compiles standalone against the GraphEngine protocol
// (with FixtureGraphEngine for demos/tests) until the engine's facade
// is consumed; then the real engine is a one-file conformance.
import PackageDescription

let package = Package(
    name: "CygnusKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CygnusKit", targets: ["CygnusKit"]),
    ],
    targets: [
        .target(name: "CygnusKit"),
        .testTarget(name: "CygnusKitTests", dependencies: ["CygnusKit"]),
    ]
)
