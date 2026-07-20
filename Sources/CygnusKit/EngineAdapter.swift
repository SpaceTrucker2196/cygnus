import Foundation
import CygnusGraph
import CygnusStore
import CygnusQuery
import CygnusEngine

// The real engine behind the GraphEngine seam. Registers + indexes a
// repository through CygnusWorkspace, then projects the graph into
// the immutable GraphSnapshot the renderers and inspector consume.

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
                    let workspace = try CygnusWorkspace(directory: directory)
                    continuation.yield(.phase("scanning"))
                    let repoID = try await workspace.register(path: url)
                    let result = try await workspace.index(repoID) { progress in
                        switch progress.phase {
                        case "extract":
                            continuation.yield(.phase("extracting"))
                            if progress.total > 0 {
                                continuation.yield(.progress(
                                    Double(progress.completed) / Double(progress.total)))
                            }
                        case "resolve": continuation.yield(.phase("resolving"))
                        case "commit": continuation.yield(.phase("committing"))
                        default: break
                        }
                    }
                    continuation.yield(.partialCounts(entities: result.entityCount,
                                                      edges: result.relationshipCount))
                    continuation.yield(.phase("projecting"))
                    let snapshot = try Self.snapshot(from: await workspace.store,
                                                     repository: repoID)
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
        let kinds: [RelationshipKind] = [.containsPhysical, .declares, .imports]
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
                    path: resolved.version.anchors.first?.path)
            }
            .sorted { $0.id < $1.id }

        var edges: [GraphSnapshot.Edge] = []
        for edge in keptEdges {
            guard let from = keyByID[edge.source], let to = keyByID[edge.target] else { continue }
            edges.append(GraphSnapshot.Edge(from: from, to: to, kind: edge.kind.rawValue))
        }

        return GraphSnapshot(nodes: nodes, edges: edges)
    }
}
