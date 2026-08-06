import Foundation
import GRDB
import CygnusGraph

// The only GRDB code the retrieval layer owns. Everything above this
// file speaks in plain Sendable values; the database never escapes.

/// One 60-line window of a blob, ready to index.
public struct SourceWindow: Hashable, Sendable {
    public let ordinal: Int
    public let startLine: Int
    public let body: String
    /// `body` with identifiers split at case/underscore boundaries.
    public let bodySplit: String

    public init(ordinal: Int, startLine: Int, body: String, bodySplit: String) {
        self.ordinal = ordinal
        self.startLine = startLine
        self.body = body
        self.bodySplit = bodySplit
    }
}

/// A lexical hit, before the path is resolved against a snapshot.
public struct SourceHit: Hashable, Sendable {
    public let blob: BlobHash
    public let ordinal: Int
    public let startLine: Int
    /// FTS5 bm25 — **lower is better**, and negative in practice.
    public let rank: Double

    public init(blob: BlobHash, ordinal: Int, startLine: Int, rank: Double) {
        self.blob = blob
        self.ordinal = ordinal
        self.startLine = startLine
        self.rank = rank
    }
}

/// A hit resolved to a repo-relative path in the current snapshot.
public struct ResolvedSourceHit: Hashable, Sendable {
    public let blob: BlobHash
    public let path: String
    public let repository: RepositoryID
    public let ordinal: Int
    public let startLine: Int
    public let rank: Double
}

public struct RetrievalIndexStore: Sendable {
    private let store: SQLiteGraphStore

    public init(store: SQLiteGraphStore) {
        self.store = store
    }

    // MARK: - Indexing

    /// Blobs already windowed. The set difference against a manifest's
    /// blobs *is* the incremental diff — nothing else is consulted.
    public func indexedBlobs() throws -> Set<BlobHash> {
        try store.readRetrieval { db in
            Set(try String.fetchAll(db, sql: "SELECT blob_hash FROM source_indexed_blob")
                .map(BlobHash.init))
        }
    }

