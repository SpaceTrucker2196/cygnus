import Foundation
import GRDB

// E0 spike: prototype of the interval-versioned schema, exercised by
// `cygnus bench`. The real schema (full tables + migrations) replaces
// this in E1; the shape being validated here — append-only rows with
// [valid_from, valid_to) revision intervals and partial indexes on
// the valid_to IS NULL hot path — is the load-bearing decision.

public enum SchemaPrototype {
    public static func create(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE entities (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                stable_key TEXT NOT NULL UNIQUE,
                kind TEXT NOT NULL,
                first_seen_rev INTEGER NOT NULL
            );
            CREATE TABLE relationships (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind TEXT NOT NULL,
                source_id INTEGER NOT NULL REFERENCES entities(id),
                target_id INTEGER NOT NULL REFERENCES entities(id),
                layer TEXT NOT NULL,
                valid_from INTEGER NOT NULL,
                valid_to INTEGER,
                properties TEXT
            );
            CREATE INDEX idx_rel_source_current
                ON relationships(source_id, kind) WHERE valid_to IS NULL;
            CREATE INDEX idx_rel_target_current
                ON relationships(target_id, kind) WHERE valid_to IS NULL;
            CREATE INDEX idx_rel_interval
                ON relationships(source_id, valid_from, valid_to);
            """)
    }
}
