import Foundation
import GRDB
import CygnusGraph

// Reads the agent-facing lookups need and the GraphStore protocol
// deliberately doesn't carry. Same precedent as `diff` and
// `currentEntityKeys`: the protocol stays small and stable, and the
// concrete store grows the queries its callers actually issue.

extension SQLiteGraphStore {
    /// Name search restricted to entity kinds.
    ///
    /// `searchNames` returns every kind, including directories and
    /// module stubs — fine for a viewer's search field, useless for
    /// "find the definition of `send`", where a directory named
    /// `send` outranking the function is simply a wrong answer.
    ///
    /// Ranking, strongest evidence first: an exact name match, then a
    /// declaration path whose last component matches exactly, then
    /// FTS rank for everything else.
    public func searchNames(_ text: String, kinds: [EntityKind],
                            repository: RepositoryID? = nil,
                            limit: Int) throws -> [ResolvedEntity] {
        let terms = text
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
            .joined(separator: " ")
        guard !terms.isEmpty else { return [] }

        var sql = """
            SELECT e.id AS eid, e.stable_key, e.kind, e.repository_id, e.first_seen_rev,
                   v.id AS vid, v.valid_from, v.valid_to, v.name, v.properties, v.anchors
            FROM entity_search s
            JOIN entity_versions v ON v.id = s.version_id
            JOIN entities e ON e.id = v.entity_id
            WHERE entity_search MATCH ? AND v.valid_to IS NULL
            """
        var arguments: [DatabaseValueConvertible] = [terms]
        if !kinds.isEmpty {
            let marks = Array(repeating: "?", count: kinds.count).joined(separator: ",")
            sql += " AND e.kind IN (\(marks))"
            arguments.append(contentsOf: kinds.map(\.rawValue))
        }
        if let repository {
            sql += " AND e.repository_id = ?"
            arguments.append(repository.raw)
        }
        // Over-fetch before the exactness sort, or a better match sitting
        // just outside the FTS window never gets the chance to be
        // promoted.
        sql += " ORDER BY rank LIMIT ?"
        arguments.append(max(limit * 5, limit))

        let candidates = try readRetrieval { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                .map(Self.resolvedEntity)
        }

        let needle = text.lowercased()
        return candidates
            .enumerated()
            .sorted { lhs, rhs in
                let left = Self.exactness(lhs.element, needle: needle)
                let right = Self.exactness(rhs.element, needle: needle)
                // Ties keep FTS order, which keeps results stable.
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .prefix(limit)
            .map(\.element)
    }

    /// 0 = exact name, 1 = declaration path tail, 2 = everything else.
    private static func exactness(_ entity: ResolvedEntity, needle: String) -> Int {
        if entity.version.name.lowercased() == needle { return 0 }
        if case .string(let declPath)? = entity.version.properties["core:declPath"],
           declPath.split(separator: ".").last?.lowercased() == needle { return 1 }
        return 2
    }

    /// The blob a path resolved to in the newest committed snapshot of
    /// its repository. Reads go to the CAS, never the working tree, so
    /// the text an agent sees is the text the graph's line numbers
    /// refer to.
    public func currentBlob(forPath path: String,
                            repository: RepositoryID) throws -> BlobHash? {
        try readRetrieval { db in
            try String.fetchOne(db, sql: """
                SELECT f.blob_hash
                FROM snapshot_files f
                JOIN snapshots s ON s.id = f.snapshot_id
                WHERE f.path = ? AND s.repository_id = ?
                  AND f.snapshot_id = (
                      SELECT MAX(r.snapshot_id) FROM revisions r
                      JOIN snapshots s2 ON s2.id = r.snapshot_id
                      WHERE s2.repository_id = ?)
                """, arguments: [path, repository.raw, repository.raw])
                .map(BlobHash.init)
        }
    }

    /// Entities anchored in a file, resolved rather than key-only.
    /// `currentEntityKeys` forces a second round trip per symbol just
    /// to learn its name and range.
    public func resolvedEntities(anchoredIn path: String) throws -> [ResolvedEntity] {
        try readRetrieval { db in
            try Row.fetchAll(db, sql: """
                SELECT e.id AS eid, e.stable_key, e.kind, e.repository_id, e.first_seen_rev,
                       v.id AS vid, v.valid_from, v.valid_to, v.name, v.properties, v.anchors
                FROM entity_version_paths p
                JOIN entity_versions v ON v.id = p.version_id AND v.valid_to IS NULL
                JOIN entities e ON e.id = v.entity_id
                WHERE p.path = ?
                ORDER BY e.stable_key
                """, arguments: [path]).map(Self.resolvedEntity)
        }
    }

    /// Whether any compiler-resolved symbol edge exists for a
    /// repository. This is what separates "nothing calls this" from
    /// "this repository was never built, so we cannot know" — a
    /// distinction that has to survive all the way to the tool output.
    public func hasCompilerReferences(repository: RepositoryID) throws -> Bool {
        try readRetrieval { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM relationships r
                    JOIN entities e ON e.id = r.source_id
                    WHERE r.kind = ? AND r.valid_to IS NULL AND e.repository_id = ?)
                """, arguments: [RelationshipKind.refersToSymbol.rawValue, repository.raw]) ?? false
        }
    }
}
