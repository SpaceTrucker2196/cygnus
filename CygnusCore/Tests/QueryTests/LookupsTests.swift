import Testing
import Foundation
import CygnusGraph
import CygnusStore
@testable import CygnusQuery

// The structural entry points. The assertions that matter most are the
// ones about *not knowing*: an empty answer from a repository that was
// never built has to be distinguishable from an empty answer from one
// that was, or a tool built on this will talk an agent into deleting
// live code.

@Suite struct LookupsTests {
    let repo = RepositoryID("test-repo")

    private func makeStore() throws -> SQLiteGraphStore {
        let store = try SQLiteGraphStore.inMemory()
        try store.registerRepository(repo, displayName: "Test Repo")
        return store
    }

    private func decl(_ name: String, kind: EntityKind = .function,
                      path: String = "A.swift", line: Int = 1,
                      declPath: String? = nil) -> EntityAssertion {
        EntityAssertion(
            stableKey: StableKey("swift:decl:test-repo/\(path)#\(name)"),
            kind: kind, repository: repo, name: name,
            properties: declPath.map { ["core:declPath": .string($0)] } ?? [:],
            anchors: [SourceAnchor(
                path: path, blob: BlobHash("beef"),
                range: SourceRange(startLine: line, startColumn: 1,
                                   endLine: line + 5, endColumn: 1))])
    }

    private func key(_ name: String, path: String = "A.swift") -> StableKey {
        StableKey("swift:decl:test-repo/\(path)#\(name)")
    }

    private func symbolEdge(_ from: StableKey, _ to: StableKey,
                            references: Int64, calls: Int64) -> RelationshipAssertion {
        RelationshipAssertion(
            source: from, target: to, kind: .refersToSymbol, layer: .derived,
            properties: ["core:referenceCount": .int(references),
                         "core:callCount": .int(calls)])
    }

    // MARK: - Definitions

    /// Directories and files are never the answer to "where is this
    /// defined", however well their names match.
    @Test func definitionsExcludeNonDeclarationKinds() throws {
        let store = try makeStore()
        try store.commit(RevisionChanges(entities: [
            decl("send", kind: .function),
            EntityAssertion(stableKey: StableKey("phys:dir:test-repo/send"),
                            kind: .directory, repository: repo, name: "send"),
        ]), note: nil)

        let found = try Lookups.definitions(store: store, named: "send")
        #expect(found.count == 1)
        #expect(found[0].entity.kind == .function)
    }

    /// An exact name beats a longer prefix match, so `send` doesn't
    /// return `sendAndForget` first.
    @Test func exactNameOutranksPrefixMatch() throws {
        let store = try makeStore()
        try store.commit(RevisionChanges(entities: [
            decl("sendAndForget", line: 1),
            decl("send", line: 20),
        ]), note: nil)

        let found = try Lookups.definitions(store: store, named: "send")
        #expect(found.first?.version.name == "send")
    }

    @Test func symbolsInAFileComeBackInSourceOrder() throws {
        let store = try makeStore()
        try store.commit(RevisionChanges(entities: [
            decl("third", line: 30),
            decl("first", line: 1),
            decl("second", line: 10),
        ]), note: nil)

        let symbols = try Lookups.symbols(store: store, in: "A.swift")
        #expect(symbols.map(\.version.name) == ["first", "second", "third"])
    }

    // MARK: - The distinction that matters

    /// No compiler edges anywhere in the repo: an empty result means
    /// "unknown", and the answer must say so.
    @Test func withoutCompilerEdgesTheAnswerIsUnavailableNotEmpty() throws {
        let store = try makeStore()
        try store.commit(RevisionChanges(entities: [decl("orphan")]), note: nil)

        let answer = try Lookups.callers(store: store, of: key("orphan"))
        #expect(answer.evidence == .unavailable)
        #expect(answer.references.isEmpty)
    }

    /// Compiler edges exist, this symbol simply has none: that is a
    /// real "none", and it must not be reported as ignorance.
    @Test func withCompilerEdgesAnEmptyResultIsARealNone() throws {
        let store = try makeStore()
        try store.commit(RevisionChanges(
            entities: [decl("caller", line: 1), decl("callee", line: 10), decl("lonely", line: 20)],
            relationships: [symbolEdge(key("caller"), key("callee"), references: 3, calls: 2)]),
            note: nil)

        let answer = try Lookups.callers(store: store, of: key("lonely"))
        #expect(answer.evidence == .compiler)
        #expect(answer.references.isEmpty)
    }

    /// The Phase 0 fix, asserted end to end: a reference that is not a
    /// call must not appear among callers.
    @Test func callersExcludeReferencesThatAreNotCalls() throws {
        let store = try makeStore()
        try store.commit(RevisionChanges(
            entities: [decl("mentions", line: 1), decl("calls", line: 10), decl("target", line: 20)],
            relationships: [
                symbolEdge(key("mentions"), key("target"), references: 5, calls: 0),
                symbolEdge(key("calls"), key("target"), references: 2, calls: 2),
            ]), note: nil)

        let references = try Lookups.references(store: store, to: key("target"))
        #expect(references.references.count == 2)

        let callers = try Lookups.callers(store: store, of: key("target"))
        #expect(callers.references.count == 1)
        #expect(callers.references[0].source.version.name == "calls")
    }

    @Test func referencesAreOrderedByWeight() throws {
        let store = try makeStore()
        try store.commit(RevisionChanges(
            entities: [decl("light", line: 1), decl("heavy", line: 10), decl("target", line: 20)],
            relationships: [
                symbolEdge(key("light"), key("target"), references: 1, calls: 0),
                symbolEdge(key("heavy"), key("target"), references: 9, calls: 0),
            ]), note: nil)

        let answer = try Lookups.references(store: store, to: key("target"))
        #expect(answer.references.map(\.source.version.name) == ["heavy", "light"])
    }

    @Test func anUnknownSymbolIsUnavailableRatherThanEmpty() throws {
        let store = try makeStore()
        let answer = try Lookups.references(store: store, to: key("nope"))
        #expect(answer.evidence == .unavailable)
    }

    // MARK: - Blast radius

    @Test func blastRadiusPutsTheOriginFirstAndIsDeterministic() throws {
        let store = try makeStore()
        try store.commit(RevisionChanges(
            entities: [decl("root", line: 1), decl("near", line: 10), decl("far", line: 20)],
            relationships: [
                symbolEdge(key("near"), key("root"), references: 4, calls: 4),
                symbolEdge(key("far"), key("near"), references: 1, calls: 1),
            ]), note: nil)

        let runs = try (0..<3).map { _ in
            try Lookups.blastRadius(store: store, of: key("root"), depth: 2)
                .map(\.version.name)
        }
        #expect(runs[0].first == "root")
        #expect(Set(runs[0]) == ["root", "near", "far"])
        #expect(runs[0] == runs[1] && runs[1] == runs[2])
    }
}
