import Foundation
import CygnusGraph
import CygnusStore
import CygnusQuery

// A compact, ranked skeleton of a repository, for the top of an
// agent's context.
//
// This is a **projection**, not a table. MISSION invariant 6 says every
// visualization is disposable and recomputable, never a second model,
// and a repo map is a visualization whose viewer happens to be a
// language model. It is memoized in-process on (repository, revision)
// and nowhere else: revisions are monotonic and a commit is one
// transaction, so the revision id is a free and perfect cache key.
//
// The ranking is what makes it worth 3k tokens instead of 30k. Files
// are ordered by weighted PageRank over the dependency and reference
// edges, so what an agent reads first is what the repository actually
// leans on — and truncating the tail drops the least connected files
// rather than whatever sorted last.

public struct RepoMap: Sendable {
    private let store: SQLiteGraphStore

    public init(store: SQLiteGraphStore) {
        self.store = store
    }

    public static let defaultTokens = 3000
    public static let maxTokens = 5000
    /// Declarations listed per file. Past a handful this stops being a
    /// map and starts being an outline.
    public static let declarationsPerFile = 6

    public struct Options: Sendable {
        public var maxTokens: Int
        /// Symbols the task is about. Present, the walk restarts on
        /// their files instead of uniformly, which turns "what matters
        /// in this repository" into "what matters for this task".
        public var focus: [String]

        public init(maxTokens: Int = RepoMap.defaultTokens, focus: [String] = []) {
            self.maxTokens = min(max(maxTokens, TokenBudget.floorTokens), RepoMap.maxTokens)
            self.focus = focus
        }
    }

    public func render(repository: RepositoryID,
                       options: Options = Options()) throws -> String {
        let repositories = try store.repositories()
        guard let repo = repositories.first(where: { $0.id == repository }) else {
            return "unknown repository: \(repository.raw)"
        }

        let files = try store.entities(kind: .file, at: .current)
            .filter { $0.entity.repository == repository }
        guard !files.isEmpty else {
            return "\(repo.displayName): not indexed — run `cygnus index`"
        }

        let fileIDs = Set(files.map(\.entity.id))
        let (edges, hasReferences) = try rankingEdges(within: fileIDs)

        // Focus seeds are declarations; the walk runs over files, so
        // each seed contributes the file it is anchored in.
        var seeds = Set<EntityID>()
        for name in options.focus {
            for match in try Lookups.definitions(
                store: store, named: name, repository: repository, limit: 3) {
                guard let path = match.version.anchors.first?.path,
                      let file = files.first(where: {
                          $0.version.anchors.first?.path == path
                              || $0.version.name == path
                      }) else { continue }
                seeds.insert(file.entity.id)
            }
        }

        let ranks = Centrality.pageRank(
            nodes: files.map(\.entity.id), edges: edges, personalization: seeds)
        let ranked = files.sorted { lhs, rhs in
            let left = ranks[lhs.entity.id] ?? 0
            let right = ranks[rhs.entity.id] ?? 0
            return left == right
                ? path(of: lhs) < path(of: rhs)
                : left > right
        }

        let declarations = try declarationsByPath(repository: repository)
        var budget = TokenBudget(maxTokens: options.maxTokens)

        var header = "\(repo.displayName) — \(files.count) files, ranked by centrality"
        if !seeds.isEmpty { header += ", focused on \(options.focus.joined(separator: ", "))" }
        if !hasReferences {
            // Without a build there are no compiler-resolved reference
            // edges, so the ranking rests on imports alone. Say so
            // rather than present a weaker ranking as the same thing.
            header += "\n(no compiler references — ranked by imports only; build the repo for more)"
        }
        budget.admitAlways(header)
        budget.admitAlways("")

        // Group by directory rather than emitting a globally-ranked
        // flat list: ranking interleaves directories, which would
        // repeat every header and read as noise. Directories inherit
        // the rank of their best file, so the ordering still leads with
        // what matters.
        var order: [String] = []
        var byDirectory: [String: [ResolvedEntity]] = [:]
        for file in ranked {
            let directory = (path(of: file) as NSString).deletingLastPathComponent
            let key = directory.isEmpty ? "." : directory
            if byDirectory[key] == nil { order.append(key) }
            byDirectory[key, default: []].append(file)
        }

        emit: for directory in order {
            guard budget.admit("\(directory)/") else { break }
            for file in byDirectory[directory] ?? [] {
                let filePath = path(of: file)
                var block = "  \((filePath as NSString).lastPathComponent)"
                let symbols = Self.headline(declarations[filePath] ?? [])
                    .map { "\($0.name):\($0.line)" }
                    .joined(separator: " ")
                if !symbols.isEmpty { block += "  \(symbols)" }
                guard budget.admitCounted(block) else { break emit }
            }
        }

        return budget.finish(total: files.count)
    }

