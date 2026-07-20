import Foundation
import CygnusGraph
import CygnusStore
import CygnusProviders
import CygnusObservation
import CygnusExtractorSwift
import CygnusExtractorTS

// The engine facade. A workspace owns one graph database, one CAS,
// and the extractor registry; the app-side CygnusKit and the CLI
// consume exactly this surface.

public struct IndexProgress: Sendable {
    public let phase: String
    public let completed: Int
    public let total: Int
}

public struct IndexResult: Sendable {
    public let repository: RepositoryID
    public let revision: RevisionID
    public let snapshot: SnapshotID
    public let filesAnalyzed: Int
    public let filesChanged: Int
    public let entityCount: Int
    public let relationshipCount: Int
}

public actor CygnusWorkspace {
    public let directory: URL
    public let store: SQLiteGraphStore
    public let contentStore: ContentStore
    private let extractors: [any ObservationExtractor]

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        self.store = try SQLiteGraphStore.onDisk(at: directory.appendingPathComponent("graph.sqlite"))
        self.contentStore = try ContentStore(root: directory.appendingPathComponent("cas"))
        self.extractors = [SwiftExtractor(), PythonExtractor(), CExtractor()]
    }

    // MARK: - Registration

    @discardableResult
    public func register(path: URL, displayName: String? = nil) throws -> RepositoryID {
        let standardized = path.standardizedFileURL
        let name = displayName ?? standardized.lastPathComponent
        // Reuse the identity of a repo already registered at this path;
        // identity is independent of path, but the same path is the
        // same repo until proven otherwise.
        if let existing = try store.repositories()
            .first(where: { $0.rootPath == standardized.path }) {
            return existing.id
        }
        let id = RepositoryID("\(name)-\(UUID().uuidString.prefix(8).lowercased())")
        try store.registerRepository(id, displayName: name, rootPath: standardized.path)
        return id
    }

    public func repositories() throws -> [SQLiteGraphStore.RegisteredRepository] {
        try store.repositories()
    }

    // MARK: - Indexing

    /// Snapshot the repository and commit one revision containing the
    /// changes since the previous snapshot. First run indexes
    /// everything; later runs are incremental via manifest diff.
    public func index(_ repoID: RepositoryID,
                      progress: (@Sendable (IndexProgress) -> Void)? = nil) async throws -> IndexResult {
        guard let repo = try store.repositories().first(where: { $0.id == repoID }),
              let rootPath = repo.rootPath
        else { throw WorkspaceError.unknownRepository(repoID) }
        let root = URL(fileURLWithPath: rootPath)

        progress?(IndexProgress(phase: "snapshot", completed: 0, total: 1))
        let provider = LocalFSProvider(root: root, contentStore: contentStore)
        let manifest = try provider.snapshot()

        // Previous manifest from the last stored snapshot.
        let previous = try store.latestIndexedSnapshot(repository: repoID).map { _, files in
            SnapshotManifest(files: files.map {
                SnapshotFile(path: $0.path, blob: BlobHash($0.blobHash),
                             size: $0.size, languageHint: $0.languageHint)
            })
        }
        let diff = ManifestDiff.between(previous, manifest)

        // Nothing changed since the last committed snapshot: no new
        // snapshot, no empty revision.
        if diff.isEmpty, previous != nil,
           let current = try store.currentRevision(),
           let (snapshotID, _) = try store.latestIndexedSnapshot(repository: repoID) {
            return IndexResult(
                repository: repoID, revision: current, snapshot: snapshotID,
                filesAnalyzed: manifest.files.count, filesChanged: 0,
                entityCount: 0, relationshipCount: 0)
        }

        let snapshot = try store.recordSnapshot(
            repository: repoID,
            sourceRef: GitInfo.headCommit(of: root),
            files: manifest.files.map {
                SQLiteGraphStore.SnapshotFileRecord(
                    path: $0.path, blobHash: $0.blob.raw,
                    size: $0.size, languageHint: $0.languageHint)
            })

        // Extract observations for changed/added files, in parallel.
        let workList = diff.changedOrAdded.compactMap { file -> (SnapshotFile, any ObservationExtractor)? in
            extractors.first(where: { $0.claims(file: file) }).map { (file, $0) }
        }
        let total = workList.count
        var extracted: [(SnapshotFile, String, [Observation])] = []
        var completed = 0
        try await withThrowingTaskGroup(of: (SnapshotFile, String, [Observation]).self) { group in
            for (file, extractor) in workList {
                let contentStore = self.contentStore
                group.addTask {
                    let content = try contentStore.read(file.blob)
                    let observations = try extractor.extract(file: file, content: content)
                    return (file, file.languageHint ?? "unknown", observations)
                }
            }
            for try await result in group {
                extracted.append(result)
                completed += 1
                progress?(IndexProgress(phase: "extract", completed: completed, total: total))
            }
        }

        progress?(IndexProgress(phase: "resolve", completed: 0, total: 1))

        // Persist observations, keeping ids for provenance.
        var fileObservations: [FileObservations] = []
        for (file, language, observations) in extracted.sorted(by: { $0.0.path < $1.0.path }) {
            let ids = try store.recordObservations(observations, snapshot: snapshot)
            fileObservations.append(FileObservations(
                file: file, language: language,
                observations: Array(zip(ids, observations))))
        }

        // Assertions for the changed subset (plus the full physical
        // tree, whose unchanged assertions dedupe to no-ops).
        var changes = Resolver.resolve(
            repository: repoID, displayName: repo.displayName,
            manifest: manifest, files: fileObservations)

        // Retract facts whose anchor files vanished or changed and
        // whose keys are not re-asserted by this revision.
        let reasserted = Set(changes.entities.map(\.stableKey))
        var retracted = Set<StableKey>()
        for path in diff.retractedPaths {
            for key in try store.currentEntityKeys(anchoredIn: path)
            where !reasserted.contains(key) && !retracted.contains(key) {
                retracted.insert(key)
                changes.retractEntities.append(key)
            }
        }

        // Surviving entities in changed files can still carry stale
        // outgoing edges (a dropped import, a moved declaration).
        // Retract every current edge from a file-anchored entity that
        // this revision does not re-assert.
        func edgeIdentity(source: StableKey, target: StableKey, kind: RelationshipKind,
                          layer: KnowledgeLayer, properties: PropertyBag) throws -> String {
            "\(source.raw)|\(target.raw)|\(kind.rawValue)|\(layer.rawValue)|\(try CanonicalJSON.encode(properties))"
        }
        let assertedEdges = Set(try changes.relationships.map {
            try edgeIdentity(source: $0.source, target: $0.target, kind: $0.kind,
                             layer: $0.layer, properties: $0.properties)
        })
        for path in diff.retractedPaths {
            for key in try store.currentEntityKeys(anchoredIn: path) where !retracted.contains(key) {
                for edge in try store.relationships(from: key, kind: nil, at: .current) {
                    let endpoints = try store.entities(ids: [edge.source, edge.target], at: .current)
                    guard let sourceKey = endpoints.first(where: { $0.entity.id == edge.source })?.entity.stableKey,
                          let targetKey = endpoints.first(where: { $0.entity.id == edge.target })?.entity.stableKey,
                          // Edges to entities retracted this commit are
                          // closed by the entity retraction itself.
                          !retracted.contains(targetKey)
                    else { continue }
                    let identity = try edgeIdentity(source: sourceKey, target: targetKey,
                                                    kind: edge.kind, layer: edge.layer,
                                                    properties: edge.properties)
                    if !assertedEdges.contains(identity) {
                        changes.retractRelationships.append(edge.id)
                    }
                }
            }
        }

        progress?(IndexProgress(phase: "commit", completed: 0, total: 1))
        let revision = try store.commit(
            changes,
            note: "index \(repo.displayName): +\(diff.added.count) ~\(diff.modified.count) -\(diff.removed.count)",
            snapshot: snapshot)

        return IndexResult(
            repository: repoID, revision: revision, snapshot: snapshot,
            filesAnalyzed: manifest.files.count,
            filesChanged: diff.changedOrAdded.count + diff.removed.count,
            entityCount: changes.entities.count,
            relationshipCount: changes.relationships.count)
    }
}

public enum WorkspaceError: Error, Equatable {
    case unknownRepository(RepositoryID)
}
