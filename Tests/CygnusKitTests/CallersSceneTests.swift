import Testing
import Foundation
@testable import CygnusKit

struct CallersSceneTests {
    private func node(_ id: String, _ kind: String) -> GraphSnapshot.Node {
        GraphSnapshot.Node(id: id, kind: kind, label: id)
    }

    @Test func liftsSymbolRefsToEnclosingTypesAndAggregates() {
        // TypeA declares a(); TypeB declares b(). a() and (again) TypeA
        // itself reference b() → A→B caller edge, weight summed.
        let snapshot = GraphSnapshot(
            nodes: [
                node("A", "core:type"), node("A.a", "core:function"),
                node("B", "core:type"), node("B.b", "core:function"),
            ],
            edges: [
                GraphSnapshot.Edge(from: "A", to: "A.a", kind: "core:declares"),
                GraphSnapshot.Edge(from: "B", to: "B.b", kind: "core:declares"),
                GraphSnapshot.Edge(from: "A.a", to: "B.b", kind: "core:refersToSymbol", weight: 3),
                GraphSnapshot.Edge(from: "A", to: "B.b", kind: "core:refersToSymbol", weight: 2),
            ])
        let scene = GraphScene.callers(from: snapshot)
        #expect(scene.edges.count == 1)
        let edge = scene.edges[0]
        #expect(edge.from == "A" && edge.to == "B")
        #expect(edge.weight == 5)                      // 3 + 2 aggregated
        #expect(Set(scene.nodes.map(\.id)) == ["A", "B"])   // types only
    }

    @Test func selfReferencesWithinAClassAreDropped() {
        let snapshot = GraphSnapshot(
            nodes: [node("A", "core:type"), node("A.a", "core:function"), node("A.b", "core:function")],
            edges: [
                GraphSnapshot.Edge(from: "A", to: "A.a", kind: "core:declares"),
                GraphSnapshot.Edge(from: "A", to: "A.b", kind: "core:declares"),
                GraphSnapshot.Edge(from: "A.a", to: "A.b", kind: "core:refersToSymbol", weight: 1),
            ])
        #expect(GraphScene.callers(from: snapshot).edges.isEmpty)   // A→A dropped
    }
}
