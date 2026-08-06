import Foundation
import CygnusGraph
import CygnusStore

// The structural questions an agent actually asks. Almost all of this
// is wrapping query methods that already existed and were already
// tested but had no single-call entry point — the data was there, the
// door wasn't.
//
// One rule runs through the whole file: never return a confident empty
// answer. "Nothing calls this" and "this repository was never built,
// so nothing can be known about what calls it" are different facts,
// and collapsing them is how a tool quietly talks an agent into
// deleting live code.

public enum Lookups {
    /// Kinds that can be the *definition* of a symbol. Excludes files,
    /// directories and modules — a directory named `send` is never the
    /// answer to "where is `send` defined".
    public static let definitionKinds: [EntityKind] =
        [.type, .interface, .enumeration, .function, .variable]

    /// What backs an answer, so a caller can say so.
    public enum Evidence: String, Sendable, Hashable {
        /// Compiler-resolved: an index store existed and was read.
        case compiler
        /// The repository has no compiler-resolved edges at all — it
        /// was never built, or the build produced no index store.
        /// An empty result here means "unknown", not "none".
        case unavailable
    }

    public struct Reference: Sendable {
        public let edge: Relationship
        public let source: ResolvedEntity
        public let referenceCount: Int64
        public let callCount: Int64

        public init(edge: Relationship, source: ResolvedEntity,
                    referenceCount: Int64, callCount: Int64) {
            self.edge = edge
            self.source = source
            self.referenceCount = referenceCount
            self.callCount = callCount
        }
    }

    public struct ReferenceAnswer: Sendable {
        public let references: [Reference]
        public let evidence: Evidence

        public init(references: [Reference], evidence: Evidence) {
            self.references = references
            self.evidence = evidence
        }
    }

    // MARK: - Definitions

    public static func definitions(store: SQLiteGraphStore, named name: String,
                                   kinds: [EntityKind]? = nil,
                                   repository: RepositoryID? = nil,
                                   limit: Int = 10) throws -> [ResolvedEntity] {
        try store.searchNames(name, kinds: kinds ?? definitionKinds,
                              repository: repository, limit: limit)
    }

    /// Symbols declared in a file, in source order.
    public static func symbols(store: SQLiteGraphStore, in path: String) throws -> [ResolvedEntity] {
        try store.resolvedEntities(anchoredIn: path)
            .filter { definitionKinds.contains($0.entity.kind) }
            .sorted { lhs, rhs in
                let left = lhs.version.anchors.first?.range?.startLine ?? 0
                let right = rhs.version.anchors.first?.range?.startLine ?? 0
                return left == right
                    ? lhs.entity.stableKey.raw < rhs.entity.stableKey.raw
                    : left < right
            }
    }

    // MARK: - References and callers

    /// Everything referring to a symbol, whether or not it calls it.
    public static func references(store: SQLiteGraphStore,
                                  to key: StableKey) throws -> ReferenceAnswer {
        try answer(store: store, to: key, callsOnly: false)
    }

    /// Only the references the compiler marked as **calls**.
    ///
    /// Measured on cygnus, 93% of `refersToSymbol` edges carry zero
    /// calls, so a caller graph that skipped this filter would be
    /// wrong about the overwhelming majority of its answers while
    /// looking exactly as authoritative.
    public static func callers(store: SQLiteGraphStore,
                               of key: StableKey) throws -> ReferenceAnswer {
        try answer(store: store, to: key, callsOnly: true)
    }

    private static func answer(store: SQLiteGraphStore, to key: StableKey,
                               callsOnly: Bool) throws -> ReferenceAnswer {
        guard let target = try store.entity(stableKey: key, at: .current) else {
            return ReferenceAnswer(references: [], evidence: .unavailable)
        }
        let repository = target.entity.repository
        let evidence: Evidence = try repository
            .map { try store.hasCompilerReferences(repository: $0) ? .compiler : .unavailable }
            ?? .unavailable

        let edges = try store.relationships(to: key, kind: .refersToSymbol, at: .current)
        let sources = try store.entities(ids: edges.map(\.source), at: .current)
        let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.entity.id, $0) })

        let references = edges.compactMap { edge -> Reference? in
            guard let source = byID[edge.source] else { return nil }
            let referenceCount = Self.count(edge, "core:referenceCount")
            let callCount = Self.count(edge, "core:callCount")
            if callsOnly && callCount == 0 { return nil }
            return Reference(edge: edge, source: source,
                             referenceCount: referenceCount, callCount: callCount)
        }
        .sorted { lhs, rhs in
            let left = callsOnly ? lhs.callCount : lhs.referenceCount
            let right = callsOnly ? rhs.callCount : rhs.referenceCount
            return left == right
                ? lhs.source.entity.stableKey.raw < rhs.source.entity.stableKey.raw
                : left > right
        }
        return ReferenceAnswer(references: references, evidence: evidence)
    }

    private static func count(_ edge: Relationship, _ key: String) -> Int64 {
        if case .int(let value)? = edge.properties[key] { return value }
        return 0
    }

    // MARK: - Blast radius

    /// What a change to this symbol could reach, ordered by centrality
    /// so that truncating the answer drops the least important nodes
    /// rather than arbitrary ones.
    public static func blastRadius(store: SQLiteGraphStore, of key: StableKey,
                                   depth: Int = 2) throws -> [ResolvedEntity] {
        let subgraph = try Projections.neighborhood(
            store: store, of: key,
            kinds: [.refersToSymbol, .references, .imports, .declares],
            depth: depth)
        guard !subgraph.entities.isEmpty else { return [] }

        let ranks = Centrality.pageRank(
            nodes: subgraph.entities.map(\.entity.id),
            edges: subgraph.relationships.map {
                ($0.source, $0.target, Double(count($0, "core:referenceCount").magnitude) + 1)
            },
            personalization: Set(subgraph.entities
                .filter { $0.entity.stableKey == key }
                .map(\.entity.id)))

        return subgraph.entities.sorted { lhs, rhs in
            let left = ranks[lhs.entity.id] ?? 0
            let right = ranks[rhs.entity.id] ?? 0
            return left == right
                ? lhs.entity.stableKey.raw < rhs.entity.stableKey.raw
                : left > right
        }
    }
}
