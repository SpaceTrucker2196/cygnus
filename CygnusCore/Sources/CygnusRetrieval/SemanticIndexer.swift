import Foundation
import CygnusGraph
import CygnusStore
import CygnusEmbed
import CygnusProviders

// Chunk, then embed, both keyed by blob.
//
// Same invalidation rule as the lexical index and for the same reason:
// the work list is a set difference on blob hashes, so unchanged files
// cost nothing, renames cost nothing, reverts cost nothing. Embedding
// is the expensive step in this layer, which is precisely why it must
// never run twice for the same content.
//
// There are exactly two re-embed triggers: a blob with no chunks, and a
// chunk with no vector *for the configured model*. There is no third.

public struct SemanticIndexer: Sendable {
    private let store: SQLiteGraphStore
    private let index: RetrievalIndexStore
    private let contentStore: ContentStore
    private let embedder: any TextEmbedder

    public init(store: SQLiteGraphStore, contentStore: ContentStore,
                embedder: any TextEmbedder) {
        self.store = store
        self.index = RetrievalIndexStore(store: store)
        self.contentStore = contentStore
        self.embedder = embedder
    }

    /// Embedding batch. Small enough that a failure loses little work,
    /// large enough that per-call overhead does not dominate.
    public static let batchSize = 32

    public struct Report: Sendable, Equatable {
        public var blobsChunked = 0
        public var chunksCreated = 0
        public var vectorsEmbedded = 0
        public var skipped = 0
    }

    /// Chunk any blob that has none. Cheap and model-independent, so it
    /// runs whether or not an embedder is installed.
    @discardableResult
    public func chunk(blobs: [BlobHash], repository: RepositoryID) throws -> Report {
        let already = try index.chunkedBlobs()
        var report = Report()
        let planner = ChunkPlanner()
        let repositoryName = (try? store.repositories().first { $0.id == repository })?
            .displayName ?? repository.raw

        for blob in Set(blobs).subtracting(already).sorted(by: { $0.raw < $1.raw }) {
            guard blob != RetrievalIndexer.notIngested,
                  let data = try? contentStore.read(blob),
                  let text = String(data: data, encoding: .utf8) else {
                report.skipped += 1
                continue
            }
            let paths = try index.paths(forBlob: blob)
            guard let path = paths.first?.path else { report.skipped += 1; continue }

            let lines = SourceWindows.splitLines(text)
            guard !lines.isEmpty else { report.skipped += 1; continue }

            let declarations = try declarations(in: path, repository: repository)
            let plan = planner.plan(
                lineCount: lines.count,
                declarations: declarations,
                isComment: { line in
                    line >= 1 && line <= lines.count
                        && ChunkPlanner.isProse(lines[line - 1])
                })

            let imports = lines.filter { $0.hasPrefix("import ") || $0.hasPrefix("#include") }
                .prefix(12).map { $0.trimmingCharacters(in: .whitespaces) }
            let drafts = plan.map { chunk -> RetrievalIndexStore.ChunkDraft in
                let prefix = ContextPrefix(
                    repository: repositoryName, path: path,
                    imports: Array(imports),
                    enclosing: chunk.declarationName.map { [$0] } ?? [],
                    siblings: plan.compactMap(\.declarationName)
                        .filter { $0 != chunk.declarationName })
                return .init(ordinal: chunk.ordinal, startLine: chunk.startLine,
                             endLine: chunk.endLine, declKey: chunk.declaration?.raw,
                             declName: chunk.declarationName, context: prefix.text)
            }
            try index.insertChunks(drafts, blob: blob)
            report.blobsChunked += 1
            report.chunksCreated += drafts.count
        }
        return report
    }

    /// Embed whatever has no vector yet for this model.
    @discardableResult
    public func embedPending(limit: Int = 5000) async throws -> Report {
        var report = Report()
        let model = embedder.identity.storageKey
        var pending = try index.chunksMissingVectors(model: model, limit: limit)

        while !pending.isEmpty {
            let batch = Array(pending.prefix(Self.batchSize))
            pending.removeFirst(batch.count)

            var texts: [String] = []
            var ids: [Int64] = []
            for chunk in batch {
                guard let body = try? body(of: chunk) else { continue }
                texts.append(chunk.context + body)
                ids.append(chunk.id)
            }
            guard !texts.isEmpty else { continue }

            let embedded = try await embedder.embed(texts)
            guard embedded.count == texts.count else {
                throw EmbedderError.shapeMismatch(expected: texts.count, got: embedded.count)
            }
            let rows = zip(ids, embedded).map { id, vector in
                (chunkID: id, data: VectorMath.encode(VectorMath.normalized(vector)))
            }
            try index.insertVectors(rows, model: model,
                                    dimension: embedder.identity.dimension)
            report.vectorsEmbedded += rows.count
        }
        return report
    }

    // MARK: - Internals

    private func body(of chunk: RetrievalIndexStore.ChunkRow) throws -> String {
        guard let text = String(data: try contentStore.read(chunk.blob), encoding: .utf8) else {
            throw EmbedderError.modelNotFound("unreadable blob \(chunk.blob.raw)")
        }
        let lines = SourceWindows.splitLines(text)
        let from = max(chunk.startLine - 1, 0)
        let to = min(chunk.endLine, lines.count)
        guard from < to else { return "" }
        return lines[from..<to].joined(separator: "\n")
    }

    private func declarations(in path: String,
                              repository: RepositoryID) throws -> [ChunkPlanner.Declaration] {
        try store.resolvedEntities(anchoredIn: path)
            .filter { $0.entity.repository == repository }
            .compactMap { entity in
                guard let range = entity.version.anchors.first?.range else { return nil }
                return ChunkPlanner.Declaration(
                    key: entity.entity.stableKey, name: entity.version.name,
                    kind: entity.entity.kind,
                    startLine: range.startLine, endLine: range.endLine)
            }
    }
}
