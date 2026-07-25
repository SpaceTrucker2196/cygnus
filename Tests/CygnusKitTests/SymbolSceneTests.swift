import Testing
import Foundation
@testable import CygnusKit

struct SymbolSceneTests {
    @Test func symbolsSceneChartsOnlyRefersToSymbolEdges() {
        let snapshot = GraphSnapshot(
            nodes: [
                GraphSnapshot.Node(id: "d:A", kind: "core:function", label: "a()", path: "A.swift"),
                GraphSnapshot.Node(id: "d:B", kind: "core:type", label: "B", path: "B.swift"),
                GraphSnapshot.Node(id: "f:A", kind: "core:file", label: "A.swift", path: "A.swift"),
            ],
            edges: [
                GraphSnapshot.Edge(from: "d:A", to: "d:B", kind: "core:refersToSymbol"),
                GraphSnapshot.Edge(from: "f:A", to: "d:A", kind: "core:declares"),
            ])
        let scene = GraphScene.symbols(from: snapshot)
        #expect(scene.edges.count == 1)
        #expect(Set(scene.nodes.map(\.id)) == ["d:A", "d:B"])   // file node excluded
        #expect(GraphScene.symbols(from: .sample).nodes.isEmpty) // none in fixture
    }
}
