import Testing
import Foundation
@testable import CygnusKit

// What the Code view charts. The rule that matters: a source file is
// present because it holds code, not because something imported it —
// an app whose every import is an Apple framework still has a graph.

@Suite struct DependencySceneTests {
    private func file(_ path: String) -> GraphSnapshot.Node {
        GraphSnapshot.Node(id: "phys:file:r/\(path)", kind: "core:file",
                           label: String(path.split(separator: "/").last ?? ""),
                           path: path)
    }

    /// Matches the resolver's key format — `isSystem` reads the
    /// language off the id, so a fake prefix would test nothing.
    private func module(_ name: String) -> GraphSnapshot.Node {
        GraphSnapshot.Node(id: "swift:module:\(name)", kind: "core:module", label: name)
    }

    private func declaration(_ name: String) -> GraphSnapshot.Node {
        GraphSnapshot.Node(id: "decl:\(name)", kind: "swift:type", label: name)
    }

    private func edge(_ from: GraphSnapshot.Node, _ to: GraphSnapshot.Node,
                      _ kind: String) -> GraphSnapshot.Edge {
        GraphSnapshot.Edge(from: from.id, to: to.id, kind: kind)
    }

    /// An Xcode app: SwiftUI/Foundation only, no internal modules.
    /// Every import is filtered as a system framework, so the scene
    /// has no edges at all — and must still chart both files.
    @Test func filesImportingOnlySystemFrameworksStillChart() {
        let view = file("Nighthawk/ScopeView.swift")
        let engine = file("Nighthawk/SynthEngine.swift")
        let snapshot = GraphSnapshot(
            nodes: [view, engine, module("SwiftUI"), module("Foundation"),
                    declaration("ScopeView"), declaration("SynthEngine")],
            edges: [edge(view, module("SwiftUI"), "core:imports"),
                    edge(engine, module("Foundation"), "core:imports"),
                    edge(view, declaration("ScopeView"), "core:declares"),
                    edge(engine, declaration("SynthEngine"), "core:declares")])

        let scene = GraphScene.dependencies(from: snapshot)
        #expect(scene.edges.isEmpty)
        #expect(Set(scene.nodes.map(\.label)) == ["ScopeView.swift", "SynthEngine.swift"])
    }

    /// Charting unwired files must not drag in every README and
    /// asset: a file earns its node by declaring something.
    @Test func filesWithoutDeclarationsDoNotChart() {
        let source = file("Nighthawk/Theme.swift")
        let readme = file("README.md")
        let assets = file("Nighthawk/Assets.xcassets/Contents.json")
        let snapshot = GraphSnapshot(
            nodes: [source, readme, assets, declaration("Theme")],
            edges: [edge(source, declaration("Theme"), "core:declares")])

        let scene = GraphScene.dependencies(from: snapshot)
        #expect(scene.nodes.map(\.label) == ["Theme.swift"])
    }

    /// The external-module filter still holds: system modules never
    /// chart (QuartzCore is an Apple framework, not a dependency),
    /// third-party ones only on request.
    @Test func externalModulesChartOnlyWhenRequested() {
        let source = file("Nighthawk/OscCore.swift")
        let snapshot = GraphSnapshot(
            nodes: [source, module("Atomics"), module("QuartzCore"), declaration("OscCore")],
            edges: [edge(source, module("Atomics"), "core:imports"),
                    edge(source, module("QuartzCore"), "core:imports"),
                    edge(source, declaration("OscCore"), "core:declares")])

        let hidden = GraphScene.dependencies(from: snapshot)
        #expect(hidden.edges.isEmpty)
        #expect(hidden.nodes.map(\.label) == ["OscCore.swift"])

        let shown = GraphScene.dependencies(from: snapshot, showExternal: true)
        #expect(shown.edges.map(\.to) == ["swift:module:Atomics"])
        #expect(Set(shown.nodes.map(\.label)) == ["OscCore.swift", "Atomics"])
    }
}
