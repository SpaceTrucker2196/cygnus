import Foundation
import GRDB

// E0 spike benchmark: 1M interval-versioned relationship rows on
// disk (WAL), then the viewer's hot queries. Results recorded in
// docs/schema.md. Deterministic seed so runs are comparable.
// Lives in CygnusStore because only this target imports GRDB; the
// CLI invokes it via `cygnus bench`.

public enum StoreBenchmark {
    static let entityCount = 50_000
    static let relationshipCount = 1_000_000
    static let revisions = 100

    public static func run() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-bench-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("bench.sqlite")
        let pool = try GraphDatabase.onDisk(at: dbURL)

        try pool.write { db in try SchemaPrototype.create(db) }

        var rng = SplitMix64(seed: 0xC516_0000)
        let clock = ContinuousClock()

        // Entities.
        let entityInsert = try clock.measure {
            try pool.write { db in
                let stmt = try db.makeStatement(sql: """
                    INSERT INTO entities (stable_key, kind, first_seen_rev) VALUES (?, ?, 1)
                    """)
                for i in 0..<entityCount {
                    try stmt.execute(arguments: ["swift:function:bench/M\(i % 500).f\(i)", "core:function"])
                }
            }
        }

        // Relationships: ~20% retracted (closed interval), rest current.
        // Batches of 100k per transaction.
        let relInsert = try clock.measure {
            var inserted = 0
            while inserted < relationshipCount {
                let batch = min(100_000, relationshipCount - inserted)
                try pool.write { db in
                    let stmt = try db.makeStatement(sql: """
                        INSERT INTO relationships
                            (kind, source_id, target_id, layer, valid_from, valid_to, properties)
                        VALUES (?, ?, ?, 'observed', ?, ?, NULL)
                        """)
                    for _ in 0..<batch {
                        let source = Int64(rng.next(upperBound: UInt64(entityCount)) + 1)
                        let target = Int64(rng.next(upperBound: UInt64(entityCount)) + 1)
                        let from = Int64(rng.next(upperBound: UInt64(revisions)) + 1)
                        let retracted = rng.next(upperBound: 5) == 0
                        let to: Int64? = retracted ? min(from + 1 + Int64(rng.next(upperBound: 20)), Int64(revisions)) : nil
                        try stmt.execute(arguments: [
                            "core:imports", source, target, from, to,
                        ])
                    }
                }
                inserted += batch
            }
        }

        // Hot query 1: current outgoing edges of one entity (viewer
        // neighborhood fetch), 1000 random entities.
        var edgeTotal = 0
        let currentNeighborhood = try clock.measure {
            try pool.read { db in
                let stmt = try db.makeStatement(sql: """
                    SELECT target_id FROM relationships
                    WHERE source_id = ? AND kind = 'core:imports' AND valid_to IS NULL
                    """)
                for _ in 0..<1000 {
                    let id = Int64(rng.next(upperBound: UInt64(entityCount)) + 1)
                    edgeTotal += try Int64.fetchAll(stmt, arguments: [id]).count
                }
            }
        }

        // Hot query 2: graph as-of a historical revision, same shape.
        var asOfTotal = 0
        let asOfNeighborhood = try clock.measure {
            try pool.read { db in
                let stmt = try db.makeStatement(sql: """
                    SELECT target_id FROM relationships
                    WHERE source_id = ? AND kind = 'core:imports'
                      AND valid_from <= ? AND (valid_to IS NULL OR valid_to > ?)
                    """)
                for _ in 0..<1000 {
                    let id = Int64(rng.next(upperBound: UInt64(entityCount)) + 1)
                    asOfTotal += try Int64.fetchAll(stmt, arguments: [id, 50, 50]).count
                }
            }
        }

        // Hot query 3: full current-graph edge count (projection sizing).
        var currentCount = 0
        let fullCurrentScan = try clock.measure {
            currentCount = try pool.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM relationships WHERE valid_to IS NULL
                    """) ?? 0
            }
        }

        // Revision commit shape: retract 5k facts + assert 5k, one tx.
        let revisionCommit = try clock.measure {
            try pool.write { db in
                try db.execute(sql: """
                    UPDATE relationships SET valid_to = \(revisions + 1)
                    WHERE id IN (SELECT id FROM relationships WHERE valid_to IS NULL LIMIT 5000)
                    """)
                let stmt = try db.makeStatement(sql: """
                    INSERT INTO relationships
                        (kind, source_id, target_id, layer, valid_from, valid_to, properties)
                    VALUES ('core:imports', ?, ?, 'observed', \(revisions + 1), NULL, NULL)
                    """)
                for _ in 0..<5000 {
                    try stmt.execute(arguments: [
                        Int64(rng.next(upperBound: UInt64(entityCount)) + 1),
                        Int64(rng.next(upperBound: UInt64(entityCount)) + 1),
                    ])
                }
            }
        }

        let dbSize = (try? FileManager.default.attributesOfItem(atPath: dbURL.path)[.size] as? Int64) ?? 0

        print("""
        cygnus bench — interval schema prototype
          entities:               \(entityCount)  in \(entityInsert)
          relationships:          \(relationshipCount)  in \(relInsert)
          current neighborhood:   1000 lookups (\(edgeTotal) edges) in \(currentNeighborhood)
          as-of neighborhood:     1000 lookups (\(asOfTotal) edges) in \(asOfNeighborhood)
          full current-edge scan: \(currentCount) rows in \(fullCurrentScan)
          revision commit:        retract 5k + assert 5k in \(revisionCommit)
          db size:                \(dbSize / 1_048_576) MiB
        """)
    }
}

/// Deterministic RNG so benchmark runs are comparable across machines.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(upperBound: UInt64) -> UInt64 { next() % upperBound }
}
