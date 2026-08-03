import Foundation
import CygnusGraph
import CygnusStore
import CygnusQuery
import CygnusObservation
import CygnusProviders
import CygnusEngine

// The real engine behind the GraphEngine seam. Registers + indexes a
// repository through CygnusWorkspace, then projects the graph into
// the immutable GraphSnapshot the renderers and inspector consume.

/// One CygnusWorkspace per directory, process-wide. A workspace owns
/// a GRDB DatabasePool, and two pools on the same database file in
/// one process is a GRDB programmer error — concurrent analyses were
/// doing exactly that (one fresh workspace per analyze) and crashing
/// in statement binding. The actor also serializes creation.
private actor WorkspaceCache {
    static let shared = WorkspaceCache()
    private var workspaces: [String: CygnusWorkspace] = [:]

    func workspace(directory: URL) throws -> CygnusWorkspace {
        let key = directory.standardizedFileURL.path
        if let existing = workspaces[key] { return existing }
        let created = try CygnusWorkspace(directory: directory)
        workspaces[key] = created
        return created
    }
}

public struct WorkspaceGraphEngine: GraphEngine {
    private let workspaceDirectory: URL

    /// Engine data lives inside the app container by default.
    public init(directory: URL? = nil) {
        self.workspaceDirectory = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Cygnus/engine")
    }

