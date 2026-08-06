import Testing
import Foundation
import CygnusGraph
import CygnusStore
import CygnusEmbed
import CygnusProviders
@testable import CygnusRetrieval

// The whole Tier 2 pipeline — chunk, embed, store, search, fuse —
// exercised without a model artifact existing.
//
// The fixture embedder derives vectors from the text's own words, so
// similarity is meaningful but entirely deterministic: the same input
// always produces the same vector, on any machine, with no download.
// That is what lets the pipeline be tested at all, since the real
// weights are a few hundred megabytes and deliberately not committed.

/// Bag-of-words hashed into a fixed-dimension vector. Not a good
/// embedder — it cannot see meaning past shared vocabulary — but a
/// truthful one for testing plumbing, and it never varies.
///
/// 256 dimensions rather than a token 32: at 32 the hash collides so
/// often that ranking becomes noise, and a test asserting an order that
/// only holds by luck is worse than no test.
struct FixtureEmbedder: TextEmbedder {
    let identity = EmbedderIdentity(name: "fixture", revision: "0000test", dimension: 256)

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            var vector = [Float](repeating: 0, count: identity.dimension)
            for word in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                var hash: UInt64 = 1469598103934665603
                for byte in word.utf8 {
                    hash = (hash ^ UInt64(byte)) &* 1099511628211
                }
                vector[Int(hash % UInt64(identity.dimension))] += 1
            }
            return VectorMath.normalized(vector)
        }
    }
}

@Suite struct SemanticPipelineTests {
    private struct Fixture {
        let store: SQLiteGraphStore
        let cas: ContentStore
        let repo: RepositoryID
        let root: URL
        let embedder: FixtureEmbedder
    }

    private func makeFixture(_ files: [String: String]) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-semantic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SQLiteGraphStore.inMemory()
        let cas = try ContentStore(root: root.appendingPathComponent("cas"))
        let repo = RepositoryID("semantic-repo")
        try store.registerRepository(repo, displayName: "Semantic")

        var records: [SQLiteGraphStore.SnapshotFileRecord] = []
        for (path, contents) in files.sorted(by: { $0.key < $1.key }) {
            let blob = try cas.store(Data(contents.utf8))
            records.append(.init(path: path, blobHash: blob.raw,
                                 size: Int64(contents.utf8.count), languageHint: "swift"))
        }
        let snapshot = try store.recordSnapshot(repository: repo, sourceRef: nil, files: records)
        _ = try store.commit(RevisionChanges(), note: "snapshot", snapshot: snapshot)

