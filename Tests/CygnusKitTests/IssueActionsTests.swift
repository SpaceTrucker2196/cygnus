import Testing
import Foundation
@testable import CygnusKit

// Issue write actions through the GitHub provider: the exact gh
// invocations, number parsing, and the re-fetch that returns the
// updated issue.

struct IssueActionsTests {
    let remote = RepoRemote(owner: "SpaceTrucker2196", name: "cygnus")

    private func issueJSON(number: Int, state: String, title: String) -> String {
        """
        {"number":\(number),"title":"\(title)","state":"\(state)","labels":[],
         "body":"b","author":{"login":"you"},"createdAt":"2026-07-25T00:00:00Z",
         "closedAt":null,"milestone":null,"comments":[]}
        """
    }

    @Test func createIssuePassesLabelsAndReFetches() async throws {
        let tooling = FixtureTooling()
        tooling.stub(.gh, argsPrefix: ["issue", "create"],
                     stdout: "https://github.com/SpaceTrucker2196/cygnus/issues/57\n")
        tooling.stub(.gh, argsPrefix: ["issue", "view", "57"],
                     stdout: issueJSON(number: 57, state: "OPEN", title: "Ship it"))
        let provider = GitHubFactoryProvider(tooling: tooling)

        let issue = try await provider.createIssue(
            remote: remote, title: "Ship it", body: "goal", labels: ["production-order"])
        #expect(issue.number == 57)
        #expect(issue.state == .open)
        #expect(tooling.invoked(.gh, argsPrefix: ["issue", "create", "--repo", remote.slug]))
        // The label reached the CLI.
        let create = tooling.invocations.first { $0.arguments.starts(with: ["issue", "create"]) }
        #expect(create?.arguments.contains("production-order") == true)
    }

    @Test func closeAndReopenHitTheRightSubcommands() async throws {
        let tooling = FixtureTooling()
        tooling.stub(.gh, argsPrefix: ["issue", "close", "12"], stdout: "")
        tooling.stub(.gh, argsPrefix: ["issue", "view", "12"],
                     stdout: issueJSON(number: 12, state: "CLOSED", title: "Done"))
        let provider = GitHubFactoryProvider(tooling: tooling)

        let closed = try await provider.setIssueState(remote: remote, number: 12, closed: true)
        #expect(closed.state == .closed)
        #expect(tooling.invoked(.gh, argsPrefix: ["issue", "close", "12"]))
    }

    @Test func commentReFetchesWithNewComment() async throws {
        let tooling = FixtureTooling()
        tooling.stub(.gh, argsPrefix: ["issue", "comment", "3"], stdout: "")
        tooling.stub(.gh, argsPrefix: ["issue", "view", "3"], stdout: """
            {"number":3,"title":"t","state":"OPEN","labels":[],"body":"b",
             "author":{"login":"you"},"createdAt":"2026-07-25T00:00:00Z","closedAt":null,
             "milestone":null,"comments":[{"author":{"login":"you"},"body":"looks good",
             "createdAt":"2026-07-25T00:00:00Z"}]}
            """)
        let provider = GitHubFactoryProvider(tooling: tooling)

        let issue = try await provider.commentIssue(remote: remote, number: 3, body: "looks good")
        #expect(issue.comments.map(\.body) == ["looks good"])
        let comment = tooling.invocations.first { $0.arguments.starts(with: ["issue", "comment"]) }
        #expect(comment?.arguments.contains("looks good") == true)
    }

    @Test func parsesIssueNumberFromCreateURL() {
        #expect(GitHubFactoryProvider.issueNumber(
            fromURL: "https://github.com/o/r/issues/142\n") == 142)
        #expect(GitHubFactoryProvider.issueNumber(fromURL: "no url here") == nil)
    }
}
