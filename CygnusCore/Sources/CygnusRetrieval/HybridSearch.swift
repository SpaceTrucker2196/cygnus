import Foundation
import CygnusGraph
import CygnusStore
import CygnusEmbed
import CygnusProviders

// The search an agent actually calls.
//
// Lexical and semantic fail differently — one misses the concept phrased
// in other words, the other misses the identifier you already know — so
// running both and fusing keeps each one's strengths. That is the
// published finding and it is why the default mode is hybrid rather
// than either alone.
//
// Degradation is explicit throughout. Without a model there is no
// semantic tier, and `hybrid` quietly becoming `lexical` **while saying
// so** is the difference between a tool an agent can reason about and
// one that makes it confidently wrong.

public struct HybridSearch: Sendable {
    public enum Mode: String, Sendable, CaseIterable {
        case lexical, semantic, hybrid
    }

    public struct Outcome: Sendable {
        public let results: [RetrievalResult]
        /// What actually ran, which may not be what was asked for.
        public let modeUsed: Mode
        /// Set when the requested mode was not available.
        public let degraded: String?
    }

    private let store: SQLiteGraphStore
    private let contentStore: ContentStore
    private let embedder: (any TextEmbedder)?

    public init(store: SQLiteGraphStore, contentStore: ContentStore,
                embedder: (any TextEmbedder)?) {
        self.store = store
        self.contentStore = contentStore
        self.embedder = embedder
    }

    public func search(_ query: String,
                       mode: Mode = .hybrid,
                       repository: RepositoryID? = nil,
                       pathPrefix: String? = nil,
                       focus: [String] = [],
                       limit: Int = 10) async throws -> Outcome {
        guard mode != .lexical, let embedder else {
            let lexical = try LexicalSearch(store: store, contentStore: contentStore)
                .search(query, repository: repository, pathPrefix: pathPrefix, limit: limit)
            return Outcome(
                results: lexical,
                modeUsed: .lexical,
                degraded: mode == .lexical ? nil
                    : "no embedding model installed — semantic search unavailable, "
                    + "ran lexical only (set \(EmbedderLocator.environmentKey))")
        }

        let semantic = try await SemanticSearch(
            store: store, contentStore: contentStore, embedder: embedder)
            .search(query, repository: repository, limit: limit * 2)

        if mode == .semantic {
            return Outcome(results: Array(semantic.prefix(limit)),
                           modeUsed: .semantic, degraded: nil)
        }

        let lexical = try LexicalSearch(store: store, contentStore: contentStore)
            .search(query, repository: repository, pathPrefix: pathPrefix, limit: limit * 2)

        // Semantic hits carry no path filter of their own — apply the
        // caller's here rather than returning results they excluded.
        let filtered = pathPrefix.map { prefix in
            semantic.filter { $0.path.hasPrefix(prefix) }
        } ?? semantic

        let boost = try GraphBoost.build(store: store, focus: focus, repository: repository)
        let fused = HybridFusion.fuse([lexical, filtered], limit: limit) { result in
            boost.score(for: result)
        }
        return Outcome(results: fused, modeUsed: .hybrid, degraded: nil)
    }

    /// The embedder for a workspace, or nil when none is installed.
    /// Never throws: absence is a normal state.
    public static func embedder(workspace: URL) -> (any TextEmbedder)? {
        guard let directory = EmbedderLocator.modelDirectory(workspace: workspace) else {
            return nil
        }
        return try? CoreMLEmbedder(directory: directory)
    }
}
