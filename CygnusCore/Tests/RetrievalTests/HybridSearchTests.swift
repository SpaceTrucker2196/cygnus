import Testing
import Foundation
import CygnusGraph
import CygnusStore
import CygnusEmbed
import CygnusProviders
@testable import CygnusRetrieval

// Degradation, and the graph signal that justifies fusing at all.
//
// The rule under every case here: a tool never substitutes a weaker
// answer silently. Hybrid falling back to lexical is fine. Hybrid
// falling back to lexical without saying so is what makes an agent
// confidently wrong, and it is the failure invariant 9 exists to stop.

@Suite struct HybridSearchTests {
    private struct Fixture {
        let store: SQLiteGraphStore
        let cas: ContentStore
        let repo: RepositoryID
        let root: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-hybrid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SQLiteGraphStore.inMemory()
        let cas = try ContentStore(root: root.appendingPathComponent("cas"))
        let repo = RepositoryID("hybrid-repo")
        try store.registerRepository(repo, displayName: "Hybrid")

        let files = [
            "Sources/Memory.swift": "struct MemoryLimits {\n  func checkHardLimit() {}\n}\n",
            "Sources/Net.swift": "struct HTTPClient {\n  func send() {}\n}\n",
        ]
        var records: [SQLiteGraphStore.SnapshotFileRecord] = []
        for (path, contents) in files.sorted(by: { $0.key < $1.key }) {
            let blob = try cas.store(Data(contents.utf8))
            records.append(.init(path: path, blobHash: blob.raw,
                                 size: Int64(contents.utf8.count), languageHint: "swift"))
        }
        let snapshot = try store.recordSnapshot(repository: repo, sourceRef: nil, files: records)
        _ = try store.commit(RevisionChanges(), note: "snapshot", snapshot: snapshot)

        // Index lexically so there is something to search.
        try RetrievalIndexer(store: store, contentStore: cas)
            .index(blobs: records.map { BlobHash($0.blobHash) })
        return Fixture(store: store, cas: cas, repo: repo, root: root)
    }

    /// Without a model, hybrid runs lexical and *reports* that it did.
    @Test func hybridWithoutAModelDegradesAndSaysSo() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let outcome = try await HybridSearch(store: fixture.store,
                                             contentStore: fixture.cas, embedder: nil)
            .search("MemoryLimits", mode: .hybrid)

        #expect(outcome.modeUsed == .lexical)
        #expect(outcome.degraded != nil, "a silent downgrade is the failure this prevents")
        #expect(outcome.degraded?.contains(EmbedderLocator.environmentKey) == true,
                "the message must say how to fix it")
        #expect(!outcome.results.isEmpty)
    }

    /// Asking for lexical and getting lexical is not a degradation, so
    /// nothing should be reported.
    @Test func explicitLexicalIsNotReportedAsDegraded() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let outcome = try await HybridSearch(store: fixture.store,
                                             contentStore: fixture.cas, embedder: nil)
            .search("MemoryLimits", mode: .lexical)
        #expect(outcome.modeUsed == .lexical)
        #expect(outcome.degraded == nil)
    }

    /// The boost is small by design: it should lift near-misses and
    /// break ties, never overrule a result both retrievers agree on.
    @Test func theGraphBoostIsSmallerThanAFirstPlaceFusionScore() {
        let firstPlace = 1 / (HybridFusion.k + 1)
        #expect(GraphBoost.adjacencyWeight < firstPlace)
        #expect(GraphBoost.centralityWeight < GraphBoost.adjacencyWeight)
    }

    /// A result adjacent to the focus symbol outranks one that is not,
    /// all else equal — this is the signal no text index has.
    @Test func adjacencyToFocusLiftsAResult() {
        let repo = RepositoryID("r")
        func result(_ path: String, _ key: String?) -> RetrievalResult {
            RetrievalResult(repository: repo, repositoryName: "r", path: path,
                            startLine: 1, endLine: 3,
                            stableKey: key.map(StableKey.init),
                            layer: .observed, resolution: .lexical, score: 1)
        }
        let near = result("A.swift", "swift:decl:r/A.swift#near")
        let far = result("B.swift", "swift:decl:r/B.swift#far")
        let boost = GraphBoost(adjacent: ["swift:decl:r/A.swift#near"])

        #expect(boost.score(for: near) > boost.score(for: far))

        // …and it changes the order when fusion would otherwise tie.
        let fused = HybridFusion.fuse([[far, near]], limit: 2) { boost.score(for: $0) }
        #expect(fused.first?.path == "A.swift")
    }

    @Test func anEmptyBoostChangesNothing() {
        let boost = GraphBoost()
        #expect(boost.isEmpty)
        let result = RetrievalResult(repository: RepositoryID("r"), repositoryName: "r",
                                     path: "A.swift", startLine: 1, endLine: 2,
                                     layer: .observed, resolution: .lexical, score: 1)
        #expect(boost.score(for: result) == 0)
    }
}
