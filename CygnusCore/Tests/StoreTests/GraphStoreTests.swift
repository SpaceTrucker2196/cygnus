import Testing
import Foundation
import CygnusGraph
@testable import CygnusStore

// E1 acceptance: revision isolation ("query at R never sees R+1"),
// append-only history, dedupe, provenance, FTS.

@Suite struct GraphStoreTests {
    let repo = RepositoryID("test-repo")

    func makeStore() throws -> SQLiteGraphStore {
        let store = try SQLiteGraphStore.inMemory()
        try store.registerRepository(repo, displayName: "Test Repo")
        return store
    }

    func fileAssertion(_ name: String, props: PropertyBag = [:]) -> EntityAssertion {
        EntityAssertion(
            stableKey: StableKey("phys:file:test-repo/\(name)"),
            kind: .file, repository: repo, name: name, properties: props)
    }

    @Test func commitCreatesMonotonicRevisions() throws {
        let store = try makeStore()
        #expect(try store.currentRevision() == nil)
        let r1 = try store.commit(RevisionChanges(entities: [fileAssertion("A.swift")]), note: "first")
        let r2 = try store.commit(RevisionChanges(entities: [fileAssertion("B.swift")]), note: "second")
        #expect(r1 < r2)
        #expect(try store.currentRevision() == r2)
        #expect(try store.revisions().map(\.note) == ["first", "second"])
    }

    @Test func unchangedAssertionCreatesNoNewVersion() throws {
        let store = try makeStore()
        try store.commit(RevisionChanges(entities: [fileAssertion("A.swift")]), note: nil)
        let v1 = try #require(try store.entity(stableKey: StableKey("phys:file:test-repo/A.swift"), at: .current))
        try store.commit(RevisionChanges(entities: [fileAssertion("A.swift")]), note: nil)
        let v2 = try #require(try store.entity(stableKey: StableKey("phys:file:test-repo/A.swift"), at: .current))
        #expect(v1.version.id == v2.version.id)
        #expect(v2.version.validFrom.raw == 1)
    }

    @Test func changedStateClosesOldVersionAndPreservesHistory() throws {
        let store = try makeStore()
        let key = StableKey("phys:file:test-repo/A.swift")
        let r1 = try store.commit(
            RevisionChanges(entities: [fileAssertion("A.swift", props: ["core:loc": .int(10)])]),
            note: nil)
        let r2 = try store.commit(
            RevisionChanges(entities: [fileAssertion("A.swift", props: ["core:loc": .int(99)])]),
            note: nil)

        let current = try #require(try store.entity(stableKey: key, at: .current))
        #expect(current.version.properties["core:loc"] == .int(99))
        #expect(current.version.validFrom == r2)

        // Time travel: the graph at r1 still shows the old state.
        let historical = try #require(try store.entity(stableKey: key, at: .asOf(r1)))
        #expect(historical.version.properties["core:loc"] == .int(10))
        #expect(historical.version.validTo == r2)

        // Append-only: identity row and history survive; same entity id.
        #expect(historical.entity.id == current.entity.id)
        #expect(historical.entity.firstSeen == r1)
    }

    @Test func revisionIsolationQueryAtRNeverSeesRPlusOne() throws {
        let store = try makeStore()
        let r1 = try store.commit(RevisionChanges(entities: [fileAssertion("A.swift")]), note: nil)
        try store.commit(RevisionChanges(entities: [fileAssertion("B.swift")]), note: nil)

        let atR1 = try store.entities(kind: .file, at: .asOf(r1))
        #expect(atR1.map(\.version.name) == ["A.swift"])
        let current = try store.entities(kind: .file, at: .current)
        #expect(current.map(\.version.name) == ["A.swift", "B.swift"])
    }

    @Test func retractedEntityHiddenFromCurrentVisibleInHistory() throws {
        let store = try makeStore()
        let key = StableKey("phys:file:test-repo/A.swift")
        let r1 = try store.commit(RevisionChanges(entities: [fileAssertion("A.swift")]), note: nil)
        try store.commit(RevisionChanges(retractEntities: [key]), note: "file deleted")

        #expect(try store.entity(stableKey: key, at: .current) == nil)
        #expect(try store.entity(stableKey: key, at: .asOf(r1)) != nil)
    }

