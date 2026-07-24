import Foundation

// Browsing and editing the repo's agent docs. The real impl reads the
// working tree and writes atomically, with an optional named git
// commit; the fixture serves canned docs for previews/tests.

// MARK: - Types

public enum DocKind: String, Sendable, CaseIterable {
    case mission, charter, factory, progress, roadmap, milestones
    case wiki, views, ledger, metrics, readme, other

    public var title: String {
        switch self {
        case .mission: "Mission"
        case .charter: "Agent Rules"
        case .factory: "Factory Runbook"
        case .progress: "Progress"
        case .roadmap: "Roadmap"
        case .milestones: "Milestones"
        case .wiki: "Wiki"
        case .views: "View Specs"
        case .ledger: "Ledger"
        case .metrics: "Metrics"
        case .readme: "Readme"
        case .other: "Other"
        }
    }

    /// Display order in the tree.
    public var sortRank: Int { DocKind.allCases.firstIndex(of: self) ?? 99 }
}

/// How an editor may touch a doc.
public enum DocPolicy: String, Sendable, Equatable {
    case editable      // free edit + save
    case appendOnly    // structured append only (e.g. METRICS.md)
    case readOnly      // machine-owned, never hand-edit (e.g. LEDGER.md)
}

public struct DocEntry: Sendable, Equatable, Identifiable {
    public let path: String        // repo-relative
    public let name: String        // display name
    public let kind: DocKind
    public let policy: DocPolicy
    public init(path: String, name: String, kind: DocKind, policy: DocPolicy) {
        self.path = path; self.name = name; self.kind = kind; self.policy = policy
    }
    public var id: String { path }
}

public struct DocSection: Sendable, Equatable, Identifiable {
    public let kind: DocKind
    public let entries: [DocEntry]
    public init(kind: DocKind, entries: [DocEntry]) { self.kind = kind; self.entries = entries }
    public var id: String { kind.rawValue }
}

public struct DocTree: Sendable, Equatable {
    public let sections: [DocSection]
    public init(sections: [DocSection]) { self.sections = sections }
    public var isEmpty: Bool { sections.allSatisfy { $0.entries.isEmpty } }
    /// Flat slug→path map for resolving [[wikilinks]].
    public var slugMap: [String: String] {
        var map: [String: String] = [:]
        for section in sections {
            for entry in section.entries {
                map[WikiLinkParser.slug((entry.path as NSString).lastPathComponent)] = entry.path
                map[WikiLinkParser.slug(entry.name)] = entry.path
            }
        }
        return map
    }
}

public struct DocFile: Sendable, Equatable {
    public let path: String
    public let content: String
    public let frontmatter: [String: String]
    public let wikilinks: [WikiLink]
    public let policy: DocPolicy
    public let modified: Date?
    public init(path: String, content: String, frontmatter: [String: String],
                wikilinks: [WikiLink], policy: DocPolicy, modified: Date?) {
        self.path = path; self.content = content; self.frontmatter = frontmatter
        self.wikilinks = wikilinks; self.policy = policy; self.modified = modified
    }
    public var markdown: MarkdownDocument { MarkdownDocument(source: content) }
}

public struct DocCommit: Sendable, Equatable {
    public let message: String
    public init(message: String) { self.message = message }
}

public struct DocWriteResult: Sendable, Equatable {
    public let committed: Bool
    public let commitSha: String?
    public init(committed: Bool, commitSha: String?) {
        self.committed = committed; self.commitSha = commitSha
    }
}

public enum DocsError: Error, Sendable, Equatable {
    case readOnly(String)
    case appendOnlyRequiresAppend(String)
    case escapesRepo(String)
    case newRootFileForbidden(String)
    case notFound(String)
}

// MARK: - Provider

public protocol FactoryDocsProvider: Sendable {
    func tree(repoAt url: URL) async throws -> DocTree
    func read(repoAt url: URL, path: String) async throws -> DocFile
    func write(repoAt url: URL, path: String, content: String, commit: DocCommit?) async throws -> DocWriteResult
}

// MARK: - Classification & scanning (shared by real provider + capabilities)

public enum FactoryDocScan {
    /// Root-level docs we recognise, in the order we want them grouped.
    static let rootDocs = ["MISSION.md", "AGENTS.md", "CLAUDE.md", "FACTORY.md",
                           "PROGRESS.md", "ROADMAP.md", "README.md",
                           "METRICS.md", "LEDGER.md"]
    static let agentDocs = ["agents/MISSION.md", "agents/AGENTS.md", "agents/FACTORY.md",
                            "agents/dark-factory.md", "agents/converge.md"]
    static let docDirs = ["docs", "docs/wiki", "docs/views"]

