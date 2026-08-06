import Foundation
import GRDB

// The interval-versioned schema, as GRDB migrations. Append-only
// discipline: no UPDATE anywhere except closing a valid_to interval;
// a revision commit is one transaction. Validated by the E0 benchmark
// (docs/schema.md).

enum Schema {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE repositories (
                    id TEXT PRIMARY KEY,
                    display_name TEXT NOT NULL
                );

                CREATE TABLE snapshots (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    repository_id TEXT NOT NULL REFERENCES repositories(id),
                    source_ref TEXT,
                    created_at TEXT NOT NULL
                );

                CREATE TABLE revisions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    note TEXT,
                    created_at TEXT NOT NULL
                );

                CREATE TABLE entities (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    stable_key TEXT NOT NULL UNIQUE,
                    kind TEXT NOT NULL,
                    repository_id TEXT,
                    first_seen_rev INTEGER NOT NULL REFERENCES revisions(id)
                );

                CREATE TABLE entity_versions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    entity_id INTEGER NOT NULL REFERENCES entities(id),
                    valid_from INTEGER NOT NULL,
                    valid_to INTEGER,
                    name TEXT NOT NULL,
                    properties TEXT NOT NULL,
                    anchors TEXT NOT NULL
                );
                CREATE INDEX idx_ev_current
                    ON entity_versions(entity_id) WHERE valid_to IS NULL;
                CREATE INDEX idx_ev_interval
                    ON entity_versions(entity_id, valid_from);

                CREATE TABLE relationships (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind TEXT NOT NULL,
                    source_id INTEGER NOT NULL REFERENCES entities(id),
                    target_id INTEGER NOT NULL REFERENCES entities(id),
                    layer TEXT NOT NULL,
                    valid_from INTEGER NOT NULL,
                    valid_to INTEGER,
                    properties TEXT NOT NULL
                );
                CREATE INDEX idx_rel_source_current
                    ON relationships(source_id, kind) WHERE valid_to IS NULL;
                CREATE INDEX idx_rel_target_current
                    ON relationships(target_id, kind) WHERE valid_to IS NULL;
                CREATE INDEX idx_rel_source_interval
                    ON relationships(source_id, valid_from);
                CREATE INDEX idx_rel_target_interval
                    ON relationships(target_id, valid_from);

                CREATE TABLE observations (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind TEXT NOT NULL,
                    snapshot_id INTEGER NOT NULL REFERENCES snapshots(id),
                    path TEXT NOT NULL,
                    blob_hash TEXT NOT NULL,
                    range TEXT,
                    payload TEXT NOT NULL,
                    extractor TEXT NOT NULL,
                    extractor_version TEXT NOT NULL
                );
                CREATE INDEX idx_obs_snapshot_path
                    ON observations(snapshot_id, path);

                CREATE TABLE provenance (
                    fact_kind TEXT NOT NULL,
                    fact_id INTEGER NOT NULL,
                    observation_id INTEGER NOT NULL REFERENCES observations(id),
                    PRIMARY KEY (fact_kind, fact_id, observation_id)
                ) WITHOUT ROWID;
                CREATE INDEX idx_prov_observation
                    ON provenance(observation_id);

                CREATE VIRTUAL TABLE entity_search USING fts5(
                    name,
                    version_id UNINDEXED,
                    tokenize = 'unicode61'
                );
                """)
        }

        migrator.registerMigration("v2-snapshot-files") { db in
            try db.execute(sql: """
                ALTER TABLE repositories ADD COLUMN root_path TEXT;

                -- Which snapshot a revision indexed. The incremental
                -- baseline is the latest snapshot referenced by a
                -- committed revision; snapshots orphaned by failed
                -- runs are never used as a diff baseline.
                ALTER TABLE revisions ADD COLUMN snapshot_id INTEGER REFERENCES snapshots(id);

                CREATE TABLE snapshot_files (
                    snapshot_id INTEGER NOT NULL REFERENCES snapshots(id),
                    path TEXT NOT NULL,
                    blob_hash TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    lang_hint TEXT,
                    PRIMARY KEY (snapshot_id, path)
                ) WITHOUT ROWID;

                -- Anchor-path index: which entity versions are anchored
                -- in which files. Drives incremental retraction scoping.
                CREATE TABLE entity_version_paths (
                    path TEXT NOT NULL,
                    version_id INTEGER NOT NULL REFERENCES entity_versions(id),
                    PRIMARY KEY (path, version_id)
                ) WITHOUT ROWID;
                """)
        }

        RetrievalSchema.register(&migrator)

        return migrator
    }
}
