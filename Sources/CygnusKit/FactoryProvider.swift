import Foundation

// What the store needs to populate the ops sections. The real impl
// (GitHubFactoryProvider) drives git/gh + reads local files; the
// fixture returns .sample values so views preview and tests run with
// no network. Async is one-shot (not a stream): each call is a single
// CLI invocation or file read, refreshed on demand.

public protocol FactoryProvider: Sendable {
    func detectCapabilities(repoAt url: URL) async -> FactoryCapabilities
    func listIssues(remote: RepoRemote) async throws -> [Issue]
    func viewIssue(remote: RepoRemote, number: Int) async throws -> Issue
    func listRuns(remote: RepoRemote, limit: Int) async throws -> [WorkflowRun]
    func checkRuns(remote: RepoRemote, sha: String) async throws -> [CheckRun]
    func recentCommits(repoAt url: URL, limit: Int) async throws -> [CommitInfo]
    func metricsRows(repoAt url: URL) async throws -> [MetricsRow]
    func ledgerRows(repoAt url: URL) async throws -> [LedgerRow]
    func convergePipeline(repoAt url: URL) async throws -> ConvergePipeline?

    // MARK: Issue actions (production-order control surface)

    /// Open a new issue and return it (fetched back with `viewIssue`).
    func createIssue(remote: RepoRemote, title: String, body: String,
                     labels: [String]) async throws -> Issue
    /// Add a comment; returns the issue re-fetched with the comment.
    func commentIssue(remote: RepoRemote, number: Int, body: String) async throws -> Issue
    /// Close or reopen; returns the issue re-fetched in its new state.
    func setIssueState(remote: RepoRemote, number: Int, closed: Bool) async throws -> Issue
}

/// Deterministic provider for previews and tests.
public struct FixtureFactoryProvider: FactoryProvider {
    public var capabilities: FactoryCapabilities
    public var issues: [Issue]
    public var runs: [WorkflowRun]
    public var commits: [CommitInfo]
    public var metrics: [MetricsRow]
    public var ledger: [LedgerRow]
    public var converge: ConvergePipeline?

    public init(capabilities: FactoryCapabilities = .sample,
                issues: [Issue] = Issue.samples,
                runs: [WorkflowRun] = WorkflowRun.samples,
                commits: [CommitInfo] = CommitInfo.samples,
                metrics: [MetricsRow] = MetricsRow.samples,
                ledger: [LedgerRow] = LedgerRow.samples,
                converge: ConvergePipeline? = .sample) {
        self.capabilities = capabilities
        self.issues = issues
        self.runs = runs
        self.commits = commits
        self.metrics = metrics
        self.ledger = ledger
        self.converge = converge
    }

    public func detectCapabilities(repoAt url: URL) async -> FactoryCapabilities { capabilities }
    public func listIssues(remote: RepoRemote) async throws -> [Issue] { issues }
    public func viewIssue(remote: RepoRemote, number: Int) async throws -> Issue {
        issues.first { $0.number == number } ?? Issue.sample
    }
    public func listRuns(remote: RepoRemote, limit: Int) async throws -> [WorkflowRun] {
        Array(runs.prefix(limit))
    }
    public func checkRuns(remote: RepoRemote, sha: String) async throws -> [CheckRun] {
        [CheckRun(name: "build", status: "completed", conclusion: "success")]
    }
    public func recentCommits(repoAt url: URL, limit: Int) async throws -> [CommitInfo] {
        Array(commits.prefix(limit))
    }
    public func metricsRows(repoAt url: URL) async throws -> [MetricsRow] { metrics }
    public func ledgerRows(repoAt url: URL) async throws -> [LedgerRow] { ledger }
    public func convergePipeline(repoAt url: URL) async throws -> ConvergePipeline? { converge }

    public func createIssue(remote: RepoRemote, title: String, body: String,
                            labels: [String]) async throws -> Issue {
        Issue(number: (issues.map(\.number).max() ?? 0) + 1, title: title, state: .open,
              labels: labels.map { IssueLabel(name: $0, color: "ededed") },
              body: body, author: "you", createdAt: .distantPast, closedAt: nil,
              milestone: nil, comments: [])
    }
    public func commentIssue(remote: RepoRemote, number: Int, body: String) async throws -> Issue {
        let issue = issues.first { $0.number == number } ?? Issue.sample
        return Issue(number: issue.number, title: issue.title, state: issue.state,
                     labels: issue.labels, body: issue.body, author: issue.author,
                     createdAt: issue.createdAt, closedAt: issue.closedAt,
                     milestone: issue.milestone,
                     comments: issue.comments + [IssueComment(
                        id: issue.comments.count, author: "you", body: body,
                        createdAt: .distantPast)])
    }
    public func setIssueState(remote: RepoRemote, number: Int, closed: Bool) async throws -> Issue {
        let issue = issues.first { $0.number == number } ?? Issue.sample
        return Issue(number: issue.number, title: issue.title,
                     state: closed ? .closed : .open, labels: issue.labels,
                     body: issue.body, author: issue.author, createdAt: issue.createdAt,
                     closedAt: closed ? .distantPast : nil, milestone: issue.milestone,
                     comments: issue.comments)
    }
}