    @Test func relationshipsAssertDedupeRetractAndTimeTravel() throws {
        let store = try makeStore()
        let a = StableKey("phys:file:test-repo/A.swift")
        let b = StableKey("phys:file:test-repo/B.swift")
        let imports = RelationshipAssertion(source: a, target: b, kind: .imports, layer: .observed)

        let r1 = try store.commit(RevisionChanges(
            entities: [fileAssertion("A.swift"), fileAssertion("B.swift")],
            relationships: [imports]), note: nil)

        // Re-asserting the identical relationship dedupes.
        try store.commit(RevisionChanges(relationships: [imports]), note: nil)
        let current = try store.relationships(from: a, kind: .imports, at: .current)
        #expect(current.count == 1)
        let rel = try #require(current.first)
        #expect(rel.validFrom == r1)

        // Incoming query sees the same edge.
        #expect(try store.relationships(to: b, kind: nil, at: .current).count == 1)

        // Retract closes the interval; history intact.
        let r3 = try store.commit(RevisionChanges(retractRelationships: [rel.id]), note: nil)
        #expect(try store.relationships(from: a, kind: .imports, at: .current).isEmpty)
        let historical = try store.relationships(from: a, kind: .imports, at: .asOf(r1))
        #expect(historical.count == 1)
        #expect(historical.first?.validTo == r3)
    }

    @Test func relationshipToUnknownEntityThrows() throws {
        let store = try makeStore()
        try store.commit(RevisionChanges(entities: [fileAssertion("A.swift")]), note: nil)
        let bogus = RelationshipAssertion(
            source: StableKey("phys:file:test-repo/A.swift"),
            target: StableKey("phys:file:test-repo/Missing.swift"),
            kind: .imports, layer: .observed)
        #expect(throws: GraphStoreError.unknownEntity(StableKey("phys:file:test-repo/Missing.swift"))) {
            try store.commit(RevisionChanges(relationships: [bogus]), note: nil)
        }
        // The failed commit rolled back atomically: no revision recorded.
        #expect(try store.currentRevision()?.raw == 1)
    }

    @Test func searchFindsCurrentNamesNotRetracted() throws {
        let store = try makeStore()
        try store.commit(RevisionChanges(entities: [
            fileAssertion("HTTPClient.swift"),
            fileAssertion("HTTPServer.swift"),
            fileAssertion("Parser.swift"),
        ]), note: nil)

        let hits = try store.searchNames("HTTP", limit: 10)
        #expect(Set(hits.map(\.version.name)) == ["HTTPClient.swift", "HTTPServer.swift"])

        try store.commit(RevisionChanges(
            retractEntities: [StableKey("phys:file:test-repo/HTTPServer.swift")]), note: nil)
        let after = try store.searchNames("HTTP", limit: 10)
        #expect(after.map(\.version.name) == ["HTTPClient.swift"])
    }

    @Test func provenanceRoundTripsThroughObservations() throws {
        let store = try makeStore()
        let snapshot = try store.recordSnapshot(repository: repo, sourceRef: "deadbeef")
        let obsIDs = try store.recordObservations([
            Observation(
                kind: .importStatement,
                file: SourceAnchor(path: "A.swift", blob: BlobHash("abc123"),
                                   range: SourceRange(startLine: 1, startColumn: 1, endLine: 1, endColumn: 9)),
                payload: ["core:module": .string("B")],
                extractor: ExtractorIdentity(name: "swift-syntax", version: "0.1.0")),
        ], snapshot: snapshot)

        let a = StableKey("phys:file:test-repo/A.swift")
        let b = StableKey("phys:file:test-repo/B.swift")
        try store.commit(RevisionChanges(
            entities: [fileAssertion("A.swift"), fileAssertion("B.swift")],
            relationships: [RelationshipAssertion(
                source: a, target: b, kind: .imports, layer: .observed,
                supportedBy: obsIDs)]), note: nil)

        let rel = try #require(try store.relationships(from: a, kind: .imports, at: .current).first)
        #expect(try store.provenance(ofRelationship: rel.id) == obsIDs)
    }
}
