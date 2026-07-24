import Testing
import Foundation
@testable import CygnusKit

// End-to-end proof against the live sloth clone using the REAL
// providers (git + gh). Gated behind CYGNUS_E2E_SLOTH=1 and the clone
// existing, so the default `swift test` stays hermetic. Run with:
//   CYGNUS_E2E_SLOTH=1 swift test --filter EndToEndSlothTests

private let slothPath = ("~/projects/sloth" as NSString).expandingTildeInPath
private var e2eEnabled: Bool {
    ProcessInfo.processInfo.environment["CYGNUS_E2E_SLOTH"] == "1"
        && FileManager.default.fileExists(atPath: slothPath)
}

@Suite struct EndToEndSlothTests {
    private var repo: URL { URL(fileURLWithPath: slothPath) }
    private var provider: GitHubFactoryProvider { GitHubFactoryProvider() }

    @Test(.enabled(if: e2eEnabled))
    func detectsRealCapabilities() async {
        let caps = await provider.detectCapabilities(repoAt: repo)
        #expect(caps.remote?.name == "sloth")
        #expect(caps.ghAvailable)
        #expect(caps.hasConverge || caps.hasMetrics)     // sloth has both
        print("E2E caps: remote=\(caps.remote?.slug ?? "nil") gh=\(caps.ghAuthenticated) converge=\(caps.hasConverge) metrics=\(caps.hasMetrics)")
    }

    @Test(.enabled(if: e2eEnabled))
    func listsRealIssuesAndRuns() async throws {
        let remote = RepoRemote(owner: "SpaceTrucker2196", name: "sloth")
        let issues = try await provider.listIssues(remote: remote)
        let runs = try await provider.listRuns(remote: remote, limit: 5)
        #expect(!issues.isEmpty)
        #expect(!runs.isEmpty)
        print("E2E issues: \(issues.count) (orders: \(issues.filter(\.isProductionOrder).count)), runs: \(runs.count), latest: \(runs.first?.name ?? "—")")
    }

    @Test(.enabled(if: e2eEnabled))
    func readsRealConvergeAndCommits() async throws {
        let pipeline = try await provider.convergePipeline(repoAt: repo)
        let commits = try await provider.recentCommits(repoAt: repo, limit: 10)
        #expect((pipeline?.steps.count ?? 0) >= 5)
        #expect(!commits.isEmpty)
        print("E2E converge steps: \(pipeline?.steps.count ?? 0), commits: \(commits.count), closes-refs: \(commits.flatMap(\.closesIssues))")
    }
}
