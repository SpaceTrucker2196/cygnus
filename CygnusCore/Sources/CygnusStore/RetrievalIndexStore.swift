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
