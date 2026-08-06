import Testing
import Foundation
import CygnusGraph
import CygnusStore
@testable import CygnusQuery

// The locator maps a source line back to the symbol enclosing it.
// Reference enrichment attributes compiler occurrences with it, and
// retrieval attributes search hits with it — so "innermost wins" is
// load-bearing for both: attributing a hit to the enclosing *file* or
// to an outer type instead of the function it landed in would make
// every citation coarser than the evidence supports.

@Suite struct DeclarationLocatorTests {
    let repo = RepositoryID("test-repo")

    private func makeStore() throws -> SQLiteGraphStore {
        let store = try SQLiteGraphStore.inMemory()
        try store.registerRepository(repo, displayName: "Test Repo")
        return store
    }

    private func decl(_ name: String, kind: EntityKind, path: String,
                      _ start: Int, _ end: Int) -> EntityAssertion {
        EntityAssertion(
            stableKey: StableKey("swift:decl:test-repo/\(path)#\(name)"),
            kind: kind, repository: repo, name: name,
            anchors: [SourceAnchor(
                path: path, blob: BlobHash("deadbeef"),
                range: SourceRange(startLine: start, startColumn: 1,
                                   endLine: end, endColumn: 1))])
    }

    /// A type spanning a file and a method nested inside it: a line in
    /// the method belongs to the method, not the type.
    @Test func innermostDeclarationWins() throws {
        let store = try makeStore()
        try store.commit(RevisionChanges(entities: [
            decl("Client", kind: .type, path: "Net/Client.swift", 1, 100),
            decl("send(_:)", kind: .function, path: "Net/Client.swift", 20, 40),
        ]), note: nil)

        let locator = try DeclarationLocator.build(store: store, repository: repo)

        #expect(locator.enclosing(path: "Net/Client.swift", line: 30)?.raw
            == "swift:decl:test-repo/Net/Client.swift#send(_:)")
        // Outside the method but inside the type.
        #expect(locator.enclosing(path: "Net/Client.swift", line: 60)?.raw
            == "swift:decl:test-repo/Net/Client.swift#Client")
    }

    @Test func boundariesAreInclusive() throws {
        let store = try makeStore()
        try store.commit(RevisionChanges(entities: [
            decl("send(_:)", kind: .function, path: "A.swift", 20, 40),
        ]), note: nil)
        let locator = try DeclarationLocator.build(store: store, repository: repo)

        #expect(locator.enclosing(path: "A.swift", line: 20) != nil)
        #expect(locator.enclosing(path: "A.swift", line: 40) != nil)
        #expect(locator.enclosing(path: "A.swift", line: 19) == nil)
        #expect(locator.enclosing(path: "A.swift", line: 41) == nil)
    }

    /// An unknown path yields nothing rather than a wrong attribution.
    @Test func unknownPathHasNoEnclosingDeclaration() throws {
        let store = try makeStore()
        try store.commit(RevisionChanges(entities: [
            decl("send(_:)", kind: .function, path: "A.swift", 1, 10),
        ]), note: nil)
        let locator = try DeclarationLocator.build(store: store, repository: repo)

        #expect(locator.enclosing(path: "Nowhere.swift", line: 5) == nil)
    }

    /// The locator is scoped to one repository — a workspace holds
    /// many, and paths collide across them constantly (`README.md`,
    /// `Package.swift`).
    @Test func otherRepositoriesAreExcluded() throws {
        let store = try makeStore()
        let other = RepositoryID("other-repo")
        try store.registerRepository(other, displayName: "Other")
        try store.commit(RevisionChanges(entities: [
            decl("mine", kind: .function, path: "Shared.swift", 1, 10),
            EntityAssertion(
                stableKey: StableKey("swift:decl:other-repo/Shared.swift#theirs"),
                kind: .function, repository: other, name: "theirs",
                anchors: [SourceAnchor(
                    path: "Shared.swift", blob: BlobHash("cafe"),
                    range: SourceRange(startLine: 1, startColumn: 1,
                                       endLine: 10, endColumn: 1))]),
        ]), note: nil)

        let locator = try DeclarationLocator.build(store: store, repository: repo)
        #expect(locator.enclosing(path: "Shared.swift", line: 5)?.raw
            == "swift:decl:test-repo/Shared.swift#mine")
    }
}
