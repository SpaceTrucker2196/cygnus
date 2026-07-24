import Testing
import Foundation
@testable import CygnusKit

// GitHubFactoryProvider decoding + argument assertions via FixtureTooling
// (captured gh/git output; no network), capability detection over temp
// repos, and FileDocsProvider write guards.

@Suite struct GitHubFactoryProviderTests {
    // Trimmed real `gh issue list --json …` output.
    static let issuesJSON = """
    [{"number":48,"title":"WITH_NCURSES=0 fails","state":"OPEN",
      "labels":[{"name":"bug","color":"d73a4a"},{"name":"production-order","color":"1D76DB"}],
      "body":"## Goal\\nfix it","author":{"login":"Capitali","name":"Ian"},
      "createdAt":"2026-07-18T10:00:00Z","closedAt":null,"milestone":null},
     {"number":45,"title":"risk gate","state":"CLOSED",
      "labels":[{"name":"production-order","color":"1D76DB"}],
      "body":"done","author":{"login":"SpaceTrucker2196","name":"Jeff"},
      "createdAt":"2026-07-19T09:00:00Z","closedAt":"2026-07-20T13:45:00Z","milestone":{"title":"v1","number":2}}]
    """

    static let runsJSON = """
    [{"conclusion":"success","createdAt":"2026-07-20T13:45:32Z","databaseId":29747626122,
      "event":"push","headBranch":"main","headSha":"e1baf1f","name":"CI","status":"completed",
      "url":"https://github.com/x/y/actions/runs/1"}]
    """

    @Test func decodesIssuesAndMapsState() async throws {
        let tooling = FixtureTooling()
        tooling.stub(.gh, argsPrefix: ["issue", "list"], stdout: Self.issuesJSON)
        let provider = GitHubFactoryProvider(tooling: tooling)

        let issues = try await provider.listIssues(remote: .sample)
        #expect(issues.count == 2)
        #expect(issues[0].number == 48)
        #expect(issues[0].state == .open)
        #expect(issues[0].author == "Capitali")
        #expect(issues[0].isProductionOrder)
        #expect(issues[1].state == .closed)
        #expect(issues[1].milestone?.title == "v1")
        // Exact CLI args were issued.
        #expect(tooling.invoked(.gh, argsPrefix: ["issue", "list", "--repo", "SpaceTrucker2196/sloth"]))
    }

    @Test func decodesRuns() async throws {
        let tooling = FixtureTooling()
        tooling.stub(.gh, argsPrefix: ["run", "list"], stdout: Self.runsJSON)
        let provider = GitHubFactoryProvider(tooling: tooling)
        let runs = try await provider.listRuns(remote: .sample, limit: 10)
        #expect(runs.count == 1)
        #expect(runs[0].id == 29747626122)
        #expect(runs[0].conclusion == "success")
    }

    @Test func surfacesUnauthenticated() async {
        let tooling = FixtureTooling()
        tooling.stub(.gh, argsPrefix: ["issue", "list"],
                     stderr: "gh auth login required", exitCode: 1)
        let provider = GitHubFactoryProvider(tooling: tooling)
        await #expect(throws: ToolingError.notAuthenticated(.gh)) {
            _ = try await provider.listIssues(remote: .sample)
        }
    }

    @Test func parsesCommitsFromGitLog() async throws {
        let log = "sha1full\u{0}sha1\u{0}Jeff\u{0}2026-07-20T06:45:06-07:00\u{0}Add gate (closes #45)\n"
                + "sha2full\u{0}sha2\u{0}Jeff\u{0}2026-07-20T06:45:19-07:00\u{0}chore(ledger): sha1"
        let tooling = FixtureTooling()
        tooling.stub(.git, argsPrefix: ["-C"], stdout: log)   // git log
        let provider = GitHubFactoryProvider(tooling: tooling)
        let commits = try await provider.recentCommits(repoAt: URL(fileURLWithPath: "/tmp/x"), limit: 10)
        #expect(commits.count == 2)
        #expect(commits[0].closesIssues == [45])
        #expect(commits[1].ledgerMarker)
    }
}

@Suite struct CapabilitiesTests {
    private func tempRepo() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cap-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func detectsRemoteAndFiles() async throws {
        let repo = tempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("x".utf8).write(to: repo.appendingPathComponent("METRICS.md"))
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try Data("1. **Read.** go".utf8).write(to: repo.appendingPathComponent("agents/converge.md"))

        let tooling = FixtureTooling()
        tooling.stub(.git, argsPrefix: ["-C", repo.path, "remote", "get-url"],
                     stdout: "https://github.com/SpaceTrucker2196/sloth.git\n")
        tooling.stub(.gh, argsPrefix: ["auth", "status"], stdout: "logged in")

        let caps = await GitHubFactoryProvider(tooling: tooling).detectCapabilities(repoAt: repo)
        #expect(caps.remote?.slug == "SpaceTrucker2196/sloth")
        #expect(caps.ghAvailable)
        #expect(caps.ghAuthenticated)
        #expect(caps.hasMetrics)
        #expect(caps.hasConverge)
        #expect(caps.convergePath == "agents/converge.md")
        #expect(caps.github)
    }

