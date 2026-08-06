import Foundation
import GRDB
import CygnusGraph

// GraphStore implementation over GRDB. Append-only: the only UPDATEs
// in this file close valid_to intervals; commit() is one transaction.

public final class SQLiteGraphStore: GraphStore, Sendable {
    private let db: any DatabaseWriter

    public static func inMemory() throws -> SQLiteGraphStore {
        try SQLiteGraphStore(db: DatabaseQueue())
    }

    public static func onDisk(at url: URL) throws -> SQLiteGraphStore {
        // DatabaseQueue, not DatabasePool: every access runs on one
        // serialized connection, so there is no reader-thread pool.
        // The recurring app crash was an EXC_BAD_ACCESS on a
        // `GRDB.DatabasePool.reader` thread that only ever reproduced
        // in the GUI's interleaved access pattern (never headless,
        // never in tests — tests use the in-memory DatabaseQueue and
        // have never crashed). Serializing on a queue removes the
        // pooled readers entirely; concurrent reads aren't needed here
        // (analysis is effectively one-at-a-time). See issue #2.
        try SQLiteGraphStore(db: DatabaseQueue(path: url.path))
    }

    private init(db: any DatabaseWriter) throws {
        self.db = db
        try Schema.migrator().migrate(db)
    }

    // Retrieval-index access. The index tables live in this database so
    // they stay transactionally aligned with the graph they point at,
    // but they are not graph facts, so they get their own seam rather
    // than widening `db` to the whole module. `RetrievalIndexStore` is
    // the only caller.
    func readRetrieval<T>(_ body: (Database) throws -> T) throws -> T {
        try db.read(body)
    }

    func writeRetrieval<T>(_ body: (Database) throws -> T) throws -> T {
        try db.write(body)
    }

    // MARK: - Repositories & snapshots

    public struct RegisteredRepository: Hashable, Codable, Sendable {
        public let id: RepositoryID
        public let displayName: String
        public let rootPath: String?
    }

