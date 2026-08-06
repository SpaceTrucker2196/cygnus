import Testing
import CygnusGraph
@testable import CygnusQuery

// PageRank exists so truncation drops the least important results
// rather than arbitrary ones. That only holds if it is deterministic
// and its ordering is defensible, so both are pinned here.

@Suite struct CentralityTests {
    private func id(_ value: Int64) -> EntityID { EntityID(value) }

    @Test func emptyGraphRanksNothing() {
        #expect(Centrality.pageRank(nodes: [], edges: []).isEmpty)
    }

    /// The node everything points at outranks the ones pointing.
    @Test func aHubOutranksItsReferrers() {
        let ranks = Centrality.pageRank(
            nodes: [id(1), id(2), id(3)],
            edges: [(id(1), id(3), 1), (id(2), id(3), 1)])
        #expect((ranks[id(3)] ?? 0) > (ranks[id(1)] ?? 0))
        #expect((ranks[id(3)] ?? 0) > (ranks[id(2)] ?? 0))
    }

    /// Edge weight is reference count, so a heavily-used dependency
    /// should outrank a barely-used one.
    @Test func weightMovesRank() {
        let ranks = Centrality.pageRank(
            nodes: [id(1), id(2), id(3)],
            edges: [(id(1), id(2), 10), (id(1), id(3), 1)])
        #expect((ranks[id(2)] ?? 0) > (ranks[id(3)] ?? 0))
    }

    /// Personalization is what turns "important here" into "important
    /// for this task".
    @Test func personalizationBiasesTowardTheSeed() {
        let nodes = [id(1), id(2), id(3)]
        let edges: [(EntityID, EntityID, Double)] = [(id(1), id(2), 1), (id(2), id(3), 1)]
        let uniform = Centrality.pageRank(nodes: nodes, edges: edges)
        let seeded = Centrality.pageRank(nodes: nodes, edges: edges, personalization: [id(1)])
        #expect((seeded[id(1)] ?? 0) > (uniform[id(1)] ?? 0))
    }

    /// A dangling node must not leak rank out of the system, or scores
    /// stop being comparable across graphs.
    @Test func rankIsConservedWithDanglingNodes() {
        let ranks = Centrality.pageRank(
            nodes: [id(1), id(2), id(3)],
            edges: [(id(1), id(2), 1)])   // 2 and 3 have no outgoing edges
        let total = ranks.values.reduce(0, +)
        #expect(abs(total - 1.0) < 0.0001)
    }

    @Test func resultsAreDeterministic() {
        let nodes = (1...20).map { id(Int64($0)) }
        let edges = (1...19).map { (id(Int64($0)), id(Int64($0 + 1)), Double($0)) }
        let runs = (0..<3).map { _ in
            Centrality.pageRank(nodes: nodes, edges: edges)
                .sorted { $0.key.raw < $1.key.raw }.map(\.value)
        }
        #expect(runs[0] == runs[1])
        #expect(runs[1] == runs[2])
    }
}
