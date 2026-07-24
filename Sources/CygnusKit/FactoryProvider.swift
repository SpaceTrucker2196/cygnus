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
}
