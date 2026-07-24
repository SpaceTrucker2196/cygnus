import CygnusGraph

// Derivers compute the derived knowledge layer mechanically from
// observed facts. Every emitted fact carries provenance links to what
// it consumed — the provenance table is the invalidation index.

public struct DeriverIdentity: Hashable, Codable, Sendable {
    public let name: String
    public let version: String
    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

/// A pure pass over the graph: reads current facts, returns the
/// changes that bring the derived layer up to date. Derivers never
/// touch observations, providers, or the store's write path — the
/// caller commits.
public protocol Deriver: Sendable {
    var identity: DeriverIdentity { get }
    func derive(from store: any GraphStore, repository: RepositoryID) throws -> RevisionChanges
}

/// Directory-level import rollups: for every directory, one derived
/// `core:dependsOn` edge per module imported by any file in its
/// subtree, with the aggregate count as a property. Mechanical
/// aggregation of observed facts — no interpretation: "files under
/// Sources/Kit import GRDB 12 times" is arithmetic, not judgment.
///
/// Provenance: each rollup edge is supported by the union of the
/// observation ids behind the file-level import edges it aggregates,
/// so rollups die with their imports (the invalidation invariant).
public struct ImportRollupDeriver: Deriver {
    public let identity = DeriverIdentity(name: "import-rollup", version: "0.1.0")

    /// Property key for the aggregate import count.
    public static let countKey = "core:importCount"

    public init() {}

    public func derive(from store: any GraphStore,
                       repository: RepositoryID) throws -> RevisionChanges {
        let contains = try store.relationships(kind: .containsPhysical, at: .current)
        let imports = try store.relationships(kind: .imports, at: .current)
            .filter { $0.layer == .observed }

        // Resolve every endpoint once.
        var ids = Set<EntityID>()
        for edge in contains { ids.insert(edge.source); ids.insert(edge.target) }
        for edge in imports { ids.insert(edge.source); ids.insert(edge.target) }
        let resolved = try store.entities(ids: Array(ids), at: .current)
        let byID = Dictionary(uniqueKeysWithValues: resolved.map { ($0.entity.id, $0) })

        // Containment children.
        var children: [EntityID: [EntityID]] = [:]
        for edge in contains { children[edge.source, default: []].append(edge.target) }

        // Descendant files per directory, memoized — containment can
        // be a DAG, and memoization is what keeps this linear.
        var descendantFiles: [EntityID: Set<EntityID>] = [:]
        var visiting = Set<EntityID>()
        func files(under id: EntityID) -> Set<EntityID> {
            if let cached = descendantFiles[id] { return cached }
            guard visiting.insert(id).inserted else { return [] }   // cycle: cut
            defer { visiting.remove(id) }
            var result = Set<EntityID>()
            for child in children[id] ?? [] {
                guard let entity = byID[child]?.entity else { continue }
                if entity.kind == .file { result.insert(child) }
                else { result.formUnion(files(under: child)) }
            }
            descendantFiles[id] = result
            return result
        }

        // File → import edges (edge ids kept for provenance).
        var importsByFile: [EntityID: [Relationship]] = [:]
        for edge in imports { importsByFile[edge.source, default: []].append(edge) }

        // Aggregate per (directory, module).
        struct Rollup {
            var count = 0
            var supportedBy = Set<ObservationID>()
        }
        var provenanceCache: [Int64: [ObservationID]] = [:]
        var assertions: [RelationshipAssertion] = []
        var assertedPairs = Set<String>()

        let directories = resolved
            .filter { $0.entity.kind == .directory && $0.entity.repository == repository }
            .sorted { $0.entity.stableKey.raw < $1.entity.stableKey.raw }
        for directory in directories {
            var byModule: [StableKey: Rollup] = [:]
            for file in files(under: directory.entity.id) {
                for edge in importsByFile[file] ?? [] {
                    guard let module = byID[edge.target]?.entity,
                          module.kind == .module else { continue }
                    var rollup = byModule[module.stableKey] ?? Rollup()
                    rollup.count += 1
                    if provenanceCache[edge.id] == nil {
                        provenanceCache[edge.id] = try store.provenance(ofRelationship: edge.id)
                    }
                    rollup.supportedBy.formUnion(provenanceCache[edge.id] ?? [])
                    byModule[module.stableKey] = rollup
                }
            }
            for (module, rollup) in byModule.sorted(by: { $0.key.raw < $1.key.raw }) {
                assertions.append(RelationshipAssertion(
                    source: directory.entity.stableKey, target: module,
                    kind: .dependsOn, layer: .derived,
                    properties: [Self.countKey: .int(Int64(rollup.count))],
                    supportedBy: rollup.supportedBy.sorted { $0.raw < $1.raw }))
                assertedPairs.insert(
                    "\(directory.entity.stableKey.raw)→\(module.raw)#\(rollup.count)")
            }
        }

        // Retract stale rollups. Relationship identity includes
        // properties (a changed count is a different fact), so the
        // identity here carries the count: a count change retracts the
        // old edge and asserts the new one in the same revision.
        var retractions: [Int64] = []
        for edge in try store.relationships(kind: .dependsOn, at: .current)
        where edge.layer == .derived {
            let endpoints = try store.entities(ids: [edge.source, edge.target], at: .current)
            guard let source = endpoints.first(where: { $0.entity.id == edge.source })?.entity,
                  let target = endpoints.first(where: { $0.entity.id == edge.target })?.entity,
                  source.repository == repository
            else { continue }
            let count: Int64? = if case .int(let value)? = edge.properties[Self.countKey] {
                value
            } else { nil }
            let identity = "\(source.stableKey.raw)→\(target.stableKey.raw)#\(count.map(String.init) ?? "?")"
            if !assertedPairs.contains(identity) {
                retractions.append(edge.id)
            }
        }

        return RevisionChanges(relationships: assertions,
                               retractRelationships: retractions)
    }
}