        return Fixture(store: store, cas: cas, repo: repo, root: root,
                       embedder: FixtureEmbedder())
    }

    private func blobs(_ fixture: Fixture) throws -> [BlobHash] {
        try corpus.keys.sorted().compactMap {
            try fixture.store.currentBlob(forPath: $0, repository: fixture.repo)
        }
    }

    private let corpus = [
        "Sources/Memory.swift": """
            // Enforcing the hard ceiling so a pathological repository
            // cannot exhaust the machine's memory during analysis.
            struct MemoryLimits {
                func checkHardLimit() throws {
                    guard let used = footprint(), used > ceiling else { return }
                    throw LimitError.exceeded
                }
            }
            """,
        "Sources/Network.swift": """
            // Sending requests to a remote host over the wire.
            struct HTTPClient {
                func send(request: Request) async throws -> Response {
                    try await transport.write(request)
                }
            }
            """,
    ]

    @Test func chunkingThenEmbeddingProducesSearchableVectors() async throws {
        let fixture = try makeFixture(corpus)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let indexer = SemanticIndexer(store: fixture.store, contentStore: fixture.cas,
                                      embedder: fixture.embedder)

        let chunked = try indexer.chunk(blobs: try blobs(fixture), repository: fixture.repo)
        #expect(chunked.chunksCreated > 0)

        let embedded = try await indexer.embedPending()
        #expect(embedded.vectorsEmbedded == chunked.chunksCreated)

        let search = SemanticSearch(store: fixture.store, contentStore: fixture.cas,
                                    embedder: fixture.embedder)
        let hits = try await search.search("memory ceiling exhaust", limit: 5)
        #expect(!hits.isEmpty)
        #expect(hits[0].path == "Sources/Memory.swift")
    }

    /// Semantic hits are inferred, not observed, and always carry a
    /// score — invariant 9 at the result boundary. A cosine number
    /// dressed as a fact is exactly what that rule forbids.
    @Test func semanticHitsAreLabelledInferredAndScored() async throws {
        let fixture = try makeFixture(corpus)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let indexer = SemanticIndexer(store: fixture.store, contentStore: fixture.cas,
                                      embedder: fixture.embedder)
        try indexer.chunk(blobs: try blobs(fixture), repository: fixture.repo)
        _ = try await indexer.embedPending()

        let hits = try await SemanticSearch(store: fixture.store, contentStore: fixture.cas,
                                            embedder: fixture.embedder)
            .search("request transport", limit: 3)
        let hit = try #require(hits.first)
        #expect(hit.layer == .inferred)
        #expect(hit.resolution == .semantic)
        #expect(hit.score != nil)
    }

    /// Re-running costs nothing. Embedding is the expensive step in
    /// this layer, so "unchanged content is never re-embedded" is the
    /// claim that matters most.
    @Test func reindexingEmbedsNothingNew() async throws {
        let fixture = try makeFixture(corpus)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let indexer = SemanticIndexer(store: fixture.store, contentStore: fixture.cas,
                                      embedder: fixture.embedder)
        try indexer.chunk(blobs: try blobs(fixture), repository: fixture.repo)
        _ = try await indexer.embedPending()

        let second = try indexer.chunk(blobs: try blobs(fixture), repository: fixture.repo)
        #expect(second.chunksCreated == 0)
        let again = try await indexer.embedPending()
        #expect(again.vectorsEmbedded == 0)
    }

    /// Changing the model invalidates every vector, because vectors
    /// from different models are not comparable. Returning nothing is
    /// the correct failure; silently mixing spaces is not.
    @Test func adifferentModelSeesNoVectors() async throws {
        struct OtherEmbedder: TextEmbedder {
            let identity = EmbedderIdentity(name: "other", revision: "ffffffff", dimension: 256)
            func embed(_ texts: [String]) async throws -> [[Float]] {
                texts.map { _ in VectorMath.normalized([Float](repeating: 1, count: 256)) }
            }
        }
        let fixture = try makeFixture(corpus)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let indexer = SemanticIndexer(store: fixture.store, contentStore: fixture.cas,
                                      embedder: fixture.embedder)
        try indexer.chunk(blobs: try blobs(fixture), repository: fixture.repo)
        _ = try await indexer.embedPending()

        let hits = try await SemanticSearch(store: fixture.store, contentStore: fixture.cas,
                                            embedder: OtherEmbedder())
            .search("memory", limit: 5)
        #expect(hits.isEmpty)
    }

    /// Fusion keeps both kinds of evidence and prefers the stronger one
    /// when they describe the same span.
    @Test func fusionCollapsesOverlappingHitsAndKeepsTheStrongerEvidence() {
        let repo = RepositoryID("r")
        func result(_ line: Int, _ resolution: Resolution) -> RetrievalResult {
            RetrievalResult(repository: repo, repositoryName: "r", path: "A.swift",
                            startLine: line, endLine: line + 2,
                            layer: resolution == .semantic ? .inferred : .observed,
                            resolution: resolution, score: 1)
        }
        let fused = HybridFusion.fuse([[result(10, .lexical)], [result(12, .semantic)]], limit: 5)
        #expect(fused.count == 1, "overlapping hits should collapse to one finding")
        #expect(fused[0].resolution == .lexical, "the stronger evidence should be shown")
    }

    @Test func fusionIsDeterministic() {
        let repo = RepositoryID("r")
        func result(_ path: String) -> RetrievalResult {
            RetrievalResult(repository: repo, repositoryName: "r", path: path,
                            startLine: 1, endLine: 2, layer: .observed,
                            resolution: .lexical, score: 1)
        }
        let lists = [[result("A.swift"), result("B.swift")], [result("B.swift")]]
        let runs = (0..<3).map { _ in HybridFusion.fuse(lists, limit: 5).map(\.citation) }
        #expect(runs[0] == runs[1] && runs[1] == runs[2])
        #expect(runs[0].first?.contains("B.swift") == true, "the hit in both lists should lead")
    }
}
