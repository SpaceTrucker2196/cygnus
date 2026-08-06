import Testing
import Foundation
import CygnusGraph
import CygnusStore
@testable import CygnusRetrieval

// The map is what sits at the top of an agent's context on every call,
// so its two properties are: it fits, and its ordering is defensible.

@Suite struct RepoMapTests {
    let repo = RepositoryID("test-repo")

    private func makeStore() throws -> SQLiteGraphStore {
        let store = try SQLiteGraphStore.inMemory()
        try store.registerRepository(repo, displayName: "Test Repo")
        return store
    }

    private func file(_ path: String) -> EntityAssertion {
        EntityAssertion(
            stableKey: StableKey("phys:file:test-repo/\(path)"),
            kind: .file, repository: repo, name: (path as NSString).lastPathComponent,
            anchors: [SourceAnchor(path: path, blob: BlobHash("f"), range: nil)])
    }

    private func decl(_ name: String, kind: EntityKind, path: String, line: Int) -> EntityAssertion {
        EntityAssertion(
            stableKey: StableKey("swift:decl:test-repo/\(path)#\(name)"),
            kind: kind, repository: repo, name: name,
            anchors: [SourceAnchor(
                path: path, blob: BlobHash("d"),
                range: SourceRange(startLine: line, startColumn: 1,
                                   endLine: line + 2, endColumn: 1))])
    }

    private func imports(_ from: String, _ to: String) -> RelationshipAssertion {
        RelationshipAssertion(
            source: StableKey("phys:file:test-repo/\(from)"),
            target: StableKey("phys:file:test-repo/\(to)"),
            kind: .imports, layer: .observed)
    }

    @Test func anUnindexedRepositorySaysSoRatherThanRenderingNothing() throws {
        let store = try makeStore()
        let map = try RepoMap(store: store).render(repository: repo)
        #expect(map.contains("not indexed"))
    }

    /// The file everything imports leads the map.
    @Test func theMostDependedUponFileRanksFirst() throws {
        let store = try makeStore()
        try store.commit(RevisionChanges(
            entities: [file("Src/Core.swift"), file("Src/A.swift"), file("Src/B.swift")],
            relationships: [imports("Src/A.swift", "Src/Core.swift"),
                            imports("Src/B.swift", "Src/Core.swift")]),
            note: nil)

        let map = try RepoMap(store: store).render(repository: repo)
        let core = try #require(map.range(of: "Core.swift"))
        let a = try #require(map.range(of: "A.swift"))
        #expect(core.lowerBound < a.lowerBound)
    }

    /// Without compiler references the ranking rests on imports alone,
    /// and the header has to admit that rather than present a weaker
    /// ordering as the same thing.
    @Test func missingCompilerReferencesAreDisclosedInTheHeader() throws {
        let store = try makeStore()
        try store.commit(RevisionChanges(entities: [file("A.swift")]), note: nil)
        let map = try RepoMap(store: store).render(repository: repo)
        #expect(map.contains("no compiler references"))
    }

    @Test func theRenderedMapStaysInsideItsBudget() throws {
        let store = try makeStore()
        let files = (1...200).map { file("Src/File\($0).swift") }
        try store.commit(RevisionChanges(entities: files), note: nil)

        let map = try RepoMap(store: store)
            .render(repository: repo, options: .init(maxTokens: 400))
        #expect(TokenBudget.estimate(map) <= 400 + TokenBudget.footerReserve)
        #expect(map.contains("truncated"))
        #expect(map.contains("of 200"))
    }

    /// Types and functions carry the shape of a file; one-line stored
    /// properties do not, and they would otherwise eat the whole
    /// per-file allowance by sitting at the top.
    @Test func headlineDeclarationsPreferTypesAndFunctionsOverProperties() {
        let declarations = (1...10).map {
            RepoMap.Declaration(name: "prop\($0)", line: $0, kind: .variable)
        } + [RepoMap.Declaration(name: "TheType", line: 99, kind: .type)]

        let headline = RepoMap.headline(declarations)
        #expect(headline.contains { $0.name == "TheType" })
        // …and reading order is restored afterwards.
        #expect(headline.map(\.line) == headline.map(\.line).sorted())
    }

    @Test func renderingIsDeterministic() throws {
        let store = try makeStore()
        try store.commit(RevisionChanges(
            entities: [file("Src/A.swift"), file("Src/B.swift"), file("Src/C.swift"),
                       decl("Alpha", kind: .type, path: "Src/A.swift", line: 1)],
            relationships: [imports("Src/B.swift", "Src/A.swift")]),
            note: nil)

        let runs = try (0..<3).map { _ in try RepoMap(store: store).render(repository: repo) }
        #expect(runs[0] == runs[1])
        #expect(runs[1] == runs[2])
    }
}