    /// Window one blob. The ledger row and the windows land in one
    /// transaction, so a crash can never leave a blob marked indexed
    /// with nothing behind it.
    public func insertWindows(_ windows: [SourceWindow], blob: BlobHash, lines: Int) throws {
        try store.writeRetrieval { db in
            // Re-indexing the same blob is a no-op rather than a
            // duplicate: blobs are immutable, so existing rows are
            // already correct.
            guard try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM source_indexed_blob WHERE blob_hash = ?",
                arguments: [blob.raw]) == 0 else { return }

            for window in windows {
                try db.execute(sql: """
                    INSERT INTO source_search (body, body_split, blob_hash, ordinal, start_line)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [window.body, window.bodySplit, blob.raw,
                                     window.ordinal, window.startLine])
            }
            try db.execute(sql: """
                INSERT INTO source_indexed_blob (blob_hash, lines, windows) VALUES (?, ?, ?)
                """, arguments: [blob.raw, lines, windows.count])
        }
    }

    // MARK: - Search

    /// BM25-ranked windows matching `query`, restricted to blobs present
    /// in the newest committed snapshot of each repository.
    ///
    /// The snapshot join is the invalidation mechanism: a blob that has
    /// left the working tree cannot surface even before its rows are
    /// collected, so staleness is impossible by construction rather
    /// than corrected after the fact.
    public func searchSource(matching ftsQuery: String,
                             repository: RepositoryID? = nil,
                             pathPrefix: String? = nil,
                             limit: Int) throws -> [ResolvedSourceHit] {
        guard !ftsQuery.isEmpty else { return [] }
        var sql = """
            SELECT s.blob_hash AS blob, s.ordinal AS ordinal, s.start_line AS start_line,
                   bm25(source_search, 1.0, 0.4) AS rank,
                   f.path AS path, snap.repository_id AS repo
            FROM source_search s
            JOIN snapshot_files f ON f.blob_hash = s.blob_hash
            JOIN snapshots snap ON snap.id = f.snapshot_id
            JOIN (
                SELECT repository_id, MAX(snapshot_id) AS snapshot_id
                FROM snapshots
                JOIN revisions ON revisions.snapshot_id = snapshots.id
                GROUP BY repository_id
            ) current ON current.snapshot_id = f.snapshot_id
            WHERE source_search MATCH ?
            """
        var arguments: [DatabaseValueConvertible] = [ftsQuery]
        if let repository {
            sql += " AND snap.repository_id = ?"
            arguments.append(repository.raw)
        }
        if let pathPrefix, !pathPrefix.isEmpty {
            sql += " AND f.path LIKE ? ESCAPE '\\'"
            arguments.append(Self.likePrefix(pathPrefix))
        }
        sql += " ORDER BY rank LIMIT ?"
        arguments.append(limit)

        return try store.readRetrieval { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map { row in
                ResolvedSourceHit(
                    blob: BlobHash(row["blob"]),
                    path: row["path"],
                    repository: RepositoryID(row["repo"]),
                    ordinal: row["ordinal"],
                    startLine: row["start_line"],
                    rank: row["rank"])
            }
        }
    }

    // MARK: - Chunks and vectors

    public struct ChunkRow: Hashable, Sendable {
        public let id: Int64
        public let blob: BlobHash
        public let ordinal: Int
        public let startLine: Int
        public let endLine: Int
        public let declKey: String?
        public let declName: String?
        public let context: String

        public init(id: Int64, blob: BlobHash, ordinal: Int, startLine: Int, endLine: Int,
                    declKey: String?, declName: String?, context: String) {
            self.id = id; self.blob = blob; self.ordinal = ordinal
            self.startLine = startLine; self.endLine = endLine
            self.declKey = declKey; self.declName = declName; self.context = context
        }
    }

    public struct ChunkDraft: Sendable {
        public let ordinal: Int
        public let startLine: Int
        public let endLine: Int
        public let declKey: String?
        public let declName: String?
        public let context: String

        public init(ordinal: Int, startLine: Int, endLine: Int,
                    declKey: String?, declName: String?, context: String) {
            self.ordinal = ordinal; self.startLine = startLine; self.endLine = endLine
            self.declKey = declKey; self.declName = declName; self.context = context
        }
    }

    public func chunkedBlobs() throws -> Set<BlobHash> {
        try store.readRetrieval { db in
            Set(try String.fetchAll(db, sql: "SELECT DISTINCT blob_hash FROM retrieval_chunk")
                .map(BlobHash.init))
        }
    }

    /// Insert a blob's chunks. Idempotent by `(blob, ordinal)`: blobs
    /// are immutable, so existing rows are already correct.
    public func insertChunks(_ drafts: [ChunkDraft], blob: BlobHash) throws {
        try store.writeRetrieval { db in
            for draft in drafts {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO retrieval_chunk
                        (blob_hash, ordinal, start_line, end_line, decl_key, decl_name, context)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [blob.raw, draft.ordinal, draft.startLine, draft.endLine,
                                     draft.declKey, draft.declName, draft.context])
            }
        }
    }

    /// Chunks with no vector for this model — the embedding work list.
    public func chunksMissingVectors(model: String, limit: Int) throws -> [ChunkRow] {
        try store.readRetrieval { db in
            try Row.fetchAll(db, sql: """
                SELECT c.* FROM retrieval_chunk c
                LEFT JOIN retrieval_vector v ON v.chunk_id = c.id AND v.model = ?
                WHERE v.chunk_id IS NULL
                ORDER BY c.id LIMIT ?
                """, arguments: [model, limit]).map(Self.chunkRow)
        }
    }

    public func insertVectors(_ vectors: [(chunkID: Int64, data: Data)],
                              model: String, dimension: Int) throws {
        try store.writeRetrieval { db in
            for vector in vectors {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO retrieval_vector (chunk_id, model, dim, vector)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [vector.chunkID, model, dimension, vector.data])
            }
        }
    }

    /// Every vector for a model, with the chunk rows beside them and
    /// restricted to blobs in a current snapshot — so a chunk whose
    /// file left the tree cannot surface, exactly as in lexical search.
    public func vectorMatrix(model: String, repository: RepositoryID? = nil) throws
        -> (chunks: [ChunkRow], vectors: [Data]) {
        var sql = """
            SELECT c.*, v.vector AS vec
            FROM retrieval_vector v
            JOIN retrieval_chunk c ON c.id = v.chunk_id
            JOIN snapshot_files f ON f.blob_hash = c.blob_hash
            JOIN snapshots s ON s.id = f.snapshot_id
            JOIN (
                SELECT repository_id, MAX(snapshot_id) AS snapshot_id
                FROM snapshots JOIN revisions ON revisions.snapshot_id = snapshots.id
                GROUP BY repository_id
            ) current ON current.snapshot_id = f.snapshot_id
            WHERE v.model = ?
            """
        var arguments: [DatabaseValueConvertible] = [model]
        if let repository {
            sql += " AND s.repository_id = ?"
            arguments.append(repository.raw)
        }
        sql += " GROUP BY c.id ORDER BY c.id"

        return try store.readRetrieval { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            return (rows.map(Self.chunkRow), rows.map { $0["vec"] as Data })
        }
    }

    /// Paths a chunk's blob currently occupies, for citations.
    public func paths(forBlob blob: BlobHash) throws -> [(path: String, repository: RepositoryID)] {
        try store.readRetrieval { db in
            try Row.fetchAll(db, sql: """
                SELECT DISTINCT f.path AS path, s.repository_id AS repo
                FROM snapshot_files f JOIN snapshots s ON s.id = f.snapshot_id
                WHERE f.blob_hash = ? ORDER BY f.path
                """, arguments: [blob.raw])
                .map { ($0["path"], RepositoryID($0["repo"])) }
        }
    }

    public func vectorCount(model: String) throws -> Int {
        try store.readRetrieval { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM retrieval_vector WHERE model = ?",
                             arguments: [model]) ?? 0
        }
    }

    public func chunkCount() throws -> Int {
        try store.readRetrieval { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM retrieval_chunk") ?? 0
        }
    }

    private static func chunkRow(_ row: Row) -> ChunkRow {
        ChunkRow(id: row["id"], blob: BlobHash(row["blob_hash"]), ordinal: row["ordinal"],
                 startLine: row["start_line"], endLine: row["end_line"],
                 declKey: row["decl_key"], declName: row["decl_name"],
                 context: row["context"])
    }

    // MARK: - Housekeeping

    /// Drop windows for blobs no longer in any current snapshot.
    /// Purely a space reclaim — orphans are already unreachable through
    /// `searchSource`, so this never changes a result.
    @discardableResult
    public func pruneOrphanBlobs() throws -> Int {
        try store.writeRetrieval { db in
            let orphans = try String.fetchAll(db, sql: """
                SELECT blob_hash FROM source_indexed_blob
                WHERE blob_hash NOT IN (SELECT blob_hash FROM snapshot_files)
                """)
            guard !orphans.isEmpty else { return 0 }
            let marks = Array(repeating: "?", count: orphans.count).joined(separator: ",")
            let arguments = StatementArguments(orphans)
            try db.execute(
                sql: "DELETE FROM source_search WHERE blob_hash IN (\(marks))",
                arguments: arguments)
            try db.execute(
                sql: "DELETE FROM source_indexed_blob WHERE blob_hash IN (\(marks))",
                arguments: arguments)
            return orphans.count
        }
    }

    public func indexedBlobCount() throws -> Int {
        try store.readRetrieval { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source_indexed_blob") ?? 0
        }
    }

    /// `LIKE` prefix match with the wildcards in the caller's string
    /// escaped, so a path containing `_` (very common) is not a
    /// single-character wildcard.
    static func likePrefix(_ prefix: String) -> String {
        let escaped = prefix
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return escaped + "%"
    }
}
