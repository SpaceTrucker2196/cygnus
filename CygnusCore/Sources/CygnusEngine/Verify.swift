import Foundation
import CygnusGraph
import CygnusStore

// `cygnus verify`: recompute a repository's graph from scratch in a
// throwaway workspace and diff it against the incrementally
// maintained graph. The incremental pipeline is only trusted because
// this can prove it equal to a cold rebuild.

public struct VerifyReport: Sendable {
    public let repository: RepositoryID
    /// Normalized facts present incrementally but not in the rebuild.
    public let staleFacts: [String]
    /// Normalized facts present in the rebuild but missing incrementally.
    public let missingFacts: [String]
    public var isClean: Bool { staleFacts.isEmpty && missingFacts.isEmpty }
}

extension CygnusWorkspace {
    /// Full-rebuild comparison for one repository. Repo IDs differ
    /// between workspaces, so facts are normalized with a `$R`
    /// placeholder before comparison.
    public func verify(_ repoID: RepositoryID) async throws -> VerifyReport {
        guard let repo = try store.repositories().first(where: { $0.id == repoID }),
              let rootPath = repo.rootPath
        else { throw WorkspaceError.unknownRepository(repoID) }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-verify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fresh = try CygnusWorkspace(directory: scratch)
        let freshRepo = try await fresh.register(path: URL(fileURLWithPath: rootPath))
        _ = try await fresh.index(freshRepo)

        let incremental = try Self.normalizedFacts(store: store, repo: repoID)
        let rebuilt = try Self.normalizedFacts(store: fresh.store, repo: freshRepo)

        return VerifyReport(
            repository: repoID,
            staleFacts: incremental.subtracting(rebuilt).sorted(),
            missingFacts: rebuilt.subtracting(incremental).sorted())
    }

    /// Current entity and relationship facts for one repository as
    /// repo-id-normalized strings.
    static func normalizedFacts(store: SQLiteGraphStore,
                                repo: RepositoryID) throws -> Set<String> {
        func normalize(_ key: String) -> String {
            key.replacingOccurrences(of: repo.raw, with: "$R")
        }

        var facts = Set<String>()
        var keyByEntityID: [EntityID: String] = [:]
        var repoEntityIDs = Set<EntityID>()

        for kind in [EntityKind.repository, .directory, .file, .module, .type,
                     .interface, .enumeration, .function, .variable] {
            for resolved in try store.entities(kind: kind, at: .current) {
                keyByEntityID[resolved.entity.id] = resolved.entity.stableKey.raw
                // Modules are shared (repository == nil); everything
                // else must belong to the repo under verification.
                guard resolved.entity.repository == repo
                        || resolved.entity.repository == nil else { continue }
                if resolved.entity.repository == repo {
                    repoEntityIDs.insert(resolved.entity.id)
                    facts.insert("entity|\(normalize(resolved.entity.stableKey.raw))" +
                                 "|\(resolved.entity.kind.rawValue)|\(resolved.version.name)")
                }
            }
        }

        for kind in [RelationshipKind.containsPhysical, .declares, .imports] {
            for edge in try store.relationships(kind: kind, at: .current) {
                guard let source = keyByEntityID[edge.source],
                      let target = keyByEntityID[edge.target],
                      repoEntityIDs.contains(edge.source) else { continue }
                facts.insert("edge|\(kind.rawValue)|\(normalize(source))|\(normalize(target))")
            }
        }
        return facts
    }
}