    // MARK: - Internals

    private func path(of file: ResolvedEntity) -> String {
        file.version.anchors.first?.path ?? file.version.name
    }

    /// Edges the ranking walks, and whether compiler references were
    /// among them. Weights: a reference counts as much as it was used,
    /// a build dependency twice, an import once.
    private func rankingEdges(within files: Set<EntityID>) throws
        -> (edges: [(EntityID, EntityID, Double)], hasReferences: Bool) {
        var edges: [(EntityID, EntityID, Double)] = []
        var hasReferences = false

        for edge in try store.relationships(kind: .references, at: .current)
        where files.contains(edge.source) && files.contains(edge.target) {
            hasReferences = true
            let count: Double
            if case .int(let value)? = edge.properties["core:referenceCount"] {
                count = Double(value)
            } else {
                count = 1
            }
            edges.append((edge.source, edge.target, count))
        }
        for edge in try store.relationships(kind: .imports, at: .current)
        where files.contains(edge.source) && files.contains(edge.target) {
            edges.append((edge.source, edge.target, 1))
        }
        for edge in try store.relationships(kind: .builds, at: .current)
        where files.contains(edge.source) && files.contains(edge.target) {
            edges.append((edge.source, edge.target, 2))
        }
        return (edges, hasReferences)
    }

    struct Declaration {
        let name: String
        let line: Int
        let kind: EntityKind
    }

    /// Which declarations earn the handful of tokens a file gets.
    ///
    /// Source order alone spends the whole allowance on whatever
    /// happens to sit at the top of the file — usually one-line stored
    /// properties (`raw`, `id`, `name`), which say nothing about what
    /// the file *is*. Types and functions carry the shape; select by
    /// that, then restore reading order.
    static func headline(_ declarations: [Declaration]) -> [Declaration] {
        func weight(_ kind: EntityKind) -> Int {
            switch kind {
            case .type, .interface, .enumeration: return 0
            case .function: return 1
            default: return 2
            }
        }
        return declarations
            .enumerated()
            .sorted { lhs, rhs in
                let left = weight(lhs.element.kind)
                let right = weight(rhs.element.kind)
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .prefix(declarationsPerFile)
            .map(\.element)
            .sorted { $0.line == $1.line ? $0.name < $1.name : $0.line < $1.line }
    }

    /// Declarations per file, in source order, most-central first is
    /// deliberately *not* used here — within a file, reading order is
    /// what a human or model expects.
    private func declarationsByPath(repository: RepositoryID) throws -> [String: [Declaration]] {
        var result: [String: [Declaration]] = [:]
        for kind in Lookups.definitionKinds {
            for entity in try store.entities(kind: kind, at: .current)
            where entity.entity.repository == repository {
                guard let anchor = entity.version.anchors.first,
                      let range = anchor.range else { continue }
                result[anchor.path, default: []].append(Declaration(
                    name: entity.version.name, line: range.startLine, kind: kind))
            }
        }
        for path in result.keys {
            result[path]?.sort { $0.line == $1.line ? $0.name < $1.name : $0.line < $1.line }
        }
        return result
    }
}
