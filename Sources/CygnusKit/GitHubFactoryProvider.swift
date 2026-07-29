import Foundation

// The real FactoryProvider: `gh` for GitHub state (issues, runs,
// checks), `git` for commits, and local file reads for the markdown
// tables and converge loop. Everything flows through FactoryTooling so
// it's testable with FixtureTooling + captured JSON.

public struct GitHubFactoryProvider: FactoryProvider {
    let tooling: any FactoryTooling
    let timeout: Duration

    public init(tooling: any FactoryTooling = ProcessTooling(), timeout: Duration = .seconds(30)) {
        self.tooling = tooling
        self.timeout = timeout
    }

    // MARK: - Capabilities

    public func detectCapabilities(repoAt url: URL) async -> FactoryCapabilities {
        var caps = FactoryCapabilities()

        // Remote from origin (non-zero exit is normal for no remote).
        if let result = try? await tooling.run(.git, ["-C", url.path, "remote", "get-url", "origin"],
                                               workingDirectory: url, timeout: timeout),
           result.succeeded {
            caps.remote = RepoRemote.parse(originURL: result.stdoutString)
        }

        // gh presence + auth: toolNotFound → unavailable; runs but
        // non-zero with an auth message → available-but-unauthed.
        do {
            let auth = try await tooling.run(.gh, ["auth", "status"],
                                             workingDirectory: url, timeout: timeout)
            caps.ghAvailable = true
            caps.ghAuthenticated = auth.succeeded
        } catch ToolingError.toolNotFound {
            caps.ghAvailable = false
        } catch {
            caps.ghAvailable = true          // it ran, something else failed
            caps.ghAuthenticated = false
        }

        // Local files.
        let fm = FileManager.default
        func exists(_ rel: String) -> Bool { fm.fileExists(atPath: url.appendingPathComponent(rel).path) }
        for candidate in ["agents/converge.md", ".claude/commands/converge.md"] where exists(candidate) {
            caps.hasConverge = true; caps.convergePath = candidate; break
        }
        caps.hasMetrics = exists("METRICS.md")
        caps.hasLedger = exists("LEDGER.md")
        caps.hasWorkflows = directoryHasYAML(url.appendingPathComponent(".github/workflows"))
        caps.hasDocs = FactoryDocScan.hasAnyDoc(repoAt: url)
        caps.screenshots = Self.fastlaneScreenshots(repoAt: url)
        caps.fastlane = FastlaneScan.scan(repoAt: url)
        caps.ciFlow = Self.ciFlow(repoAt: url, fastlane: caps.fastlane)
        caps.pagesURL = await detectPagesURL(repoAt: url, caps: caps)
        return caps
    }

    private func directoryHasYAML(_ dir: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        return entries.contains { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }
    }

    /// The pipeline to chart: fastlane's flow when the Fastfile parses
    /// to lanes, otherwise the top-level Makefile's target graph. Nil
    /// when the repo has neither — the CI Flow section then says so.
    static func ciFlow(repoAt url: URL, fastlane: FastlaneInfo?) -> CIFlow? {
        if let flow = fastlane?.flow, !flow.isEmpty { return flow }
        for name in ["Makefile", "makefile", "GNUmakefile"] {
            let path = url.appendingPathComponent(name)
            if let text = try? String(contentsOf: path, encoding: .utf8) {
                let flow = MakeFlowBuilder.build(makefileText: text)
                return flow.isEmpty ? nil : flow
            }
        }
        return nil
    }