    public func analyze(repoAt url: URL) -> AsyncThrowingStream<AnalysisEvent, any Error> {
        let directory = workspaceDirectory
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let workspace = try await WorkspaceCache.shared.workspace(directory: directory)
                    continuation.yield(.phase("scanning"))
                    let repoID = try await workspace.register(path: url)
                    let displayName = url.lastPathComponent

                    // Accumulates extraction results and projects a
                    // partial snapshot every batch, so the graph
                    // grows on screen while the engine works.
                    let builder = PartialSnapshotBuilder(
                        repository: repoID, displayName: displayName)

                    let result = try await workspace.index(repoID) { progress in
                        switch progress.phase {
                        case "snapshot":
                            if let files = progress.manifest,
                               let partial = builder.setManifest(files) {
                                continuation.yield(.partial(partial))
                            }
                        case "extract":
                            continuation.yield(.phase("extracting"))
                            if progress.total > 0 {
                                continuation.yield(.progress(
                                    Double(progress.completed) / Double(progress.total)))
                            }
                            if let extracted = progress.extracted,
                               let partial = builder.add(extracted) {
                                continuation.yield(.partial(partial))
                            }
                        case "resolve": continuation.yield(.phase("resolving"))
                        case "commit": continuation.yield(.phase("committing"))
                        default: break
                        }
                    }
                    continuation.yield(.partialCounts(entities: result.entityCount,
                                                      edges: result.relationshipCount))
                    continuation.yield(.phase("projecting"))
                    // Project on the actor so the read is serialized
                    // with index() writes — the store is shared across
                    // all repos, and reading it off-actor raced writes
                    // from a concurrent analysis (issue #2/#3).
                    let snapshot = try await workspace.withStore { store in
                        try Self.snapshot(from: store, repository: repoID)
                    }
                    continuation.yield(.finished(snapshot))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - History

    public func revisions(repoAt url: URL) async throws -> [GraphRevision] {
        let workspace = try await WorkspaceCache.shared.workspace(directory: workspaceDirectory)
        return try await workspace.withStore { store in
            try store.revisions().map {
                GraphRevision(id: $0.id.raw, createdAt: $0.createdAt, note: $0.note)
            }
        }
    }

    public func delta(repoAt url: URL, from: Int64, to: Int64) async throws -> RevisionDelta {
        let workspace = try await WorkspaceCache.shared.workspace(directory: workspaceDirectory)
        guard let repoID = try await Self.repositoryID(in: workspace, at: url) else {
            return RevisionDelta()
        }
        return try await workspace.withStore { store in
            let delta = try store.diff(from: RevisionID(from), to: RevisionID(to))
            func keys(_ versions: [ResolvedEntity]) -> Set<String> {
                Set(versions.filter { $0.entity.repository == repoID }
                    .map(\.entity.stableKey.raw))
            }
            let asserted = keys(delta.assertedEntityVersions)
            let retracted = keys(delta.retractedEntityVersions)
            // Asserted and retracted in the same window means the
            // entity survived with new content, not that it came and
            // went.
            let owned = try Self.ownedEntityIDs(store: store, repository: repoID)
            func countEdges(_ edges: [Relationship]) -> Int {
                edges.filter { owned.contains($0.source) }.count
            }
            return RevisionDelta(
                addedNodes: asserted.subtracting(retracted),
                removedNodes: retracted.subtracting(asserted),
                changedNodes: asserted.intersection(retracted),
                addedEdges: countEdges(delta.assertedRelationships),
                removedEdges: countEdges(delta.retractedRelationships))
        }
    }

    public func snapshot(repoAt url: URL, asOf revision: Int64) async throws -> GraphSnapshot {
        let workspace = try await WorkspaceCache.shared.workspace(directory: workspaceDirectory)
        guard let repoID = try await Self.repositoryID(in: workspace, at: url) else {
            return GraphSnapshot(nodes: [], edges: [])
        }
        return try await workspace.withStore { store in
            try Self.snapshot(from: store, repository: repoID,
                              at: .asOf(RevisionID(revision)))
        }
    }

    /// The registered repository whose root is this URL. Matched
    /// rather than re-registered: registering has side effects, and a
    /// read must not mutate the workspace.
    private static func repositoryID(in workspace: CygnusWorkspace,
                                     at url: URL) async throws -> RepositoryID? {
        let wanted = url.standardizedFileURL.path
        return try await workspace.repositories()
            .first { $0.rootPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == wanted }?
            .id
    }

    /// Entity properties a renderer is allowed to see. An allow-list,
    /// not a copy of the bag: the snapshot is a projection, and
    /// widening it silently is how it stops being one.
    static let projectedProperties = ["core:lastCommit", "core:buildSystem"]
    static let projectedIntProperties = ["core:buildOrder"]
    /// Ordered lists, joined with a unit separator. The snapshot's
    /// attribute bag is strings, and a renderer that needs the order
    /// splits it back — cheaper than widening the value type for the
    /// one case that needs it.
    static let projectedListProperties = ["core:buildSteps"]
    static let listSeparator = "\u{1f}"

    static func projectedAttributes(of resolved: ResolvedEntity) -> [String: String] {
        var result: [String: String] = [:]
        for key in projectedProperties {
            if case .string(let value)? = resolved.version.properties[key] {
                result[key] = value
            }
        }
        for key in projectedIntProperties {
            if case .int(let value)? = resolved.version.properties[key] {
                result[key] = String(value)
            }
        }
        for key in projectedListProperties {
            guard case .array(let values)? = resolved.version.properties[key] else { continue }
            let strings = values.compactMap { value -> String? in
                if case .string(let text) = value { text } else { nil }
            }
            if !strings.isEmpty { result[key] = strings.joined(separator: listSeparator) }
        }
        return result
    }

    /// Entity ids belonging to a repository — the filter that keeps
    /// one repo's counts out of another's.
    private static func ownedEntityIDs(store: SQLiteGraphStore,
                                       repository: RepositoryID) throws -> Set<EntityID> {
        var ids = Set<EntityID>()
        for kind in Self.projectedKinds {
            for edge in try store.relationships(kind: kind, at: .current) {
                ids.insert(edge.source)
            }
        }
        let entities = try store.entities(ids: Array(ids), at: .current)
        return Set(entities.filter { $0.entity.repository == repository }.map(\.entity.id))
    }

    static let projectedKinds: [RelationshipKind] = [
        .containsPhysical, .declares, .imports, .references, .refersToSymbol, .builds,
        .authoredBy, .ownedBy,
    ]

    /// Project one repository's current graph into a render-ready
    /// snapshot: containment + declaration + import edges owned by
    /// the repo, plus the shared module entities they point at. The
    /// workspace stores many repos; a snapshot never mixes them.
    static func snapshot(from store: SQLiteGraphStore,
                         repository: RepositoryID,
                         at query: RevisionQuery = .current) throws -> GraphSnapshot {
        var entityIDs = Set<EntityID>()
        var rawEdges: [Relationship] = []
        for kind in Self.projectedKinds {
            for edge in try store.relationships(kind: kind, at: query) {
                rawEdges.append(edge)
                entityIDs.insert(edge.source)
                entityIDs.insert(edge.target)
            }
        }

        let entities = try store.entities(ids: Array(entityIDs), at: query)
        let ownedIDs = Set(entities.filter { $0.entity.repository == repository }
            .map(\.entity.id))
        let keptEdges = rawEdges.filter { ownedIDs.contains($0.source) }
        let reachedIDs = Set(keptEdges.map(\.target)).union(ownedIDs)
        let kept = entities.filter { reachedIDs.contains($0.entity.id) }
        let keyByID = Dictionary(uniqueKeysWithValues: kept.map { ($0.entity.id, $0.entity.stableKey.raw) })

        let nodes = kept
            .map { resolved in
                GraphSnapshot.Node(
                    id: resolved.entity.stableKey.raw,
                    kind: resolved.entity.kind.rawValue,
                    label: resolved.version.name,
                    path: resolved.version.anchors.first?.path,
                    line: resolved.version.anchors.first?.range?.startLine,
                    attributes: Self.projectedAttributes(of: resolved))
            }
            .sorted { $0.id < $1.id }

        var edges: [GraphSnapshot.Edge] = []
        for edge in keptEdges {
            guard let from = keyByID[edge.source], let to = keyByID[edge.target] else { continue }
            // Whatever count the edge aggregates becomes its weight —
            // references for enrichment edges, commits for authorship.
            let weight: Int = if case .int(let n)? = edge.properties["core:referenceCount"] {
                Int(n)
            } else if case .int(let n)? = edge.properties["core:commitCount"] {
                Int(n)
            } else { 1 }
            edges.append(GraphSnapshot.Edge(from: from, to: to,
                                            kind: edge.kind.rawValue, weight: weight))
        }

        return GraphSnapshot(nodes: nodes, edges: edges)
    }
}
