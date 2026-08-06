import Foundation
import CygnusGraph
import CygnusStore
import CygnusQuery
import CygnusRetrieval
import CygnusProviders
import CygnusObservation
import CygnusDerive
import CygnusExtractorSwift
import CygnusExtractorTS
import CygnusExtractorIndex
import CygnusExtractorBuild

// The engine facade. A workspace owns one graph database, one CAS,
// and the extractor registry; the app-side CygnusKit and the CLI
// consume exactly this surface.

public struct IndexProgress: Sendable {
    public let phase: String
    public let completed: Int
    public let total: Int
    /// The full manifest, delivered once with the "snapshot" phase —
    /// consumers can render the physical tree before extraction.
    public let manifest: [SnapshotFile]?
    /// One file's extraction result, delivered live during the
    /// "extract" phase — consumers can grow the graph in realtime.
    public let extracted: ExtractedFile?

    public init(phase: String, completed: Int, total: Int,
                manifest: [SnapshotFile]? = nil, extracted: ExtractedFile? = nil) {
        self.phase = phase
        self.completed = completed
        self.total = total
        self.manifest = manifest
        self.extracted = extracted
    }
}

public struct ExtractedFile: Sendable {
    public let file: SnapshotFile
    public let language: String
    public let observations: [Observation]
}

public struct IndexResult: Sendable {
    public let repository: RepositoryID
    public let revision: RevisionID
    public let snapshot: SnapshotID
    public let filesAnalyzed: Int
    public let filesChanged: Int
    public let filesRenamed: Int
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
        self.extractors = [SwiftExtractor(), PythonExtractor(), CExtractor(), RustExtractor(),
                           BuildExtractor()]
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

    /// Run a read against the store **on the actor**, so it's
    /// serialized with `index()` writes rather than racing them from
    /// another thread. All store access for one workspace must go
    /// through here (or the actor's own methods) — the store is shared
    /// across every repo in a workspace. The projection type lives in
    /// the app layer, so it's threaded in as a closure.
    public func withStore<T: Sendable>(
        _ body: @Sendable (SQLiteGraphStore) throws -> T) rethrows -> T {
        try body(store)
    }

    // MARK: - Indexing

