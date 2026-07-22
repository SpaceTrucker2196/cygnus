import Foundation
import CygnusGraph
import CygnusObservation
import CygnusProviders
import CygnusEngine

// Builds growing snapshots during analysis by running the engine's
// pure Resolver over whatever has been extracted so far. Partials are
// render-only projections — provenance and persistence stay with the
// engine's real commit; observation ids are placeholders here.

final class PartialSnapshotBuilder: @unchecked Sendable {
    private let repository: RepositoryID
    private let displayName: String
    private let lock = NSLock()
    private var manifest: SnapshotManifest?
    private var files: [FileObservations] = []
    private var sinceLastEmit = 0
    private var lastEmit = ContinuousClock.now

    /// Emit a partial at most this often (whichever comes first).
    private static let batchSize = 12
    private static let interval = Duration.milliseconds(300)

    init(repository: RepositoryID, displayName: String) {
        self.repository = repository
        self.displayName = displayName
    }

    /// The manifest arrives first: the physical tree (repo, dirs,
    /// files) renders before any extraction finishes.
    func setManifest(_ files: [SnapshotFile]) -> GraphSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        manifest = SnapshotManifest(files: files)
        return buildLocked()
    }

    func add(_ extracted: ExtractedFile) -> GraphSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        files.append(FileObservations(
            file: extracted.file, language: extracted.language,
            observations: extracted.observations.map { (ObservationID(0), $0) }))
        sinceLastEmit += 1
        let due = sinceLastEmit >= Self.batchSize
            || ContinuousClock.now - lastEmit >= Self.interval
        guard due else { return nil }
        return buildLocked()
    }

    private func buildLocked() -> GraphSnapshot? {
        guard let manifest else { return nil }
        sinceLastEmit = 0
        lastEmit = .now
        let changes = Resolver.resolve(
            repository: repository, displayName: displayName,
            manifest: manifest, files: files)
        return Self.snapshot(from: changes)
    }

    /// A snapshot straight from resolver assertions — stable keys are
    /// all the renderer needs; no store round-trip.
    static func snapshot(from changes: RevisionChanges) -> GraphSnapshot {
        let nodes = changes.entities.map { assertion in
            GraphSnapshot.Node(
                id: assertion.stableKey.raw,
                kind: assertion.kind.rawValue,
                label: assertion.name,
                path: assertion.anchors.first?.path)
        }
        let edges = changes.relationships.map { assertion in
            GraphSnapshot.Edge(from: assertion.source.raw,
                               to: assertion.target.raw,
                               kind: assertion.kind.rawValue)
        }
        return GraphSnapshot(nodes: nodes.sorted { $0.id < $1.id }, edges: edges)
    }
}