    public static func hasAnyDoc(repoAt url: URL) -> Bool {
        let fm = FileManager.default
        for rel in rootDocs + agentDocs where fm.fileExists(atPath: url.appendingPathComponent(rel).path) {
            return true
        }
        for dir in docDirs where fm.fileExists(atPath: url.appendingPathComponent(dir).path) {
            return true
        }
        return false
    }

    public static func kind(forPath path: String) -> DocKind {
        let name = (path as NSString).lastPathComponent.uppercased()
        if path.hasPrefix("docs/wiki/") { return .wiki }
        if path.hasPrefix("docs/views/") { return .views }
        switch name {
        case "MISSION.MD": return .mission
        case "AGENTS.MD", "CLAUDE.MD": return .charter
        case "FACTORY.MD": return .factory
        case "PROGRESS.MD": return .progress
        case "ROADMAP.MD": return .roadmap
        case "MILESTONES.MD": return .milestones
        case "LEDGER.MD": return .ledger
        case "METRICS.MD": return .metrics
        case "README.MD": return .readme
        default: return path.hasPrefix("docs/") ? .wiki : .other
        }
    }

    public static func policy(forPath path: String) -> DocPolicy {
        let name = (path as NSString).lastPathComponent.uppercased()
        switch name {
        case "LEDGER.MD": return .readOnly
        case "METRICS.MD": return .appendOnly
        default: return .editable
        }
    }

    /// Collect every recognised doc path in the repo (repo-relative).
    static func allDocPaths(repoAt url: URL) -> [String] {
        let fm = FileManager.default
        var paths: [String] = []
        for rel in rootDocs + agentDocs where fm.fileExists(atPath: url.appendingPathComponent(rel).path) {
            paths.append(rel)
        }
        for dir in ["docs"] {
            let base = url.appendingPathComponent(dir)
            guard let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles]) else { continue }
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "md" {
                let rel = fileURL.path.replacingOccurrences(of: url.path + "/", with: "")
                paths.append(rel)
            }
        }
        return paths
    }
}

// MARK: - Fixture

public struct FixtureDocsProvider: FactoryDocsProvider {
    public var files: [String: String]
    public init(files: [String: String] = FixtureDocsProvider.sampleFiles) { self.files = files }

    public static let sampleFiles: [String: String] = [
        "MISSION.md": "# Mission\n\nWhat this factory does.",
        "docs/milestones.md": "## Engine\n\n- [x] **E1** — Model. *(2026-07-19)*\n- [ ] **E2** — Store.",
        "docs/wiki/architecture.md": "---\nname: architecture\ntype: reference\n---\n\n# Architecture\n\nSee [[mission]].",
        "LEDGER.md": "| commit | cost |\n|---|---|\n| abc | 1.0 |",
    ]

    public func tree(repoAt url: URL) async throws -> DocTree {
        let entries = files.keys.sorted().map { path in
            DocEntry(path: path, name: (path as NSString).lastPathComponent,
                     kind: FactoryDocScan.kind(forPath: path),
                     policy: FactoryDocScan.policy(forPath: path))
        }
        return DocTree(sections: FixtureDocsProvider.group(entries))
    }

    public func read(repoAt url: URL, path: String) async throws -> DocFile {
        guard let content = files[path] else { throw DocsError.notFound(path) }
        return DocFile(path: path, content: content,
                       frontmatter: Frontmatter.fields(content),
                       wikilinks: WikiLinkParser.links(in: content),
                       policy: FactoryDocScan.policy(forPath: path), modified: nil)
    }

    public func write(repoAt url: URL, path: String, content: String, commit: DocCommit?) async throws -> DocWriteResult {
        if FactoryDocScan.policy(forPath: path) == .readOnly { throw DocsError.readOnly(path) }
        return DocWriteResult(committed: commit != nil, commitSha: commit != nil ? "fixturesha" : nil)
    }

    public static func group(_ entries: [DocEntry]) -> [DocSection] {
        Dictionary(grouping: entries, by: \.kind)
            .map { DocSection(kind: $0.key, entries: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.kind.sortRank < $1.kind.sortRank }
    }
}
