import Testing
import Foundation
@testable import CygnusProviders

// Authorship parsing. Pure text in, facts out — no repository needed,
// which is the point of keeping the parse separate from the process.

@Suite struct GitHistoryTests {
    private func log(_ records: [(String, String, String, String, [String])]) -> String {
        records.map { sha, name, email, date, paths in
            let header = [sha, name, email, date].joined(separator: GitHistory.fieldSeparator)
            return GitHistory.recordSeparator + header + "\n" + paths.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    @Test func parsesCommitsAndTheirPaths() {
        let commits = GitHistory.parse(log([
            ("abc123", "Jeff Kunzelman", "jeff@river.io", "2026-07-30T10:00:00Z",
             ["Sources/App.swift", "Tests/AppTests.swift"]),
            ("def456", "Someone Else", "else@example.com", "2026-07-29T09:00:00Z",
             ["README.md"]),
        ]))

        #expect(commits.count == 2)
        #expect(commits[0].sha == "abc123")
        #expect(commits[0].authorEmail == "jeff@river.io")
        #expect(commits[0].paths == ["Sources/App.swift", "Tests/AppTests.swift"])
        #expect(commits[1].paths == ["README.md"])
        #expect(commits[0].date > commits[1].date)
    }

    /// A commit that touched nothing tracked (an empty commit) still
    /// parses rather than swallowing the commits after it.
    @Test func handlesCommitsWithNoPaths() {
        let commits = GitHistory.parse(log([
            ("aaa", "A", "a@x.com", "2026-07-30T10:00:00Z", []),
            ("bbb", "B", "b@x.com", "2026-07-30T11:00:00Z", ["file.swift"]),
        ]))
        #expect(commits.count == 2)
        #expect(commits[0].paths.isEmpty)
        #expect(commits[1].paths == ["file.swift"])
    }

    @Test func emptyOutputIsNoCommitsRatherThanAnError() {
        #expect(GitHistory.parse("").isEmpty)
        #expect(GitHistory.parse("\n\n").isEmpty)
    }

    /// Identity is the address: the same person commits under several
    /// display names, and merging them by name would merge the wrong
    /// people together.
    @Test func identityPrefersTheAddressAndIsCaseInsensitive() {
        #expect(GitHistory.identity(email: "Jeff@River.IO", name: "Jeff") == "jeff@river.io")
        #expect(GitHistory.identity(email: "  ", name: "No Address") == "No Address")
    }

    /// A repository is required; absence of git is not an error.
    @Test func nonRepositoryYieldsNoHistory() {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-nogit-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(GitHistory.commits(of: empty).isEmpty)
    }
}
