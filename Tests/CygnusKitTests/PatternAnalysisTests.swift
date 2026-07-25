import Testing
import Foundation
@testable import CygnusKit

struct PatternAnalysisTests {
    private func edge(_ from: String, _ to: String) -> GraphSnapshot.Edge {
        GraphSnapshot.Edge(from: from, to: to, kind: "core:references")
    }
    private func scene(_ ids: [String], _ edges: [(String, String)]) -> GraphScene {
        GraphScene(
            nodes: ids.map { GraphSnapshot.Node(id: $0, kind: "core:file", label: $0) },
            edges: edges.map { edge($0.0, $0.1) })
    }

    @Test func detectsCycleEdgesAndSparesAcyclicOnes() {
        // A→B→C→A is a cycle; D→A is a feeder (not on a cycle).
        let s = scene(["A", "B", "C", "D"],
                      [("A","B"), ("B","C"), ("C","A"), ("D","A")])
        let cyclic = s.cyclicEdges
        #expect(cyclic.contains("A\u{1}B"))
        #expect(cyclic.contains("B\u{1}C"))
        #expect(cyclic.contains("C\u{1}A"))
        #expect(!cyclic.contains("D\u{1}A"))
    }

    @Test func acyclicGraphHasNoCycleEdges() {
        let s = scene(["A", "B", "C"], [("A","B"), ("B","C"), ("A","C")])
        #expect(s.cyclicEdges.isEmpty)
    }

    @Test func selfLoopIsACycle() {
        let s = scene(["A"], [("A","A")])
        #expect(s.cyclicEdges.contains("A\u{1}A"))
    }

    @Test func deepChainDoesNotStackOverflow() {
        // 20k-node chain with a back edge closing one big cycle —
        // iterative Tarjan must handle it.
        let ids = (0..<20_000).map { "n\($0)" }
        var edges = (0..<19_999).map { ("n\($0)", "n\($0 + 1)") }
        edges.append(("n19999", "n0"))
        let s = scene(ids, edges)
        #expect(s.cyclicEdges.count == 20_000)
    }

    @Test func neighborhoodIsSelfPlusDirectNeighbors() {
        let index = SnapshotIndex(GraphSnapshot(
            nodes: ["A", "B", "C", "D"].map { GraphSnapshot.Node(id: $0, kind: "core:file", label: $0) },
            edges: [edge("A", "B"), edge("C", "A"), edge("B", "D")]))
        #expect(index.neighborhood(of: "A") == ["A", "B", "C"])   // out:B, in:C
    }
}
