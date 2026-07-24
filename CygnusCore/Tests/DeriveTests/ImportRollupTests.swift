import Testing
import Foundation
import CygnusGraph
import CygnusDerive
@testable import CygnusStore

// First real deriver: directory-level import rollups. Asserts the
// derived layer's contract — mechanical aggregation, provenance to
// the underlying observations, staleness retraction, idempotence.

@Suite struct ImportRollupTests {
    let repo = RepositoryID("test-repo")

    private func key(_ raw: String) -> StableKey { StableKey(raw) }

    private func entity(_ raw: String, kind: EntityKind, name: String,
                        shared: Bool = false) -> EntityAssertion {
        EntityAssertion(stableKey: key(raw), kind: kind,
                        repository: shared ? nil : repo, name: name)
    }

    private func contains(_ from: String, _ to: String) -> RelationshipAssertion {
        RelationshipAssertion(source: key(from), target: key(to),
                              kind: .containsPhysical, layer: .observed)
    }

    /// repo → A → (One.swift, Two.swift), A → B → Three.swift.
    /// One+Three import GRDB, Two imports Foundation.
    private func makeStore() throws -> (SQLiteGraphStore, imports: [ObservationID]) {
        let store = try SQLiteGraphStore.inMemory()
        try store.registerRepository(repo, displayName: "Test Repo")
        let snapshot = try store.recordSnapshot(repository: repo, sourceRef: nil)
        let observations = try store.recordObservations(
            (1...3).map { index in
                Observation(
                    kind: .importStatement,
                    file: SourceAnchor(path: "file\(index)", blob: BlobHash("blob\(index)"),
                                       range: nil),
                    payload: ["core:module": .string(index == 2 ? "Foundation" : "GRDB")],
                    extractor: ExtractorIdentity(name: "test", version: "0"))
            }, snapshot: snapshot)

        try store.commit(RevisionChanges(
            entities: [
                entity("repo", kind: .repository, name: "test-repo"),
                entity("dir:A", kind: .directory, name: "A"),
                entity("dir:A/B", kind: .directory, name: "B"),
                entity("file:One", kind: .file, name: "One.swift"),
                entity("file:Two", kind: .file, name: "Two.swift"),
                entity("file:Three", kind: .file, name: "Three.swift"),
                entity("mod:GRDB", kind: .module, name: "GRDB", shared: true),
                entity("mod:Foundation", kind: .module, name: "Foundation", shared: true),
            ],
            relationships: [
                contains("repo", "dir:A"),
                contains("dir:A", "file:One"),
                contains("dir:A", "file:Two"),
                contains("dir:A", "dir:A/B"),
                contains("dir:A/B", "file:Three"),
                RelationshipAssertion(source: key("file:One"), target: key("mod:GRDB"),
                                      kind: .imports, layer: .observed,
                                      supportedBy: [observations[0]]),
                RelationshipAssertion(source: key("file:Two"), target: key("mod:Foundation"),
                                      kind: .imports, layer: .observed,
                                      supportedBy: [observations[1]]),
                RelationshipAssertion(source: key("file:Three"), target: key("mod:GRDB"),
                                      kind: .imports, layer: .observed,
                                      supportedBy: [observations[2]]),
            ]), note: "observed")
        return (store, observations)
    }

    @Test func rollsUpSubtreeImportsWithCountsAndProvenance() throws {
        let (store, observations) = try makeStore()
        let changes = try ImportRollupDeriver().derive(from: store, repository: repo)
        try store.commit(changes, note: "derive")

        // A sees its own files plus B's subtree: GRDB ×2, Foundation ×1.
        let fromA = try store.relationships(from: key("dir:A"), kind: .dependsOn, at: .current)
        #expect(fromA.count == 2)
        let grdb = try #require(fromA.first {
            try! store.entities(ids: [$0.target], at: .current)
                .first?.entity.stableKey == key("mod:GRDB")
        })
        #expect(grdb.layer == .derived)
        #expect(grdb.properties[ImportRollupDeriver.countKey] == .int(2))
        // Provenance is the union of both GRDB import observations.
        #expect(Set(try store.provenance(ofRelationship: grdb.id))
                == [observations[0], observations[2]])

        // B rolls up only its own file.
        let fromB = try store.relationships(from: key("dir:A/B"), kind: .dependsOn, at: .current)
        #expect(fromB.count == 1)
        #expect(fromB[0].properties[ImportRollupDeriver.countKey] == .int(1))
    }

    @Test func rederiveIsIdempotent() throws {
        let (store, _) = try makeStore()
        try store.commit(try ImportRollupDeriver().derive(from: store, repository: repo),
                         note: "derive 1")
        let before = try store.relationships(from: key("dir:A"), kind: .dependsOn, at: .current)

        let second = try ImportRollupDeriver().derive(from: store, repository: repo)
        #expect(second.retractRelationships.isEmpty)
        try store.commit(second, note: "derive 2")
        let after = try store.relationships(from: key("dir:A"), kind: .dependsOn, at: .current)
        // Identical assertions dedupe: same relationship rows survive.
        #expect(before.map(\.id).sorted() == after.map(\.id).sorted())
    }

    @Test func staleRollupsAreRetractedWhenImportsVanish() throws {
        let (store, _) = try makeStore()
        try store.commit(try ImportRollupDeriver().derive(from: store, repository: repo),
                         note: "derive 1")

        // Three.swift (B's only import) goes away.
        let threeImport = try #require(
            try store.relationships(from: key("file:Three"), kind: .imports, at: .current).first)
        try store.commit(RevisionChanges(retractRelationships: [threeImport.id]),
                         note: "drop import")

        let changes = try ImportRollupDeriver().derive(from: store, repository: repo)
        try store.commit(changes, note: "derive 2")

        // B's rollup is gone; A's GRDB count drops to 1.
        #expect(try store.relationships(from: key("dir:A/B"), kind: .dependsOn, at: .current).isEmpty)
        let fromA = try store.relationships(from: key("dir:A"), kind: .dependsOn, at: .current)
        let grdb = try #require(fromA.first {
            try! store.entities(ids: [$0.target], at: .current)
                .first?.entity.stableKey == key("mod:GRDB")
        })
        #expect(grdb.properties[ImportRollupDeriver.countKey] == .int(1))
    }
}
