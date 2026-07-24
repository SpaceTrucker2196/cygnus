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
    private var lastEmit = ContinuousClock.now

    /// Emit a partial at most this often. Each partial is a full
    /// graph copy — time-only throttling keeps peak memory flat no
    /// matter how fast extraction runs.
    private static let interval = Duration.milliseconds(800)

    /// The live preview retains a copy of every file's observations so
    /// it can re-resolve the growing graph — a second full copy beside
    /// the engine's. Past this many files that copy costs more than the
    /// preview is worth, so we freeze it: the final snapshot is
    /// projected from the committed store regardless.
    private static let previewFileCap = 4000

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
        // Freeze the preview once it's grown large enough that a second
        // copy of the observations would compete with the engine for
        // memory. No append, no re-resolve, no new snapshot allocation.
        guard files.count < Self.previewFileCap else { return nil }
        files.append(FileObservations(
            file: extracted.file, language: extracted.language,
            observations: extracted.observations.map { (ObservationID(0), $0) }))
        guard ContinuousClock.now - lastEmit >= Self.interval else { return nil }
        return buildLocked()
    }

    private func buildLocked() -> GraphSnapshot? {
        guard let manifest else { return nil }
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
