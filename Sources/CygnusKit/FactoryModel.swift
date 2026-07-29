import Foundation

// Immutable, Sendable projections of a "factory" (a repo run as a
// dark-factory CI system). The providers build these from `gh`/`git`
// output and local markdown; views consume them and never touch the
// tools directly. Each type carries a `.sample` for previews/tests,
// mirroring GraphSnapshot.sample.

/// A GitHub remote parsed from `git remote get-url origin`.
public struct RepoRemote: Sendable, Equatable, Codable {
    public let owner: String
    public let name: String
    public init(owner: String, name: String) { self.owner = owner; self.name = name }
    public var slug: String { "\(owner)/\(name)" }

    /// Parse an origin URL in either form:
    ///   https://github.com/owner/name(.git)
    ///   git@github.com:owner/name(.git)
    public static func parse(originURL: String) -> RepoRemote? {
        let trimmed = originURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "github.com") else { return nil }
        var rest = String(trimmed[range.upperBound...])
        // Drop the separator after github.com (":" for SSH, "/" for HTTPS).
        if let first = rest.first, first == ":" || first == "/" { rest.removeFirst() }
        if rest.hasSuffix(".git") { rest.removeLast(4) }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        return RepoRemote(owner: parts[0], name: parts[1])
    }
}

/// A GitHub issue label. Named `IssueLabel` to avoid colliding with
/// SwiftUI.Label in the view layer.
public struct IssueLabel: Sendable, Equatable, Identifiable, Codable {
    public let name: String
    public let color: String        // 6-hex, no leading '#'
    public init(name: String, color: String) { self.name = name; self.color = color }
    public var id: String { name }
}

public struct Milestone: Sendable, Equatable, Codable {
    public let title: String
    public let number: Int
    public init(title: String, number: Int) { self.title = title; self.number = number }
}

public struct IssueComment: Sendable, Equatable, Identifiable, Codable {
    public let id: Int          // provider-assigned index (gh gives no stable int)
    public let author: String
    public let body: String
    public let createdAt: Date
    public init(id: Int, author: String, body: String, createdAt: Date) {
        self.id = id; self.author = author; self.body = body; self.createdAt = createdAt
    }
}

/// A GitHub issue — a "production order" in dark-factory terms.
public struct Issue: Sendable, Equatable, Identifiable, Codable {
    public enum State: String, Sendable, Codable { case open, closed }

    public let number: Int
    public let title: String
    public let state: State
    public let labels: [IssueLabel]
    public let body: String
    public let author: String
    public let createdAt: Date
    public let closedAt: Date?
    public let milestone: Milestone?
    public let comments: [IssueComment]

    public init(number: Int, title: String, state: State, labels: [IssueLabel],
                body: String, author: String, createdAt: Date, closedAt: Date?,
                milestone: Milestone?, comments: [IssueComment]) {
        self.number = number; self.title = title; self.state = state
        self.labels = labels; self.body = body; self.author = author
        self.createdAt = createdAt; self.closedAt = closedAt
        self.milestone = milestone; self.comments = comments
    }

    public var id: Int { number }
    public var isProductionOrder: Bool { labels.contains { $0.name == "production-order" } }
}

/// A single check run (`gh api .../check-runs`).
public struct CheckRun: Sendable, Equatable {
    public let name: String
    public let status: String            // queued/in_progress/completed
    public let conclusion: String?       // success/failure/… when completed
    public init(name: String, status: String, conclusion: String?) {
        self.name = name; self.status = status; self.conclusion = conclusion
    }
}

/// A GitHub Actions run (`gh run list`).
public struct WorkflowRun: Sendable, Equatable, Identifiable, Codable {
    public let id: Int                   // databaseId
    public let name: String
    public let status: String            // queued/in_progress/completed
    public let conclusion: String?       // success/failure/cancelled/skipped/…
    public let headSha: String
    public let headBranch: String
    public let event: String
    public let createdAt: Date
    public let url: String

    public init(id: Int, name: String, status: String, conclusion: String?,
                headSha: String, headBranch: String, event: String, createdAt: Date, url: String) {
        self.id = id; self.name = name; self.status = status; self.conclusion = conclusion
        self.headSha = headSha; self.headBranch = headBranch; self.event = event
        self.createdAt = createdAt; self.url = url
    }
}

/// A commit on the default branch, with dark-factory markers parsed
/// out of the subject.
public struct CommitInfo: Sendable, Equatable, Identifiable {
    public let sha: String
    public let shortSha: String
    public let subject: String
    public let author: String
    public let date: Date
    public let closesIssues: [Int]       // parsed (closes #N)/(fixes #N)/(resolves #N)
    public let ledgerMarker: Bool        // chore(ledger|metrics): …

