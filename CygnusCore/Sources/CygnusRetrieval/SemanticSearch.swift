import Foundation
import CygnusGraph
import CygnusStore
import CygnusEmbed
import CygnusProviders

// Similarity search over the chunk vectors.
//
// The matrix is loaded once and held, because pulling tens of megabytes
// through a serialized DatabaseQueue on every query would put the read
// behind whatever indexing is in flight. It is an actor for the same
// reason `CoreMLEmbedder` is: shared mutable state that must not be
// touched from two places at once, satisfied without
// `nonisolated(unsafe)`.

public actor VectorIndex {
    private let index: RetrievalIndexStore
    private let model: String
    private let dimension: Int

    private var chunks: [RetrievalIndexStore.ChunkRow] = []
    private var matrix: [Float] = []
    private var loadedFor: RepositoryID?
    private var loaded = false

    public init(store: SQLiteGraphStore, model: String, dimension: Int) {
        self.index = RetrievalIndexStore(store: store)
        self.model = model
        self.dimension = dimension
    }

    /// Reload when the scope changes. Cheap to call; the guard is what
    /// keeps a per-query reload from happening by accident.
    private func load(repository: RepositoryID?) throws {
        guard !loaded || loadedFor != repository else { return }
        let (rows, blobs) = try index.vectorMatrix(model: model, repository: repository)
        var packed = [Float]()
        packed.reserveCapacity(rows.count * dimension)
        var kept: [RetrievalIndexStore.ChunkRow] = []
        for (row, blob) in zip(rows, blobs) {
            // A vector of the wrong width is a corrupt row, not a
            // reason to fail the query — drop it and carry on.
            guard let vector = VectorMath.decode(blob, dimension: dimension) else { continue }
            packed.append(contentsOf: vector)
            kept.append(row)
        }
        chunks = kept
        matrix = packed
        loadedFor = repository
        loaded = true
    }

    public func search(vector: [Float], limit: Int,
                       repository: RepositoryID? = nil) throws
        -> [(chunk: RetrievalIndexStore.ChunkRow, score: Float)] {
        try load(repository: repository)
        guard !chunks.isEmpty else { return [] }
        return VectorMath.topK(query: vector, matrix: matrix,
                               dimension: dimension, k: limit)
            .map { (chunks[$0.index], $0.score) }
    }

    public func count() throws -> Int {
        try load(repository: loadedFor)
        return chunks.count
    }

    /// Drop the cached matrix — call after indexing writes vectors.
    public func invalidate() {
        loaded = false
        chunks = []
        matrix = []
    }
}

public struct SemanticSearch: Sendable {
    private let store: SQLiteGraphStore
    private let contentStore: ContentStore
    private let embedder: any TextEmbedder
    private let vectors: VectorIndex

    public init(store: SQLiteGraphStore, contentStore: ContentStore,
                embedder: any TextEmbedder) {
        self.store = store
        self.contentStore = contentStore
        self.embedder = embedder
        self.vectors = VectorIndex(store: store,
                                   model: embedder.identity.storageKey,
                                   dimension: embedder.identity.dimension)
    }

    public func search(_ query: String, repository: RepositoryID? = nil,
                       limit: Int = 10) async throws -> [RetrievalResult] {
        let embedded = try await embedder.embed(query)
        guard embedded.count == embedder.identity.dimension else { return [] }
        let hits = try await vectors.search(vector: VectorMath.normalized(embedded),
                                            limit: limit, repository: repository)
        guard !hits.isEmpty else { return [] }

        let index = RetrievalIndexStore(store: store)
        let names = Dictionary(uniqueKeysWithValues:
            try store.repositories().map { ($0.id, $0.displayName) })

        var results: [RetrievalResult] = []
        for hit in hits {
            // A blob can sit at several paths; cite the first
            // deterministically rather than inventing a preference.
            guard let location = try index.paths(forBlob: hit.chunk.blob).first else { continue }
            let snippet = try? snippet(blob: hit.chunk.blob,
                                       from: hit.chunk.startLine, to: hit.chunk.endLine)
            results.append(RetrievalResult(
                repository: location.repository,
                repositoryName: names[location.repository] ?? location.repository.raw,
                path: location.path,
                startLine: hit.chunk.startLine,
                endLine: hit.chunk.endLine,
                stableKey: hit.chunk.declKey.map(StableKey.init),
                layer: .inferred,          // similarity is a guess, and says so
                resolution: .semantic,
                score: Double(hit.score),
                snippet: snippet))
        }
        return results
    }

    private func snippet(blob: BlobHash, from: Int, to: Int) throws -> String? {
        guard let text = String(data: try contentStore.read(blob), encoding: .utf8) else {
            return nil
        }
        let lines = SourceWindows.splitLines(text)
        guard from >= 1, from <= lines.count else { return nil }
        // Snippets are for reading, not for reconstructing the file.
        let end = min(to, lines.count, from + 20)
        return lines[(from - 1)..<end].joined(separator: "\n")
    }
}
