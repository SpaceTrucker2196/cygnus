import Foundation

// Deterministic sample values for previews and tests — the factory
// analogue of GraphSnapshot.sample. Dates are fixed epoch offsets so
// nothing depends on the wall clock.

extension Date {
    fileprivate static func fixed(_ iso: String) -> Date {
        FactoryParse.date(iso) ?? Date(timeIntervalSince1970: 0)
    }
}

extension RepoRemote {
    public static let sample = RepoRemote(owner: "SpaceTrucker2196", name: "sloth")
}

extension Issue {
    public static let sample = Issue(
        number: 48,
        title: "make WITH_NCURSES=0 fails to compile — src/tui.c uses ncurses symbols",
        state: .open,
        labels: [IssueLabel(name: "bug", color: "d73a4a"),
                 IssueLabel(name: "production-order", color: "1D76DB")],
        body: """
        The Makefile advertises a TUI-less build (`WITH_NCURSES=0`) but it
        doesn't compile.

        ## Goal
        Make `make WITH_NCURSES=0` build clean.

        ## Acceptance criteria
        - [ ] Headless build compiles
        - [ ] `make test` stays green
        - [x] Repro documented

        ## Autonomy level
        decides-and-flags
        """,
        author: "Capitali",
        createdAt: .fixed("2026-07-18T10:00:00Z"),
        closedAt: nil,
        milestone: nil,
        comments: [IssueComment(id: 0, author: "Jeff Kunzelman",
                                body: "Confirmed on Ubuntu 26.04. See #35.",
                                createdAt: .fixed("2026-07-19T12:00:00Z"))])

    public static let sampleClosed = Issue(
        number: 45,
        title: "Factory: risk-proportionate autonomy gate for agent tasks",
        state: .closed,
        labels: [IssueLabel(name: "production-order", color: "1D76DB")],
        body: "## Goal\nAdd a risk gate.\n\n## Acceptance criteria\n- [x] risk_score.sh lands",
        author: "SpaceTrucker2196",
        createdAt: .fixed("2026-07-19T09:00:00Z"),
        closedAt: .fixed("2026-07-20T13:45:00Z"),
        milestone: nil,
        comments: [])

    public static let samples = [Issue.sample, .sampleClosed]
}

extension WorkflowRun {
    public static let sample = WorkflowRun(
        id: 29747626122, name: "CI", status: "completed", conclusion: "success",
        headSha: "e1baf1f7dd016157b91580021251adbd78353c3d", headBranch: "main",
        event: "push", createdAt: .fixed("2026-07-20T13:45:32Z"),
        url: "https://github.com/SpaceTrucker2196/sloth/actions/runs/29747626122")

    public static let sampleFailed = WorkflowRun(
        id: 29747000000, name: "code-review", status: "completed", conclusion: "failure",
        headSha: "a688b2524353bf7f84f26422c93d8cba39b1a2d8", headBranch: "main",
        event: "push", createdAt: .fixed("2026-07-20T13:40:00Z"),
        url: "https://github.com/SpaceTrucker2196/sloth/actions/runs/29747000000")

    public static let samples = [WorkflowRun.sample, .sampleFailed]
}

extension CommitInfo {
    public static let sample = CommitInfo(
        sha: "a688b2524353bf7f84f26422c93d8cba39b1a2d8", shortSha: "a688b25",
        subject: "Add risk-proportionate autonomy gate to the converge loop (closes #45)",
        author: "Jeff Kunzelman", date: .fixed("2026-07-20T13:45:06Z"),
        closesIssues: [45], ledgerMarker: false)

    public static let samples = [
        CommitInfo.sample,
        CommitInfo(sha: "c0d36cdc704fb4544fcd10833d7ea796970ed72e", shortSha: "c0d36cd",
                   subject: "chore(metrics): #45 converge row", author: "Jeff Kunzelman",
                   date: .fixed("2026-07-20T13:45:19Z"), closesIssues: [], ledgerMarker: true),
    ]
}

extension ConvergePipeline {
    public static let sample = ConvergePipeline(steps: [
        ConvergeStep(index: 1, title: "Read the order", detail: "Parse goal, acceptance criteria."),
        ConvergeStep(index: 2, title: "Plan", detail: "Map against AGENTS.md."),
        ConvergeStep(index: 3, title: "Generate", detail: "Implement per recipes."),
        ConvergeStep(index: 4, title: "Converge", detail: "Run make test until green."),
        ConvergeStep(index: 5, title: "Self-review", detail: "Diff against invariants."),
        ConvergeStep(index: 6, title: "Risk gate", detail: "Run risk_score.sh."),
        ConvergeStep(index: 7, title: "Ship", detail: "Commit, closes #N."),
        ConvergeStep(index: 8, title: "Instrument", detail: "Append METRICS + LEDGER rows."),
        ConvergeStep(index: 9, title: "Report", detail: "Comment on the issue."),
    ], sourcePath: "agents/converge.md")
}

extension MetricsRow {
    public static let samples = [
        MetricsRow(issue: 45, commit: "a688b25", date: .fixed("2026-07-20"),
                   convergeIters: 1, testsAtShip: 3721, shipped: true,
                   notes: "risk gate; suite green on first converge"),
        MetricsRow(issue: 41, commit: "8f0aa21", date: .fixed("2026-07-19"),
                   convergeIters: 2, testsAtShip: 3702, shipped: true,
                   notes: "scan_entry false-positive fix"),
    ]
}

extension LedgerRow {
    public static let samples = [
        LedgerRow(commit: "a688b25", date: .fixed("2026-07-20T13:45:09Z"),
                  model: "claude-opus-4-8", input: 44915, output: 33099,
                  cacheRead: 4277477, cacheWrite: 201690, costUSD: 5.2077,
                  summary: "Add risk-proportionate autonomy gate"),
        LedgerRow(commit: "8f0aa21", date: .fixed("2026-07-19T22:10:00Z"),
                  model: "claude-opus-4-8", input: 12240, output: 18646,
                  cacheRead: 4068452, cacheWrite: 36392, costUSD: 8.59,
                  summary: "scan_entry false-positive fix"),
    ]
}

extension FactoryCapabilities {
    public static let sample = FactoryCapabilities(
        remote: .sample, ghAvailable: true, ghAuthenticated: true,
        hasConverge: true, convergePath: "agents/converge.md",
        hasMetrics: true, hasLedger: true, hasWorkflows: true, hasDocs: true)
}
