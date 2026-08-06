import Foundation
import CygnusGraph
import CygnusStore

// Query surface the viewer consumes. Projections are computed on
// demand and returned as plain values — disposable, never persisted
// as separate models.

/// A renderable slice of the graph: entities plus the relationships
/// among them.
public struct Subgraph: Sendable {
    public let entities: [ResolvedEntity]
    public let relationships: [Relationship]
    public init(entities: [ResolvedEntity], relationships: [Relationship]) {
        self.entities = entities
        self.relationships = relationships
    }
}

/// A node in the physical/logical containment tree.
public struct TreeProjection: Sendable {
    public let entity: ResolvedEntity
    public let children: [TreeProjection]
    public init(entity: ResolvedEntity, children: [TreeProjection]) {
        self.entity = entity
        self.children = children
    }
}

public enum Projections {
    /// Containment trees rooted at each repository entity, following
    /// containsPhysical (repo → dir → file) then declares (file →
    /// declarations).
    public static func containsTrees(store: SQLiteGraphStore,
                                     at query: RevisionQuery = .current) throws -> [TreeProjection] {
        let contains = try store.relationships(kind: .containsPhysical, at: query)
        let declares = try store.relationships(kind: .declares, at: query)
        let edges = contains + declares

        var children: [EntityID: [EntityID]] = [:]
        var hasParent = Set<EntityID>()
        for edge in edges {
            children[edge.source, default: []].append(edge.target)
            hasParent.insert(edge.target)
        }

        let allIDs = Set(edges.flatMap { [$0.source, $0.target] })
        let entities = try store.entities(ids: Array(allIDs), at: query)
        let byID = Dictionary(uniqueKeysWithValues: entities.map { ($0.entity.id, $0) })

        func build(_ id: EntityID) -> TreeProjection? {
            guard let entity = byID[id] else { return nil }
            let kids = (children[id] ?? [])
                .compactMap(build)
                .sorted { $0.entity.version.name < $1.entity.version.name }
            return TreeProjection(entity: entity, children: kids)
        }

        let roots = entities
            .filter { $0.entity.kind == .repository && !hasParent.contains($0.entity.id) }
            .sorted { $0.version.name < $1.version.name }
        return roots.compactMap { build($0.entity.id) }
    }

    /// The import graph: file and module entities connected by
    /// imports edges.
    public static func dependencyGraph(store: SQLiteGraphStore,
                                       at query: RevisionQuery = .current) throws -> Subgraph {
        let imports = try store.relationships(kind: .imports, at: query)
        let ids = Set(imports.flatMap { [$0.source, $0.target] })
        let entities = try store.entities(ids: Array(ids), at: query)
        return Subgraph(entities: entities.sorted { $0.entity.stableKey.raw < $1.entity.stableKey.raw },
                        relationships: imports)
    }

    /// Breadth-first neighborhood of one entity across the given
    /// relationship kinds (both directions).
    public static func neighborhood(store: SQLiteGraphStore, of key: StableKey,
                                    kinds: [RelationshipKind]? = nil, depth: Int = 1,
                                    at query: RevisionQuery = .current) throws -> Subgraph {
        guard let origin = try store.entity(stableKey: key, at: query) else {
            return Subgraph(entities: [], relationships: [])
        }
        var frontier = [origin]
        var seen: [EntityID: ResolvedEntity] = [origin.entity.id: origin]
        var edges: [Int64: Relationship] = [:]

        for _ in 0..<max(depth, 0) {
            // Collect the whole level's edges first, then resolve every
            // newly discovered endpoint in ONE query. Resolving inside
            // the edge loop issued one round trip per node, which the
            // serialized DatabaseQueue turns into hundreds of blocking
            // queries for a depth-2 walk off a hub symbol.
            var discovered = Set<EntityID>()
            for entity in frontier {
                let outgoing = try store.relationships(
                    from: entity.entity.stableKey, kind: nil, at: query)
                let incoming = try store.relationships(
                    to: entity.entity.stableKey, kind: nil, at: query)
                for edge in outgoing + incoming
                where kinds == nil || kinds!.contains(edge.kind) {
                    edges[edge.id] = edge
                    for id in [edge.source, edge.target] where seen[id] == nil {
                        discovered.insert(id)
                    }
                }
            }
            if discovered.isEmpty { break }

            // Sorted so the traversal order — and therefore any
            // downstream truncation — is deterministic.
            let next = try store.entities(ids: Array(discovered), at: query)
                .sorted { $0.entity.stableKey.raw < $1.entity.stableKey.raw }
            for resolved in next { seen[resolved.entity.id] = resolved }
            frontier = next
        }

        return Subgraph(
            entities: seen.values.sorted { $0.entity.stableKey.raw < $1.entity.stableKey.raw },
            relationships: edges.values.sorted { $0.id < $1.id })
    }
}