    public func registerRepository(_ id: RepositoryID, displayName: String,
                                   rootPath: String? = nil) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO repositories (id, display_name, root_path) VALUES (?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET display_name = excluded.display_name,
                                                  root_path = excluded.root_path
                    """,
                arguments: [id.raw, displayName, rootPath])
        }
    }

    public func repositories() throws -> [RegisteredRepository] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, display_name, root_path FROM repositories ORDER BY id")
                .map {
                    RegisteredRepository(id: RepositoryID($0["id"]),
                                         displayName: $0["display_name"],
                                         rootPath: $0["root_path"])
                }
        }
    }

    public func recordSnapshot(repository: RepositoryID, sourceRef: String?,
                               files: [SnapshotFileRecord] = []) throws -> SnapshotID {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO snapshots (repository_id, source_ref, created_at) VALUES (?, ?, ?)",
                arguments: [repository.raw, sourceRef, iso8601Now()])
            let snapshotID = db.lastInsertedRowID
            if !files.isEmpty {
                let stmt = try db.makeStatement(sql: """
                    INSERT INTO snapshot_files (snapshot_id, path, blob_hash, size, lang_hint)
                    VALUES (?, ?, ?, ?, ?)
                    """)
                for file in files {
                    try stmt.execute(arguments: [
                        snapshotID, file.path, file.blobHash, file.size, file.languageHint,
                    ])
                }
            }
            return SnapshotID(snapshotID)
        }
    }

    public struct SnapshotFileRecord: Hashable, Codable, Sendable {
        public let path: String
        public let blobHash: String
        public let size: Int64
        public let languageHint: String?
        public init(path: String, blobHash: String, size: Int64, languageHint: String?) {
            self.path = path
            self.blobHash = blobHash
            self.size = size
            self.languageHint = languageHint
        }
    }

    /// Latest snapshot of a repository that a committed revision
    /// references, with its file manifest. Snapshots recorded by runs
    /// that failed before commit are never a diff baseline.
    public func latestIndexedSnapshot(repository: RepositoryID) throws -> (SnapshotID, [SnapshotFileRecord])? {
        try db.read { db in
            guard let snapshotID = try Int64.fetchOne(db, sql: """
                SELECT s.id FROM snapshots s
                JOIN revisions r ON r.snapshot_id = s.id
                WHERE s.repository_id = ? ORDER BY s.id DESC LIMIT 1
                """, arguments: [repository.raw])
            else { return nil }
            let files = try Row.fetchAll(db, sql: """
                SELECT path, blob_hash, size, lang_hint FROM snapshot_files
                WHERE snapshot_id = ? ORDER BY path
                """, arguments: [snapshotID]).map {
                    SnapshotFileRecord(path: $0["path"], blobHash: $0["blob_hash"],
                                       size: $0["size"], languageHint: $0["lang_hint"])
                }
            return (SnapshotID(snapshotID), files)
        }
    }

    public func recordObservations(_ observations: [Observation],
                                   snapshot: SnapshotID) throws -> [ObservationID] {
        try db.write { db in
            let stmt = try db.makeStatement(sql: """
                INSERT INTO observations
                    (kind, snapshot_id, path, blob_hash, range, payload, extractor, extractor_version)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """)
            var ids: [ObservationID] = []
            ids.reserveCapacity(observations.count)
            for obs in observations {
                try stmt.execute(arguments: [
                    obs.kind.rawValue, snapshot.raw, obs.file.path, obs.file.blob.raw,
                    obs.file.range.map { try? CanonicalJSON.encode($0) } ?? nil,
                    try CanonicalJSON.encode(obs.payload),
                    obs.extractor.name, obs.extractor.version,
                ])
                ids.append(ObservationID(db.lastInsertedRowID))
            }
            return ids
        }
    }

    // MARK: - Revisions

    public func currentRevision() throws -> RevisionID? {
        try db.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM revisions").map(RevisionID.init)
        }
    }

    public func revisions() throws -> [RevisionInfo] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, note, created_at FROM revisions ORDER BY id").map {
                RevisionInfo(id: RevisionID($0["id"]),
                             note: $0["note"],
                             createdAt: parseISO8601($0["created_at"]) ?? .distantPast)
            }
        }
    }

    public func commit(_ changes: RevisionChanges, note: String?) throws -> RevisionID {
        try commit(changes, note: note, snapshot: nil)
    }

    @discardableResult
    public func commit(_ changes: RevisionChanges, note: String? = nil,
                       snapshot: SnapshotID? = nil) throws -> RevisionID {
        try db.write { db in
            try db.execute(sql: "INSERT INTO revisions (note, created_at, snapshot_id) VALUES (?, ?, ?)",
                           arguments: [note, iso8601Now(), snapshot?.raw])
            let rev = db.lastInsertedRowID

            for assertion in changes.entities {
                try apply(assertion, at: rev, db)
            }
            for key in changes.retractEntities {
                try retractEntity(key, at: rev, db)
            }
            for assertion in changes.relationships {
                try apply(assertion, at: rev, db)
            }
            for relID in changes.retractRelationships {
                try db.execute(literal: """
                    UPDATE relationships SET valid_to = \(rev)
                    WHERE id = \(relID) AND valid_to IS NULL
                    """)
                if db.changesCount == 0 {
                    throw GraphStoreError.unknownRelationship(relID)
                }
            }
            return RevisionID(rev)
        }
    }

    private func apply(_ assertion: EntityAssertion, at rev: Int64, _ db: Database) throws {
        let props = try CanonicalJSON.encode(assertion.properties)
        let anchors = try CanonicalJSON.encode(assertion.anchors)

        var entityID = try Int64.fetchOne(
            db, sql: "SELECT id FROM entities WHERE stable_key = ?",
            arguments: [assertion.stableKey.raw])

        if entityID == nil {
            try db.execute(
                sql: "INSERT INTO entities (stable_key, kind, repository_id, first_seen_rev) VALUES (?, ?, ?, ?)",
                arguments: [assertion.stableKey.raw, assertion.kind.rawValue,
                            assertion.repository?.raw, rev])
            entityID = db.lastInsertedRowID
        }
        guard let entityID else { return }

        let current = try Row.fetchOne(db, sql: """
            SELECT id, name, properties, anchors FROM entity_versions
            WHERE entity_id = ? AND valid_to IS NULL
            """, arguments: [entityID])

        let versionID: Int64
        if let current,
           current["name"] == assertion.name,
           current["properties"] == props,
           current["anchors"] == anchors {
            versionID = current["id"]        // unchanged — no new row
        } else {
            if let current {
                try db.execute(literal: """
                    UPDATE entity_versions SET valid_to = \(rev)
                    WHERE id = \(current["id"] as Int64)
                    """)
                try db.execute(sql: "DELETE FROM entity_search WHERE version_id = ?",
                               arguments: [current["id"] as Int64])
            }
            try db.execute(
                sql: "INSERT INTO entity_versions (entity_id, valid_from, valid_to, name, properties, anchors) VALUES (?, ?, NULL, ?, ?, ?)",
                arguments: [entityID, rev, assertion.name, props, anchors])
            versionID = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO entity_search (name, version_id) VALUES (?, ?)",
                           arguments: [assertion.name, versionID])
            for path in Set(assertion.anchors.map(\.path)) {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO entity_version_paths (path, version_id) VALUES (?, ?)",
                    arguments: [path, versionID])
            }
        }

        try link(observations: assertion.supportedBy, factKind: "entity_version",
                 factID: versionID, db)
    }

    private func retractEntity(_ key: StableKey, at rev: Int64, _ db: Database) throws {
        guard let entityID = try Int64.fetchOne(
            db, sql: "SELECT id FROM entities WHERE stable_key = ?", arguments: [key.raw])
        else { throw GraphStoreError.unknownEntity(key) }

        if let versionID = try Int64.fetchOne(db, sql: """
            SELECT id FROM entity_versions WHERE entity_id = ? AND valid_to IS NULL
            """, arguments: [entityID]) {
            try db.execute(literal: """
                UPDATE entity_versions SET valid_to = \(rev) WHERE id = \(versionID)
                """)
            try db.execute(sql: "DELETE FROM entity_search WHERE version_id = ?",
                           arguments: [versionID])
        }
        // A relationship must connect valid entities (MISSION.md §2.2):
        // retracting an entity closes its current edges with it.
        try db.execute(literal: """
            UPDATE relationships SET valid_to = \(rev)
            WHERE (source_id = \(entityID) OR target_id = \(entityID)) AND valid_to IS NULL
            """)
    }

    /// Stable keys of entities whose current version is anchored in
    /// the given path. Incremental indexing retracts vanished ones.
    public func currentEntityKeys(anchoredIn path: String) throws -> [StableKey] {
        try db.read { db in
            try String.fetchAll(db, sql: """
                SELECT e.stable_key
                FROM entity_version_paths p
                JOIN entity_versions v ON v.id = p.version_id AND v.valid_to IS NULL
                JOIN entities e ON e.id = v.entity_id
                WHERE p.path = ?
                ORDER BY e.stable_key
                """, arguments: [path]).map(StableKey.init)
        }
    }

    private func apply(_ assertion: RelationshipAssertion, at rev: Int64, _ db: Database) throws {
        guard let sourceID = try Int64.fetchOne(
            db, sql: "SELECT id FROM entities WHERE stable_key = ?",
            arguments: [assertion.source.raw])
        else { throw GraphStoreError.unknownEntity(assertion.source) }
        guard let targetID = try Int64.fetchOne(
            db, sql: "SELECT id FROM entities WHERE stable_key = ?",
            arguments: [assertion.target.raw])
        else { throw GraphStoreError.unknownEntity(assertion.target) }

        let props = try CanonicalJSON.encode(assertion.properties)

        let relID: Int64
        if let existing = try Int64.fetchOne(db, sql: """
            SELECT id FROM relationships
            WHERE source_id = ? AND target_id = ? AND kind = ? AND layer = ?
              AND properties = ? AND valid_to IS NULL
            """, arguments: [sourceID, targetID, assertion.kind.rawValue,
                             assertion.layer.rawValue, props]) {
            relID = existing                 // dedupe — no new row
        } else {
            try db.execute(
                sql: "INSERT INTO relationships (kind, source_id, target_id, layer, valid_from, valid_to, properties) VALUES (?, ?, ?, ?, ?, NULL, ?)",
                arguments: [assertion.kind.rawValue, sourceID, targetID,
                            assertion.layer.rawValue, rev, props])
            relID = db.lastInsertedRowID
        }

        try link(observations: assertion.supportedBy, factKind: "relationship",
                 factID: relID, db)
    }

    private func link(observations: [ObservationID], factKind: String,
                      factID: Int64, _ db: Database) throws {
        guard !observations.isEmpty else { return }
        let stmt = try db.makeStatement(sql: """
            INSERT OR IGNORE INTO provenance (fact_kind, fact_id, observation_id)
            VALUES (?, ?, ?)
            """)
        for obs in observations {
            try stmt.execute(arguments: [factKind, factID, obs.raw])
        }
    }

    // MARK: - Reads

    public func entity(stableKey: StableKey, at query: RevisionQuery) throws -> ResolvedEntity? {
        try db.read { db in
            try Row.fetchOne(db, sql: """
                SELECT e.id AS eid, e.stable_key, e.kind, e.repository_id, e.first_seen_rev,
                       v.id AS vid, v.valid_from, v.valid_to, v.name, v.properties, v.anchors
                FROM entities e JOIN entity_versions v ON v.entity_id = e.id
                WHERE e.stable_key = ? AND \(Self.intervalPredicate(query, alias: "v"))
                """, arguments: [stableKey.raw]).map(Self.resolvedEntity)
        }
    }

    public func entities(kind: EntityKind, at query: RevisionQuery) throws -> [ResolvedEntity] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.id AS eid, e.stable_key, e.kind, e.repository_id, e.first_seen_rev,
                       v.id AS vid, v.valid_from, v.valid_to, v.name, v.properties, v.anchors
                FROM entities e JOIN entity_versions v ON v.entity_id = e.id
                WHERE e.kind = ? AND \(Self.intervalPredicate(query, alias: "v"))
                ORDER BY e.stable_key
                """, arguments: [kind.rawValue]).map(Self.resolvedEntity)
        }
    }

    public func relationships(from source: StableKey, kind: RelationshipKind?,
                              at query: RevisionQuery) throws -> [Relationship] {
        try fetchRelationships(endpoint: "source_id", key: source, kind: kind, at: query)
    }

    public func relationships(to target: StableKey, kind: RelationshipKind?,
                              at query: RevisionQuery) throws -> [Relationship] {
        try fetchRelationships(endpoint: "target_id", key: target, kind: kind, at: query)
    }

    private func fetchRelationships(endpoint: String, key: StableKey,
                                    kind: RelationshipKind?,
                                    at query: RevisionQuery) throws -> [Relationship] {
        try db.read { db in
            guard let entityID = try Int64.fetchOne(
                db, sql: "SELECT id FROM entities WHERE stable_key = ?", arguments: [key.raw])
            else { return [] }

            var sql = """
                SELECT id, kind, source_id, target_id, layer, valid_from, valid_to, properties
                FROM relationships
                WHERE \(endpoint) = ? AND \(Self.intervalPredicate(query, alias: "relationships"))
                """
            var arguments: StatementArguments = [entityID]
            if let kind {
                sql += " AND kind = ?"
                _ = arguments.append(contentsOf: [kind.rawValue])
            }
            sql += " ORDER BY id"
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map(Self.relationship)
        }
    }

    /// All relationships of a kind — projection builders consume this.
    public func relationships(kind: RelationshipKind,
                              at query: RevisionQuery) throws -> [Relationship] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, kind, source_id, target_id, layer, valid_from, valid_to, properties
                FROM relationships
                WHERE kind = ? AND \(Self.intervalPredicate(query, alias: "relationships"))
                ORDER BY id
                """, arguments: [kind.rawValue]).map(Self.relationship)
        }
    }

    /// Batch entity fetch by store id.
    public func entities(ids: [EntityID], at query: RevisionQuery) throws -> [ResolvedEntity] {
        guard !ids.isEmpty else { return [] }
        return try db.read { db in
            let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
            return try Row.fetchAll(db, sql: """
                SELECT e.id AS eid, e.stable_key, e.kind, e.repository_id, e.first_seen_rev,
                       v.id AS vid, v.valid_from, v.valid_to, v.name, v.properties, v.anchors
                FROM entities e JOIN entity_versions v ON v.entity_id = e.id
                WHERE e.id IN (\(marks)) AND \(Self.intervalPredicate(query, alias: "v"))
                """, arguments: StatementArguments(ids.map(\.raw))).map(Self.resolvedEntity)
        }
    }

    public func searchNames(_ text: String, limit: Int) throws -> [ResolvedEntity] {
        // FTS prefix match over current entity names.
        let match = text
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
            .joined(separator: " ")
        guard !match.isEmpty else { return [] }
        return try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.id AS eid, e.stable_key, e.kind, e.repository_id, e.first_seen_rev,
                       v.id AS vid, v.valid_from, v.valid_to, v.name, v.properties, v.anchors
                FROM entity_search s
                JOIN entity_versions v ON v.id = s.version_id
                JOIN entities e ON e.id = v.entity_id
                WHERE entity_search MATCH ? AND v.valid_to IS NULL
                ORDER BY rank LIMIT ?
                """, arguments: [match, limit]).map(Self.resolvedEntity)
        }
    }

    // MARK: - Revision diff

    public struct GraphDelta: Sendable {
        public let assertedEntityVersions: [ResolvedEntity]
        public let retractedEntityVersions: [ResolvedEntity]
        public let assertedRelationships: [Relationship]
        public let retractedRelationships: [Relationship]
        public var isEmpty: Bool {
            assertedEntityVersions.isEmpty && retractedEntityVersions.isEmpty
                && assertedRelationships.isEmpty && retractedRelationships.isEmpty
        }
    }

    /// What changed between two revisions: facts asserted in
    /// (from, to] and facts retracted in (from, to]. Cheap by
    /// construction — the interval columns are the change log.
    public func diff(from: RevisionID, to: RevisionID) throws -> GraphDelta {
        try db.read { db in
            func versions(_ predicate: String) throws -> [ResolvedEntity] {
                try Row.fetchAll(db, sql: """
                    SELECT e.id AS eid, e.stable_key, e.kind, e.repository_id, e.first_seen_rev,
                           v.id AS vid, v.valid_from, v.valid_to, v.name, v.properties, v.anchors
                    FROM entities e JOIN entity_versions v ON v.entity_id = e.id
                    WHERE \(predicate) ORDER BY e.stable_key
                    """, arguments: [from.raw, to.raw]).map(Self.resolvedEntity)
            }
            func relationships(_ predicate: String) throws -> [Relationship] {
                try Row.fetchAll(db, sql: """
                    SELECT id, kind, source_id, target_id, layer, valid_from, valid_to, properties
                    FROM relationships WHERE \(predicate) ORDER BY id
                    """, arguments: [from.raw, to.raw]).map(Self.relationship)
            }
            return GraphDelta(
                assertedEntityVersions: try versions("v.valid_from > ? AND v.valid_from <= ?"),
                retractedEntityVersions: try versions("v.valid_to > ? AND v.valid_to <= ?"),
                assertedRelationships: try relationships("valid_from > ? AND valid_from <= ?"),
                retractedRelationships: try relationships("valid_to > ? AND valid_to <= ?"))
        }
    }

    public func provenance(ofRelationship id: Int64) throws -> [ObservationID] {
        try provenance(factKind: "relationship", factID: id)
    }

    public func provenance(ofEntityVersion id: Int64) throws -> [ObservationID] {
        try provenance(factKind: "entity_version", factID: id)
    }

    private func provenance(factKind: String, factID: Int64) throws -> [ObservationID] {
        try db.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT observation_id FROM provenance
                WHERE fact_kind = ? AND fact_id = ? ORDER BY observation_id
                """, arguments: [factKind, factID]).map(ObservationID.init)
        }
    }

    // MARK: - Row mapping

    private static func intervalPredicate(_ query: RevisionQuery, alias: String) -> String {
        switch query {
        case .current:
            "\(alias).valid_to IS NULL"
        case .asOf(let rev):
            "\(alias).valid_from <= \(rev.raw) AND (\(alias).valid_to IS NULL OR \(alias).valid_to > \(rev.raw))"
        }
    }

    private static func resolvedEntity(_ row: Row) throws -> ResolvedEntity {
        ResolvedEntity(
            entity: Entity(
                id: EntityID(row["eid"]),
                stableKey: StableKey(row["stable_key"]),
                kind: EntityKind(row["kind"]),
                repository: (row["repository_id"] as String?).map(RepositoryID.init),
                firstSeen: RevisionID(row["first_seen_rev"])),
            version: EntityVersion(
                id: row["vid"],
                entity: EntityID(row["eid"]),
                validFrom: RevisionID(row["valid_from"]),
                validTo: (row["valid_to"] as Int64?).map(RevisionID.init),
                name: row["name"],
                properties: try CanonicalJSON.decode(PropertyBag.self, from: row["properties"]),
                anchors: try CanonicalJSON.decode([SourceAnchor].self, from: row["anchors"])))
    }

    private static func relationship(_ row: Row) throws -> Relationship {
        Relationship(
            id: row["id"],
            kind: RelationshipKind(row["kind"]),
            source: EntityID(row["source_id"]),
            target: EntityID(row["target_id"]),
            layer: KnowledgeLayer(rawValue: row["layer"]) ?? .observed,
            validFrom: RevisionID(row["valid_from"]),
            validTo: (row["valid_to"] as Int64?).map(RevisionID.init),
            properties: try CanonicalJSON.decode(PropertyBag.self, from: row["properties"]))
    }
}

private func iso8601Now() -> String {
    ISO8601DateFormatter().string(from: Date())
}

private func parseISO8601(_ text: String) -> Date? {
    ISO8601DateFormatter().date(from: text)
}