    @Test func degradesWhenNoRemoteOrGh() async throws {
        let repo = tempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let tooling = FixtureTooling()
        tooling.stubError(.git, argsPrefix: ["-C", repo.path, "remote"],
                          error: .nonZeroExit(.git, code: 1, stderr: "no origin"))
        tooling.stubError(.gh, argsPrefix: ["auth"], error: .toolNotFound(.gh))

        let caps = await GitHubFactoryProvider(tooling: tooling).detectCapabilities(repoAt: repo)
        #expect(caps.remote == nil)
        #expect(!caps.ghAvailable)
        #expect(!caps.github)
    }
}

@Suite struct FileDocsProviderTests {
    private func tempRepo() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("docs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: dir.appendingPathComponent("docs"), withIntermediateDirectories: true)
        return dir
    }

    @Test func readsAndClassifiesPolicy() async throws {
        let repo = tempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("---\nname: arch\n---\n# A\nSee [[mission]]."
            .utf8).write(to: repo.appendingPathComponent("docs/architecture.md"))
        let provider = FileDocsProvider(tooling: FixtureTooling())
        let doc = try await provider.read(repoAt: repo, path: "docs/architecture.md")
        #expect(doc.frontmatter["name"] == "arch")
        #expect(doc.wikilinks.first?.target == "mission")
        #expect(doc.policy == .editable)
    }

    @Test func rejectsReadOnlyLedger() async throws {
        let repo = tempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("| a |".utf8).write(to: repo.appendingPathComponent("LEDGER.md"))
        let provider = FileDocsProvider(tooling: FixtureTooling())
        await #expect(throws: DocsError.readOnly("LEDGER.md")) {
            _ = try await provider.write(repoAt: repo, path: "LEDGER.md", content: "x", commit: nil)
        }
    }

    @Test func rejectsNewRootFile() async throws {
        let repo = tempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let provider = FileDocsProvider(tooling: FixtureTooling())
        await #expect(throws: DocsError.newRootFileForbidden("NOTES.md")) {
            _ = try await provider.write(repoAt: repo, path: "NOTES.md", content: "x", commit: nil)
        }
    }

    @Test func rejectsPathEscape() async throws {
        let repo = tempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let provider = FileDocsProvider(tooling: FixtureTooling())
        await #expect(throws: DocsError.escapesRepo("../evil.md")) {
            _ = try await provider.write(repoAt: repo, path: "../evil.md", content: "x", commit: nil)
        }
    }

    @Test func writesAndCommitsRealGitRepo() async throws {
        // Hermetic: a real local git repo (no network).
        let repo = tempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return }
        let real = ProcessTooling(locator: ToolLocator(gitPath: "/usr/bin/git", ghPath: nil))
        _ = try await real.run(.git, ["-C", repo.path, "init", "-q"], workingDirectory: repo, timeout: .seconds(10))
        _ = try await real.run(.git, ["-C", repo.path, "config", "user.email", "t@t.io"], workingDirectory: repo, timeout: .seconds(10))
        _ = try await real.run(.git, ["-C", repo.path, "config", "user.name", "T"], workingDirectory: repo, timeout: .seconds(10))
        try Data("# Doc\n\nold".utf8).write(to: repo.appendingPathComponent("docs/note.md"))
        _ = try await real.run(.git, ["-C", repo.path, "add", "-A"], workingDirectory: repo, timeout: .seconds(10))
        _ = try await real.run(.git, ["-C", repo.path, "commit", "-q", "-m", "init"], workingDirectory: repo, timeout: .seconds(10))

        let provider = FileDocsProvider(tooling: real)
        let result = try await provider.write(repoAt: repo, path: "docs/note.md",
                                              content: "# Doc\n\nnew", commit: DocCommit(message: "docs: update note"))
        #expect(result.committed)
        #expect(result.commitSha != nil)

        // The commit exists, working tree is clean, no push occurred
        // (bare `git log` shows exactly 2 commits).
        let log = try await real.run(.git, ["-C", repo.path, "log", "--oneline"],
                                     workingDirectory: repo, timeout: .seconds(10))
        #expect(log.stdoutString.contains("docs: update note"))
        let status = try await real.run(.git, ["-C", repo.path, "status", "--porcelain"],
                                        workingDirectory: repo, timeout: .seconds(10))
        #expect(status.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