    /// Fastlane screenshot scan: everything image-like under
    /// `fastlane/` (snapshot puts them in `screenshots/<locale>/`,
    /// deliver under `metadata/`). Sorted for stable order, capped —
    /// the dashboard shows a preview strip, not a gallery.
    static let screenshotCap = 24
    static func fastlaneScreenshots(repoAt url: URL) -> [String] {
        let root = url.appendingPathComponent("fastlane")
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return [] }
        var found: [String] = []
        for case let file as URL in enumerator {
            guard ["png", "jpg", "jpeg"].contains(file.pathExtension.lowercased())
            else { continue }
            let rootPath = url.standardizedFileURL.path
            let path = file.standardizedFileURL.path
            guard path.hasPrefix(rootPath) else { continue }
            found.append(String(path.dropFirst(rootPath.count).drop(while: { $0 == "/" })))
        }
        return Array(found.sorted().prefix(screenshotCap))
    }

    /// Pages URL: authoritative from `gh api .../pages` when GitHub is
    /// reachable; falls back to the `owner.github.io/name` convention
    /// when a pages deploy workflow exists.
    private func detectPagesURL(repoAt url: URL, caps: FactoryCapabilities) async -> String? {
        guard let remote = caps.remote else { return nil }
        if caps.github,
           let result = try? await tooling.run(
               .gh, ["api", "repos/\(remote.slug)/pages", "--jq", ".html_url"],
               workingDirectory: url, timeout: timeout),
           result.succeeded {
            let html = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !html.isEmpty { return html }
        }
        let workflows = url.appendingPathComponent(".github/workflows")
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: workflows.path),
           entries.contains(where: { $0.lowercased().contains("pages") }) {
            return "https://\(remote.owner).github.io/\(remote.name)/"
        }
        return nil
    }

    // MARK: - GitHub (gh)

    private static let issueListFields =
        "number,title,state,labels,body,createdAt,closedAt,milestone,author"

    public func listIssues(remote: RepoRemote) async throws -> [Issue] {
        let result = try await tooling.runChecked(.gh, [
            "issue", "list", "--repo", remote.slug, "--state", "all",
            "--limit", "200", "--json", Self.issueListFields,
        ], workingDirectory: nil, timeout: timeout)
        let dtos = try Self.decoder.decode([IssueDTO].self, from: result.stdout)
        return dtos.map { $0.toDomain(comments: []) }
    }

    public func viewIssue(remote: RepoRemote, number: Int) async throws -> Issue {
        let result = try await tooling.runChecked(.gh, [
            "issue", "view", String(number), "--repo", remote.slug,
            "--json", Self.issueListFields + ",comments",
        ], workingDirectory: nil, timeout: timeout)
        let dto = try Self.decoder.decode(IssueDTO.self, from: result.stdout)
        let comments = (dto.comments ?? []).enumerated().map { index, c in
            IssueComment(id: index, author: c.author?.login ?? "unknown",
                         body: c.body, createdAt: c.createdAt)
        }
        return dto.toDomain(comments: comments)
    }

    public func listRuns(remote: RepoRemote, limit: Int) async throws -> [WorkflowRun] {
        let result = try await tooling.runChecked(.gh, [
            "run", "list", "--repo", remote.slug, "--limit", String(limit),
            "--json", "databaseId,name,status,conclusion,headSha,headBranch,event,createdAt,url",
        ], workingDirectory: nil, timeout: timeout)
        let dtos = try Self.decoder.decode([RunDTO].self, from: result.stdout)
        return dtos.map { $0.toDomain() }
    }

    public func checkRuns(remote: RepoRemote, sha: String) async throws -> [CheckRun] {
        let result = try await tooling.runChecked(.gh, [
            "api", "repos/\(remote.slug)/commits/\(sha)/check-runs",
        ], workingDirectory: nil, timeout: timeout)
        let envelope = try Self.decoder.decode(CheckRunEnvelope.self, from: result.stdout)
        return envelope.check_runs.map {
            CheckRun(name: $0.name, status: $0.status, conclusion: $0.conclusion)
        }
    }

    // MARK: - Issue actions (writes)

    public func createIssue(remote: RepoRemote, title: String, body: String,
                            labels: [String]) async throws -> Issue {
        var args = ["issue", "create", "--repo", remote.slug,
                    "--title", title, "--body", body]
        for label in labels { args += ["--label", label] }
        // `gh issue create` prints the new issue URL; the trailing path
        // component is its number.
        let result = try await tooling.runChecked(.gh, args,
                                                  workingDirectory: nil, timeout: timeout)
        let number = Self.issueNumber(fromURL: result.stdoutString)
        guard let number else {
            throw ToolingError.nonZeroExit(.gh, code: 0,
                stderr: "created issue but couldn't parse its number from: \(result.stdoutString)")
        }
        return try await viewIssue(remote: remote, number: number)
    }

    public func commentIssue(remote: RepoRemote, number: Int, body: String) async throws -> Issue {
        _ = try await tooling.runChecked(.gh, [
            "issue", "comment", String(number), "--repo", remote.slug, "--body", body,
        ], workingDirectory: nil, timeout: timeout)
        return try await viewIssue(remote: remote, number: number)
    }

    public func setIssueState(remote: RepoRemote, number: Int, closed: Bool) async throws -> Issue {
        _ = try await tooling.runChecked(.gh, [
            "issue", closed ? "close" : "reopen", String(number), "--repo", remote.slug,
        ], workingDirectory: nil, timeout: timeout)
        return try await viewIssue(remote: remote, number: number)
    }

    /// Last path component of a github.com issue URL, as an Int.
    static func issueNumber(fromURL text: String) -> Int? {
        text.split(whereSeparator: \.isWhitespace)
            .compactMap { line -> Int? in
                guard line.contains("github.com") else { return nil }
                return line.split(separator: "/").last.flatMap { Int($0) }
            }
            .first
    }

    // MARK: - git + files

    public func recentCommits(repoAt url: URL, limit: Int) async throws -> [CommitInfo] {
        let result = try await tooling.runChecked(.git, [
            "-C", url.path, "log", "-n", String(limit),
            "--format=%H%x00%h%x00%an%x00%aI%x00%s",
        ], workingDirectory: url, timeout: timeout)
        return result.stdoutString
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { FactoryParse.commit(fromLogLine: String($0)) }
    }

    public func metricsRows(repoAt url: URL) async throws -> [MetricsRow] {
        guard let text = try Self.readIfExists(url.appendingPathComponent("METRICS.md")) else { return [] }
        return FactoryParse.metricsRows(text)
    }

    public func ledgerRows(repoAt url: URL) async throws -> [LedgerRow] {
        guard let text = try Self.readIfExists(url.appendingPathComponent("LEDGER.md")) else { return [] }
        return FactoryParse.ledgerRows(text)
    }

    public func convergePipeline(repoAt url: URL) async throws -> ConvergePipeline? {
        for candidate in ["agents/converge.md", ".claude/commands/converge.md"] {
            if let text = try Self.readIfExists(url.appendingPathComponent(candidate)) {
                let steps = FactoryParse.convergeSteps(text)
                return steps.isEmpty ? nil : ConvergePipeline(steps: steps, sourcePath: candidate)
            }
        }
        return nil
    }

    // MARK: - Helpers

    static func readIfExists(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - Decodable DTOs (gh --json shapes)

private struct AuthorDTO: Decodable { let login: String?; let name: String? }
private struct LabelDTO: Decodable { let name: String; let color: String? }
private struct MilestoneDTO: Decodable { let title: String; let number: Int }
private struct CommentDTO: Decodable { let author: AuthorDTO?; let body: String; let createdAt: Date }

private struct IssueDTO: Decodable {
    let number: Int
    let title: String
    let state: String          // gh returns "OPEN"/"CLOSED"
    let labels: [LabelDTO]
    let body: String
    let author: AuthorDTO?
    let createdAt: Date
    let closedAt: Date?
    let milestone: MilestoneDTO?
    let comments: [CommentDTO]?

    func toDomain(comments: [IssueComment]) -> Issue {
        Issue(
            number: number,
            title: title,
            state: state.lowercased() == "closed" ? .closed : .open,
            labels: labels.map { IssueLabel(name: $0.name, color: $0.color ?? "cccccc") },
            body: body,
            author: author?.login ?? "unknown",
            createdAt: createdAt,
            closedAt: closedAt,
            milestone: milestone.map { Milestone(title: $0.title, number: $0.number) },
            comments: comments)
    }
}

private struct RunDTO: Decodable {
    let databaseId: Int
    let name: String
    let status: String
    let conclusion: String?
    let headSha: String
    let headBranch: String
    let event: String
    let createdAt: Date
    let url: String

    func toDomain() -> WorkflowRun {
        WorkflowRun(id: databaseId, name: name, status: status, conclusion: conclusion,
                    headSha: headSha, headBranch: headBranch, event: event,
                    createdAt: createdAt, url: url)
    }
}

private struct CheckRunEnvelope: Decodable { let check_runs: [CheckRunDTO] }
private struct CheckRunDTO: Decodable { let name: String; let status: String; let conclusion: String? }
