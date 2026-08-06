import Foundation
import GRDB

// Retrieval index tables.
//
// These are a rebuildable *index over* the graph, not facts about it —
// the same category `entity_search` already occupies, and the reason
// they may be INSERTed and DELETEd freely while the fact tables stay
// append-only. Nothing here stores source text as a durable claim: a
// row holds a blob hash and a line range, and the text is a copy the
// CAS can reproduce byte for byte. The moment one of these tables
// becomes the only place something is known, cygnus has grown the
// second representation MISSION §7 forbids.
//
// Everything is keyed by **blob hash, never by path**. That is what
// makes the incremental story free: an unchanged file re-indexes
// nothing, a renamed file re-indexes nothing (same blob, new path row
// in snapshot_files), a reverted file re-indexes nothing, and the same
// vendored file in two repositories is indexed once between them.
// Paths enter at query time through the snapshot_files join, which is
// also what keeps results from outliving the snapshot that justified
// them.

enum RetrievalSchema {
    static func register(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3-retrieval") { db in
            try db.execute(sql: """
                -- Source text, windowed. `body` is verbatim; `body_split`
                -- is the same text with identifiers broken at case and
                -- underscore boundaries, because unicode61 makes
                -- `withThrowingTaskGroup` a single token and a search for
                -- "task group" would otherwise match nothing at all.
                -- tokenchars keeps _ and $ inside identifiers so `foo_bar`
                -- and `$state` stay whole in `body`.
                CREATE VIRTUAL TABLE source_search USING fts5(
                    body,
                    body_split,
                    blob_hash UNINDEXED,
                    ordinal UNINDEXED,
                    start_line UNINDEXED,
                    tokenize = 'unicode61 tokenchars ''_$'''
                );

                -- Which blobs have been windowed. Written in the SAME
                -- transaction as the windows themselves: a crash between
                -- the two would otherwise mark a blob indexed with no
                -- rows behind it, and nothing would ever re-index it.
                CREATE TABLE source_indexed_blob (
                    blob_hash TEXT PRIMARY KEY,
                    lines INTEGER NOT NULL,
                    windows INTEGER NOT NULL
                ) WITHOUT ROWID;

                -- snapshot_files is WITHOUT ROWID keyed (snapshot_id,
                -- path), so every retrieval join — orphan filtering,
                -- path resolution, the indexed-blob set difference —
                -- scans it end to end without this.
                CREATE INDEX idx_snapshot_files_blob
                    ON snapshot_files(blob_hash);
                """)
        }

        migrator.registerMigration("v4-semantic") { db in
            try db.execute(sql: """
                -- A chunk is a pointer, not a copy: blob hash, line
                -- range, and the generated prefix. The text lives in
                -- the CAS and nowhere else.
                --
                -- No revision column, deliberately. Keyed by (blob,
                -- ordinal), a chunk is a pure function of content, so
                -- unchanged files never re-chunk and never re-embed.
                CREATE TABLE retrieval_chunk (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    blob_hash TEXT NOT NULL,
                    ordinal INTEGER NOT NULL,
                    start_line INTEGER NOT NULL,
                    end_line INTEGER NOT NULL,
                    decl_key TEXT,
                    decl_name TEXT,
                    context TEXT NOT NULL,
                    UNIQUE(blob_hash, ordinal)
                );
                CREATE INDEX idx_chunk_blob ON retrieval_chunk(blob_hash);

                -- Vectors are Float32 little-endian, pre-L2-normalized
                -- so cosine collapses to a dot product. `model` is part
                -- of the key because vectors from different models are
                -- not comparable — a model change makes queries return
                -- nothing rather than silently mixing embedding spaces.
                CREATE TABLE retrieval_vector (
                    chunk_id INTEGER NOT NULL REFERENCES retrieval_chunk(id),
                    model TEXT NOT NULL,
                    dim INTEGER NOT NULL,
                    vector BLOB NOT NULL,
                    PRIMARY KEY (chunk_id, model)
                ) WITHOUT ROWID;
                CREATE INDEX idx_vector_model ON retrieval_vector(model);
                """)
        }
    }
}
