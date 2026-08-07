import Foundation
import CygnusGraph
import CygnusStore
import CygnusQuery

// The part no text index can do.
//
// Cross-file signal was deliberately excluded from the embedding —
// putting "referenced by RequestQueue" into a chunk's prefix would make
// its vector depend on other files and collapse blob-keyed
// incrementality into transitive invalidation. So it enters here
// instead, at rank time, where it costs nothing to recompute and
// nothing to invalidate.
//
// This is also where cygnus has something to say that a grep and an
// embedding model do not: it knows what calls what. A result sitting
// one hop from the symbol you are working on is more likely to be the
// answer than one that merely shares vocabulary with your query.

public struct GraphBoost: Sendable {
    /// Stable keys within one hop of the focus symbols.
    private let adjacent: Set<String>
    /// Files ranked by centrality, normalized to 0…1.
    private let centrality: [String: Double]

    /// Weights. Deliberately small relative to RRF's own scale (~1/61
    /// for a first-place hit): the boost should break ties and lift
    /// near-misses, not overrule a result both retrievers agree on.
    public static let adjacencyWeight = 0.010
    public static let centralityWeight = 0.005

    public init(adjacent: Set<String> = [], centrality: [String: Double] = [:]) {
        self.adjacent = adjacent
        self.centrality = centrality
    }

    /// Build from the graph for a set of focus symbols. With no focus,
    /// only centrality applies — "what matters here" rather than "what
    /// matters for this task".
    public static func build(store: SQLiteGraphStore,
                             focus: [String],
                             repository: RepositoryID?) throws -> GraphBoost {
        var adjacent = Set<String>()
        for name in focus {
            for definition in try Lookups.definitions(
                store: store, named: name, repository: repository, limit: 3) {
                adjacent.insert(definition.entity.stableKey.raw)
                let neighbourhood = try Projections.neighborhood(
                    store: store, of: definition.entity.stableKey,
                    kinds: [.refersToSymbol, .references], depth: 1)
                for entity in neighbourhood.entities {
                    adjacent.insert(entity.entity.stableKey.raw)
                }
            }
        }

        // Centrality over file imports/references, reused from the same
        // ranking the repo map uses so the two agree about importance.
        let files = try store.entities(kind: .file, at: .current)
            .filter { repository == nil || $0.entity.repository == repository }
        var edges: [(EntityID, EntityID, Double)] = []
        let ids = Set(files.map(\.entity.id))
        for kind in [RelationshipKind.references, .imports] {
            for edge in try store.relationships(kind: kind, at: .current)
            where ids.contains(edge.source) && ids.contains(edge.target) {
                edges.append((edge.source, edge.target, 1))
            }
        }
        let ranks = Centrality.pageRank(nodes: files.map(\.entity.id), edges: edges)
        let highest = ranks.values.max() ?? 0
        var byPath: [String: Double] = [:]
        if highest > 0 {
            for file in files {
                guard let path = file.version.anchors.first?.path,
                      let rank = ranks[file.entity.id] else { continue }
                byPath[path] = rank / highest
            }
        }
        return GraphBoost(adjacent: adjacent, centrality: byPath)
    }

    public func score(for result: RetrievalResult) -> Double {
        var boost = 0.0
        if let key = result.stableKey?.raw, adjacent.contains(key) {
            boost += Self.adjacencyWeight
        }
        boost += (centrality[result.path] ?? 0) * Self.centralityWeight
        return boost
    }

    public var isEmpty: Bool { adjacent.isEmpty && centrality.isEmpty }
}