    public init(sha: String, shortSha: String, subject: String, author: String, date: Date,
                closesIssues: [Int], ledgerMarker: Bool) {
        self.sha = sha; self.shortSha = shortSha; self.subject = subject
        self.author = author; self.date = date
        self.closesIssues = closesIssues; self.ledgerMarker = ledgerMarker
    }
    public var id: String { sha }
}

/// One step of the converge loop, parsed from `converge.md`.
public struct ConvergeStep: Sendable, Equatable, Identifiable {
    public let index: Int
    public let title: String
    public let detail: String
    public init(index: Int, title: String, detail: String) {
        self.index = index; self.title = title; self.detail = detail
    }
    public var id: Int { index }
}

public struct ConvergePipeline: Sendable, Equatable {
    public let steps: [ConvergeStep]
    public let sourcePath: String        // repo-relative path it was read from
    public init(steps: [ConvergeStep], sourcePath: String) {
        self.steps = steps; self.sourcePath = sourcePath
    }
}

/// A row of `METRICS.md` — one production order through the loop.
public struct MetricsRow: Sendable, Equatable, Identifiable {
    public let issue: Int?
    public let commit: String
    public let date: Date?
    public let convergeIters: Int?
    public let testsAtShip: Int?
    public let shipped: Bool?
    public let notes: String
    public init(issue: Int?, commit: String, date: Date?, convergeIters: Int?,
                testsAtShip: Int?, shipped: Bool?, notes: String) {
        self.issue = issue; self.commit = commit; self.date = date
        self.convergeIters = convergeIters; self.testsAtShip = testsAtShip
        self.shipped = shipped; self.notes = notes
    }
    public var id: String { commit }
}

/// A row of `LEDGER.md` — token cost per commit.
public struct LedgerRow: Sendable, Equatable, Identifiable {
    public let commit: String
    public let date: Date?
    public let model: String
    public let input: Int?
    public let output: Int?
    public let cacheRead: Int?
    public let cacheWrite: Int?
    public let costUSD: Double?
    public let summary: String
    public init(commit: String, date: Date?, model: String, input: Int?, output: Int?,
                cacheRead: Int?, cacheWrite: Int?, costUSD: Double?, summary: String) {
        self.commit = commit; self.date = date; self.model = model
        self.input = input; self.output = output
        self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
        self.costUSD = costUSD; self.summary = summary
    }
    public var id: String { commit }
}

/// What a given repo can actually surface. Recomputed on selection and
/// on manual refresh — never persisted, since it goes stale (the user
/// runs `gh auth login`, adds a workflow, etc.).
public struct FactoryCapabilities: Sendable, Equatable {
    public var remote: RepoRemote?
    public var ghAvailable: Bool
    public var ghAuthenticated: Bool
    public var hasConverge: Bool
    public var convergePath: String?
    public var hasMetrics: Bool
    public var hasLedger: Bool
    public var hasWorkflows: Bool
    public var hasDocs: Bool
    /// Repo-relative paths of fastlane screenshots (capped scan).
    public var screenshots: [String]
    /// The repo's GitHub Pages site, when one is deployed.
    public var pagesURL: String?
    /// Fastlane configuration (lanes, Appfile, CI invocations), when
    /// the repo has a Fastfile.
    public var fastlane: FastlaneInfo?
    /// The CI/build pipeline to visualize — fastlane's flow when a
    /// Fastfile exists, otherwise a Makefile's target graph. Nil when
    /// the repo has neither.
    public var ciFlow: CIFlow?

    public init(remote: RepoRemote? = nil, ghAvailable: Bool = false,
                ghAuthenticated: Bool = false, hasConverge: Bool = false,
                convergePath: String? = nil, hasMetrics: Bool = false,
                hasLedger: Bool = false, hasWorkflows: Bool = false, hasDocs: Bool = false,
                screenshots: [String] = [], pagesURL: String? = nil,
                fastlane: FastlaneInfo? = nil, ciFlow: CIFlow? = nil) {
        self.remote = remote; self.ghAvailable = ghAvailable
        self.ghAuthenticated = ghAuthenticated; self.hasConverge = hasConverge
        self.convergePath = convergePath; self.hasMetrics = hasMetrics
        self.hasLedger = hasLedger; self.hasWorkflows = hasWorkflows; self.hasDocs = hasDocs
        self.screenshots = screenshots; self.pagesURL = pagesURL
        self.fastlane = fastlane; self.ciFlow = ciFlow
    }

    public static let empty = FactoryCapabilities()

    /// GitHub-backed data (issues, runs) is only reachable with all three.
    public var github: Bool { remote != nil && ghAvailable && ghAuthenticated }
}
