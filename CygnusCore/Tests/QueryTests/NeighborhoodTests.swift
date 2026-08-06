import Testing
import Foundation
import CygnusGraph
import CygnusStore
@testable import CygnusQuery

// The blast-radius primitive. These pin the traversal's *behaviour*
// so it stays free to change shape underneath: the walk was rewritten
// to resolve each BFS level's endpoints in one query instead of one
// per node, and nothing here should have to change for that.

@Suite struct NeighborhoodTests {
    let repo = RepositoryID("test-repo")

    private func makeStore() throws -> SQLiteGraphStore {
        let store = try SQLiteGraphStore.inMemory()
        try store.registerRepository(repo, displayName: "Test Repo")
        return store
    }

    private func key(_ name: String) -> StableKey {
        StableKey("phys:file:test-repo/\(name)")
    }

    private func file(_ name: String) -> EntityAssertion {
        EntityAssertion(stableKey: key(name), kind: .file, repository: repo, name: name)
    }

    private func imports(_ from: String, _ to: String) -> RelationshipAssertion {
        RelationshipAssertion(source: key(from), target: key(to),
                              kind: .imports, layer: .observed)
    }

    /// A ── B ── C, plus D pointing at A, plus an unrelated island.
    private func makeChain() throws -> SQLiteGraphStore {
        let store = try makeStore()
        try store.commit(RevisionChanges(
            entities: ["A", "B", "C", "D", "Island"].map(file),
            relationships: [imports("A", "B"), imports("B", "C"), imports("D", "A")]),
            note: nil)
        return store
    }

    @Test func depthOneReachesImmediateNeighboursOnly() throws {
        let store = try makeChain()
        let sub = try Projections.neighborhood(store: store, of: key("A"), depth: 1)
        #expect(Set(sub.entities.map(\.version.name)) == ["A", "B", "D"])
    }

    /// Traversal is undirected — D→A is followed backwards from A.
    @Test func depthTwoReachesAcrossTheChainInBothDirections() throws {
        let store = try makeChain()
        let sub = try Projections.neighborhood(store: store, of: key("A"), depth: 2)
        #expect(Set(sub.entities.map(\.version.name)) == ["A", "B", "C", "D"])
        #expect(!sub.entities.map(\.version.name).contains("Island"))
    }

    @Test func kindFilterExcludesOtherEdges() throws {
        let store = try makeStore()
        try store.commit(RevisionChanges(
            entities: ["A", "B", "C"].map(file),
            relationships: [
                imports("A", "B"),
                RelationshipAssertion(source: key("A"), target: key("C"),
                                      kind: .references, layer: .derived),
            ]), note: nil)

        let sub = try Projections.neighborhood(
            store: store, of: key("A"), kinds: [.imports], depth: 1)
        #expect(Set(sub.entities.map(\.version.name)) == ["A", "B"])
        #expect(sub.relationships.allSatisfy { $0.kind == .imports })
    }

    /// A cycle must terminate rather than revisit — `seen` is the guard,
    /// and batching the level's resolution must not weaken it.
    @Test func cyclesTerminate() throws {
        let store = try makeStore()
        try store.commit(RevisionChanges(
            entities: ["A", "B", "C"].map(file),
            relationships: [imports("A", "B"), imports("B", "C"), imports("C", "A")]),
            note: nil)

        let sub = try Projections.neighborhood(store: store, of: key("A"), depth: 10)
        #expect(sub.entities.count == 3)
    }

    @Test func unknownOriginYieldsEmptySubgraph() throws {
        let store = try makeChain()
        let sub = try Projections.neighborhood(store: store, of: key("Nope"), depth: 2)
        #expect(sub.entities.isEmpty)
        #expect(sub.relationships.isEmpty)
    }

    @Test func depthZeroYieldsOnlyTheOrigin() throws {
        let store = try makeChain()
        let sub = try Projections.neighborhood(store: store, of: key("A"), depth: 0)
        #expect(sub.entities.map(\.version.name) == ["A"])
    }

    /// Results must be byte-identical across runs: truncation to a token
    /// budget happens downstream, so a wobbling order would silently
    /// change *which* results an agent is shown.
    @Test func resultsAreDeterministic() throws {
        let store = try makeChain()
        let runs = try (0..<5).map { _ in
            try Projections.neighborhood(store: store, of: key("A"), depth: 2)
                .entities.map(\.entity.stableKey.raw)
        }
        #expect(Set(runs.map { $0.joined(separator: ",") }).count == 1)
        #expect(runs[0] == runs[0].sorted())
    }
}
