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

    /// Project one repository's current graph into a render-ready
    /// snapshot: containment + declaration + import edges owned by
    /// the repo, plus the shared module entities they point at. The
    /// workspace stores many repos; a snapshot never mixes them.
    static func snapshot(from store: SQLiteGraphStore,
                         repository: RepositoryID) throws -> GraphSnapshot {
        let kinds: [RelationshipKind] = [.containsPhysical, .declares, .imports,
                                         .references, .refersToSymbol]
        var entityIDs = Set<EntityID>()
        var rawEdges: [Relationship] = []
        for kind in kinds {
            for edge in try store.relationships(kind: kind, at: .current) {
                rawEdges.append(edge)
                entityIDs.insert(edge.source)
                entityIDs.insert(edge.target)
            }
        }

        let entities = try store.entities(ids: Array(entityIDs), at: .current)
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
                    line: resolved.version.anchors.first?.range?.startLine)
            }
            .sorted { $0.id < $1.id }

        var edges: [GraphSnapshot.Edge] = []
        for edge in keptEdges {
            guard let from = keyByID[edge.source], let to = keyByID[edge.target] else { continue }
            let weight: Int = if case .int(let n)? = edge.properties["core:referenceCount"] {
                Int(n)
            } else { 1 }
            edges.append(GraphSnapshot.Edge(from: from, to: to,
                                            kind: edge.kind.rawValue, weight: weight))
        }

        return GraphSnapshot(nodes: nodes, edges: edges)
    }
}