    /// Snapshot the repository and commit one revision containing the
    /// changes since the previous snapshot. First run indexes
    /// everything; later runs are incremental via manifest diff.
    public func index(_ repoID: RepositoryID,
                      limits: IndexLimits = .default,
                      progress: (@Sendable (IndexProgress) -> Void)? = nil) async throws -> IndexResult {
        guard let repo = try store.repositories().first(where: { $0.id == repoID }),
              let rootPath = repo.rootPath
        else { throw WorkspaceError.unknownRepository(repoID) }
        let root = URL(fileURLWithPath: rootPath)

        let provider = LocalFSProvider(root: root, contentStore: contentStore)
        // The walk ingests the whole working tree — it must honour the
        // same hard limit as extraction, and respond to cancellation
        // (a cancelled analysis must stop working, not grind on as a
        // zombie behind the actor).
        let manifest = try provider.snapshot(budget: {
            try Task.checkCancellation()
            try limits.checkHardLimit()
        })
        progress?(IndexProgress(phase: "snapshot", completed: 1, total: 1,
                                manifest: manifest.files))

        // Previous manifest from the last stored snapshot.
        let previous = try store.latestIndexedSnapshot(repository: repoID).map { _, files in
            SnapshotManifest(files: files.map {
                SnapshotFile(path: $0.path, blob: BlobHash($0.blobHash),
                             size: $0.size, languageHint: $0.languageHint)
            })
        }
        let diff = ManifestDiff.between(previous, manifest)

        // Nothing changed since the last committed snapshot: no new
        // snapshot, no empty revision. But an index store may have
        // appeared since the last run (the "Build Index" button, a CI
        // build) — reference enrichment reads that, not the source, so
        // run it even on a source no-op or symbols would never show up
        // after a build.
        if diff.isEmpty, previous != nil,
           let current = try store.currentRevision(),
           let (snapshotID, _) = try store.latestIndexedSnapshot(repository: repoID) {
            var revision = current
            do {
                if let enriched = try await enrichReferences(
                    repoID: repoID, root: root, snapshot: snapshotID,
                    currentPaths: Set(manifest.files.map(\.path)), progress: progress) {
                    revision = enriched
                }
            } catch {
                FileHandle.standardError.write(Data("enrichment skipped: \(error)\n".utf8))
            }
            return IndexResult(
                repository: repoID, revision: revision, snapshot: snapshotID,
                filesAnalyzed: manifest.files.count, filesChanged: 0, filesRenamed: 0,
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
        // Bounded, memory-aware sliding window: at most `limits.window()`
        // files parse at once (that count of syntax trees is the peak),
        // and the window shrinks to one whenever the process footprint
        // crosses the soft brake — so a huge repo can't fan out into
        // hundreds of concurrent trees and exhaust memory.
        try await withThrowingTaskGroup(of: (SnapshotFile, String, [Observation]).self) { group in
            let contentStore = self.contentStore
            var iterator = workList.makeIterator()
            var inFlight = 0

            func submitNext() -> Bool {
                guard let (file, extractor) = iterator.next() else { return false }
                group.addTask {
                    let content = try contentStore.read(file.blob)
                    let observations = try extractor.extract(file: file, content: content)
                    return (file, file.languageHint ?? "unknown", observations)
                }
                inFlight += 1
                return true
            }

            // Seed the window.
            while inFlight < limits.window(), submitNext() {}

            while let result = try await group.next() {
                inFlight -= 1
                extracted.append(result)
                completed += 1
                // Results accumulate for the whole run — the hard
                // limit is the only bound on that growth. Throwing
                // here cancels the group; nothing has been committed.
                try Task.checkCancellation()
                try limits.checkHardLimit()
                progress?(IndexProgress(
                    phase: "extract", completed: completed, total: total,
                    extracted: ExtractedFile(file: result.0, language: result.1,
                                             observations: result.2)))
                // Top the window back up to its current (possibly
                // pressure-reduced) width before awaiting the next.
                while inFlight < limits.window(), submitNext() {}
            }
        }

        // Resolve makes further full copies (fileObservations, the
        // assertion set) — don't start it without headroom.
        try limits.checkHardLimit()
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
        // tree, whose unchanged assertions dedupe to no-ops). Detected
        // renames thread identity: the new file entity records the
        // path its content evidently moved from.
        var changes = Resolver.resolve(
            repository: repoID, displayName: repo.displayName,
            manifest: manifest, files: fileObservations,
            renamedFrom: diff.renamedFrom)

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
        let renameNote = diff.renames.isEmpty ? "" : " ↷\(diff.renames.count)"
        let revision = try store.commit(
            changes,
            note: "index \(repo.displayName): +\(diff.added.count) ~\(diff.modified.count) -\(diff.removed.count)\(renameNote)",
            snapshot: snapshot)

        // Derive pass: bring the derived layer up to date from the
        // just-committed observed facts. Its own revision (one
        // transaction), skipped entirely when nothing changed. The
        // result reports the final revision — the one the graph is at.
        progress?(IndexProgress(phase: "derive", completed: 0, total: 1))
        let derived = try ImportRollupDeriver().derive(from: store, repository: repoID)
        var finalRevision = revision
        if !derived.relationships.isEmpty || !derived.retractRelationships.isEmpty {
            finalRevision = try store.commit(
                derived, note: "derive \(repo.displayName): import rollups")
        }

        // Lexical retrieval index. Runs before enrichment so search
        // freshness never waits on a slow index-store read, and writes
        // no graph facts — it is an index over the CAS, so it mints no
        // revision and cannot affect `verify`. Best-effort on the same
        // contract as enrichment.
        do {
            progress?(IndexProgress(phase: "retrieve", completed: 0, total: 1))
            try RetrievalIndexer(store: store, contentStore: contentStore)
                .index(blobs: manifest.files.map(\.blob))
        } catch {
            FileHandle.standardError.write(Data("retrieval index skipped: \(error)\n".utf8))
        }

        // Index-store enrichment: compiler-resolved reference edges,
        // when a build has produced an index store. Best-effort by
        // contract — enrichment can never fail the index, but its
        // failures are reported, never swallowed.
        do {
            if let enriched = try await enrichReferences(
                repoID: repoID, root: root, snapshot: snapshot,
                currentPaths: Set(manifest.files.map(\.path)), progress: progress) {
                finalRevision = enriched
            }
        } catch {
            FileHandle.standardError.write(Data("enrichment skipped: \(error)\n".utf8))
        }

        // Authorship: who has worked on what, and where ownership
        // concentrates. Best-effort on the same contract — a repo
        // without git, or with git unavailable, simply has no
        // ownership facts.
        do {
            if let owned = try enrichOwnership(
                repoID: repoID, root: root, snapshot: snapshot,
                currentPaths: Set(manifest.files.map(\.path)),
                displayName: repo.displayName, progress: progress) {
                finalRevision = owned
            }
        } catch {
            FileHandle.standardError.write(Data("ownership skipped: \(error)\n".utf8))
        }

        return IndexResult(
            repository: repoID, revision: finalRevision, snapshot: snapshot,
            filesAnalyzed: manifest.files.count,
            filesChanged: diff.changedOrAdded.count + diff.removed.count,
            filesRenamed: diff.renames.count,
            entityCount: changes.entities.count,
            relationshipCount: changes.relationships.count)
    }

    /// Reference enrichment: read the repo's compiled index store,
    /// record one `.reference` observation per cross-file reference,
    /// and assert derived file→file `core:references` edges with
    /// per-pair counts and provenance to those observations. Returns
    /// the committed revision, or nil when there was no store or
    /// nothing to change.
    private func enrichReferences(
        repoID: RepositoryID, root: URL, snapshot: SnapshotID,
        currentPaths: Set<String>,
        progress: (@Sendable (IndexProgress) -> Void)?) async throws -> RevisionID? {
        guard let storePath = IndexStoreReader.storePath(under: root) else { return nil }

        // Reading the store is the expensive half of an analysis on a
        // repository with a large Xcode index. Skip it when the store
        // has not been rebuilt and the snapshot has not moved —
        // nothing it could tell us has changed.
        let fingerprint = EnrichmentLedger.fingerprint(ofStoreAt: storePath)
        var ledger = EnrichmentLedger.load(in: directory)
        if let previous = ledger[repoID.raw],
           previous.storeFingerprint == fingerprint,
           previous.snapshotID == snapshot.raw {
            return nil
        }
        // Recorded before the work, not after: a store that makes the
        // reader crash or hang must not be retried on every analysis
        // for the rest of time.
        ledger[repoID.raw] = EnrichmentState(storeFingerprint: fingerprint,
                                             snapshotID: snapshot.raw)
        EnrichmentLedger.save(ledger, in: directory)

        progress?(IndexProgress(phase: "enrich", completed: 0, total: 1))
        let reader = try IndexStoreReader(
            storePath: storePath,
            databasePath: directory.appendingPathComponent("isdb-cache").path)
        // Index stores keep units for deleted files — an old build's
        // ghosts. Only references between files in the CURRENT
        // snapshot are evidence about it.
        let references = await reader.fileReferences(repoRoot: root).filter {
            currentPaths.contains($0.fromPath) && currentPaths.contains($0.toPath)
        }
        guard !references.isEmpty else { return nil }

        // One literal observation per reference occurrence.
        let observations = references.map { ref in
            Observation(
                kind: .reference,
                file: SourceAnchor(
                    path: ref.fromPath, blob: BlobHash(""),
                    range: SourceRange(startLine: ref.line, startColumn: ref.column,
                                       endLine: ref.line, endColumn: ref.column)),
                payload: [
                    "core:symbolUSR": .string(ref.symbolUSR),
                    "core:symbolName": .string(ref.symbolName),
                    "core:definedIn": .string(ref.toPath),
                    "core:isCall": .bool(ref.isCall),
                ],
                extractor: ExtractorIdentity(name: "indexstore-db", version: "0.1.0"))
        }
        let ids = try store.recordObservations(observations, snapshot: snapshot)

        // Aggregate per file pair; cap provenance per edge so a hot
        // pair (thousands of references) doesn't explode the table.
        // `calls` counts the subset the compiler marked as calls, so a
        // caller graph can be built from calls alone rather than from
        // every mention of the symbol.
        struct Pair { var count = 0; var calls = 0; var supportedBy: [ObservationID] = [] }
        var pairs: [String: Pair] = [:]
        var pairKeys: [String: (from: String, to: String)] = [:]
        for (index, ref) in references.enumerated() {
            let key = "\(ref.fromPath)→\(ref.toPath)"
            var pair = pairs[key] ?? Pair()
            pair.count += 1
            if pair.supportedBy.count < 200 { pair.supportedBy.append(ids[index]) }
            pairs[key] = pair
            pairKeys[key] = (ref.fromPath, ref.toPath)
        }

        // Symbol-level: map each reference's endpoints to the
        // innermost enclosing declaration (the caller/callee), and
        // aggregate decl→decl pairs. The file→file edge is the coarse
        // chart; this is the wiring the inspector walks.
        let locator = try DeclarationLocator.build(store: store, repository: repoID)
        var symbolPairs: [String: Pair] = [:]
        var symbolPairKeys: [String: (from: StableKey, to: StableKey)] = [:]
        for (index, ref) in references.enumerated() {
            guard let from = locator.enclosing(path: ref.fromPath, line: ref.line),
                  let to = locator.enclosing(path: ref.toPath, line: ref.defLine),
                  from != to
            else { continue }
            let key = "\(from.raw)→\(to.raw)"
            var pair = symbolPairs[key] ?? Pair()
            pair.count += 1
            if ref.isCall { pair.calls += 1 }
            if pair.supportedBy.count < 200 { pair.supportedBy.append(ids[index]) }
            symbolPairs[key] = pair
            symbolPairKeys[key] = (from, to)
        }

        var changes = RevisionChanges()
        var asserted = Set<String>()
        for (key, pair) in pairs.sorted(by: { $0.key < $1.key }) {
            guard let (from, to) = pairKeys[key] else { continue }
            changes.relationships.append(RelationshipAssertion(
                source: StableKeys.file(repoID, from),
                target: StableKeys.file(repoID, to),
                kind: .references, layer: .derived,
                properties: ["core:referenceCount": .int(Int64(pair.count))],
                supportedBy: pair.supportedBy))
            asserted.insert("\(key)#\(pair.count)")
        }
        var assertedSymbols = Set<String>()
        for (key, pair) in symbolPairs.sorted(by: { $0.key < $1.key }) {
            guard let (from, to) = symbolPairKeys[key] else { continue }
            changes.relationships.append(RelationshipAssertion(
                source: from, target: to, kind: .refersToSymbol, layer: .derived,
                properties: [
                    "core:referenceCount": .int(Int64(pair.count)),
                    "core:callCount": .int(Int64(pair.calls)),
                ],
                supportedBy: pair.supportedBy))
            assertedSymbols.insert("\(key)#\(pair.count)/\(pair.calls)")
        }

        // Retract stale reference edges (identity includes the count,
        // matching the rollup deriver's convention). `currentFile`
        // records what's already present so an unchanged re-run can
        // skip committing entirely (no revision bloat under the watch).
        var currentFile = Set<String>()
        for edge in try store.relationships(kind: .references, at: .current)
        where edge.layer == .derived {
            let endpoints = try store.entities(ids: [edge.source, edge.target], at: .current)
            guard let source = endpoints.first(where: { $0.entity.id == edge.source })?.entity,
                  let target = endpoints.first(where: { $0.entity.id == edge.target })?.entity,
                  source.repository == repoID
            else { continue }
            let count: Int64? = if case .int(let value)? = edge.properties["core:referenceCount"] {
                value
            } else { nil }
            let identity = "\(pathOf(source.stableKey, repo: repoID))→\(pathOf(target.stableKey, repo: repoID))#\(count.map(String.init) ?? "?")"
            currentFile.insert(identity)
            if !asserted.contains(identity) {
                changes.retractRelationships.append(edge.id)
            }
        }

        // Retract stale symbol edges by (source, target, count),
        // reading stable keys directly (both endpoints are decls in
        // this repo).
        var currentSymbol = Set<String>()
        for edge in try store.relationships(kind: .refersToSymbol, at: .current)
        where edge.layer == .derived {
            let endpoints = try store.entities(ids: [edge.source, edge.target], at: .current)
            guard let source = endpoints.first(where: { $0.entity.id == edge.source })?.entity,
                  let target = endpoints.first(where: { $0.entity.id == edge.target })?.entity,
                  source.repository == repoID
            else { continue }
            let count: Int64? = if case .int(let value)? = edge.properties["core:referenceCount"] {
                value
            } else { nil }
            // The call count participates in edge identity: an edge whose
            // reference count is unchanged but whose call count moved is a
            // different fact and must be retracted and re-asserted. Edges
            // written before callCount existed carry no value and read as
            // "?", so the first enrichment after this change retracts and
            // re-asserts every symbol edge exactly once — deliberate.
            let calls: Int64? = if case .int(let value)? = edge.properties["core:callCount"] {
                value
            } else { nil }
            let identity = "\(source.stableKey.raw)→\(target.stableKey.raw)#\(count.map(String.init) ?? "?")/\(calls.map(String.init) ?? "?")"
            currentSymbol.insert(identity)
            if !assertedSymbols.contains(identity) {
                changes.retractRelationships.append(edge.id)
            }
        }

        // Skip the commit when the graph already holds exactly these
        // edges — nothing to retract and nothing new — so a re-run over
        // an unchanged index mints no revision.
        let nothingNew = changes.retractRelationships.isEmpty
            && asserted.isSubset(of: currentFile)
            && assertedSymbols.isSubset(of: currentSymbol)
        guard !nothingNew else { return nil }
        return try store.commit(
            changes,
            note: "enrich: \(pairs.count) file + \(symbolPairs.count) symbol reference edges")
    }

    /// Strip a file stable key back to its repo-relative path.
    private func pathOf(_ key: StableKey, repo: RepositoryID) -> String {
        let prefix = "phys:file:\(repo.raw)/"
        return key.raw.hasPrefix(prefix) ? String(key.raw.dropFirst(prefix.count)) : key.raw
    }
}

public enum WorkspaceError: Error, Equatable {
    case unknownRepository(RepositoryID)
    /// The index run was aborted because the process crossed the hard
    /// memory limit. Nothing was committed; re-run after freeing
    /// memory (or raise CYGNUS_HARD_MEMORY_MB deliberately).
    case memoryLimitExceeded(usedBytes: UInt64, limitBytes: UInt64)
}

extension WorkspaceError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unknownRepository(let id):
            "unknown repository \(id.raw)"
        case .memoryLimitExceeded(let used, let limit):
            "index aborted: memory \(used / 1_048_576) MB exceeded the \(limit / 1_048_576) MB hard limit; nothing was committed"
        }
    }
}
