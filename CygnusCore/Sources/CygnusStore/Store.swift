import Foundation
import GRDB
import CygnusGraph

// GRDB-backed graph store. Interval-versioned, append-only schema —
// rows are never mutated except to close a valid_to interval, and a
// revision commit is one transaction. Full schema lands in E1
// (docs/schema.md); this file currently proves the storage seam.

public enum GraphDatabase {
    /// In-memory database for tests. Same code path as on-disk — GRDB
    /// treats `:memory:` as a normal database.
    public static func inMemory() throws -> DatabaseQueue {
        try DatabaseQueue()
    }

    /// On-disk workspace database (WAL mode).
    public static func onDisk(at url: URL) throws -> DatabasePool {
        try DatabasePool(path: url.path)
    }
}
