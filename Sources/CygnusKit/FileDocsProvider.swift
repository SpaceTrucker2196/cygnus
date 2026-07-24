import Foundation

// The real docs provider: reads the working tree, writes atomically,
// and optionally commits the single named file (never `git add -A`,
// never push). Enforces the repo's editing invariants — LEDGER.md is
// read-only, METRICS.md append-only, no new files at the repo root, no
// writes escaping the repo.

public struct FileDocsProvider: FactoryDocsProvider {
    let tooling: any FactoryTooling
    let timeout: Duration

    public init(tooling: any FactoryTooling = ProcessTooling(), timeout: Duration = .seconds(30)) {
        self.tooling = tooling
        self.timeout = timeout
    }

    // MARK: - Read

    public func tree(repoAt url: URL) async throws -> DocTree {
        let entries = FactoryDocScan.allDocPaths(repoAt: url).map { path in
            DocEntry(path: path, name: (path as NSString).lastPathComponent,
                     kind: FactoryDocScan.kind(forPath: path),
                     policy: FactoryDocScan.policy(forPath: path))
        }
        return DocTree(sections: FixtureDocsProvider.group(entries))
    }

    public func read(repoAt url: URL, path: String) async throws -> DocFile {
        let fileURL = try Self.resolvedURL(repoAt: url, path: path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw DocsError.notFound(path)
        }
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let modified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return DocFile(path: path, content: content,
                       frontmatter: Frontmatter.fields(content),
                       wikilinks: WikiLinkParser.links(in: content),
                       policy: FactoryDocScan.policy(forPath: path), modified: modified)
    }

    // MARK: - Write

    public func write(repoAt url: URL, path: String,
                      content: String, commit: DocCommit?) async throws -> DocWriteResult {
        let fileURL = try Self.resolvedURL(repoAt: url, path: path)
        let policy = FactoryDocScan.policy(forPath: path)

        // Policy guards.
        if policy == .readOnly { throw DocsError.readOnly(path) }
        if policy == .appendOnly {
            // Full-body overwrite is refused; appends go through a
            // dedicated path (not this method).
            throw DocsError.appendOnlyRequiresAppend(path)
        }
        // Never create a NEW file at the repo root (AGENTS.md rule).
        let isRootLevel = !path.contains("/")
        if isRootLevel, !FileManager.default.fileExists(atPath: fileURL.path) {
            throw DocsError.newRootFileForbidden(path)
        }

        // Atomic write.
        try Data(content.utf8).write(to: fileURL, options: .atomic)

        guard let commit else { return DocWriteResult(committed: false, commitSha: nil) }

        // Named add + commit, no push.
        _ = try await tooling.runChecked(.git, ["-C", url.path, "add", "--", path],
                                         workingDirectory: url, timeout: timeout)
        _ = try await tooling.runChecked(.git, ["-C", url.path, "commit", "-m", commit.message],
                                         workingDirectory: url, timeout: timeout)
        let head = try await tooling.runChecked(.git, ["-C", url.path, "rev-parse", "HEAD"],
                                                workingDirectory: url, timeout: timeout)
        let sha = head.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return DocWriteResult(committed: true, commitSha: sha.isEmpty ? nil : sha)
    }

    // MARK: - Path safety

    /// Resolve `path` under the repo root, rejecting `..` escapes.
    static func resolvedURL(repoAt url: URL, path: String) throws -> URL {
        let root = url.standardizedFileURL
        let target = root.appendingPathComponent(path).standardizedFileURL
        guard target.path == root.path || target.path.hasPrefix(root.path + "/") else {
            throw DocsError.escapesRepo(path)
        }
        return target
    }
}
