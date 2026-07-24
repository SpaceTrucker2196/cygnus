import Testing
import Foundation
@testable import CygnusKit

// ToolLocator resolution logic (pure, injected fileExists/shellProbe)
// and the ProcessTooling error surface. The one test that spawns a
// real process is env-gated so the default `swift test` stays hermetic.

@Suite struct ToolLocatorTests {
    @Test func prefersOverrideWhenExecutable() {
        let locator = ToolLocator.resolve(
            overrides: ToolOverrides(gitPath: "/custom/git", ghPath: nil),
            fileExists: { $0 == "/custom/git" || $0 == "/opt/homebrew/bin/gh" },
            shellProbe: { _ in nil })
        #expect(locator.gitPath == "/custom/git")
        #expect(locator.ghPath == "/opt/homebrew/bin/gh")
    }

    @Test func fallsBackToCandidateList() {
        let locator = ToolLocator.resolve(
            fileExists: { $0 == "/usr/bin/git" || $0 == "/opt/homebrew/bin/gh" },
            shellProbe: { _ in nil })
        #expect(locator.gitPath == "/usr/bin/git")
        #expect(locator.ghPath == "/opt/homebrew/bin/gh")
    }

    @Test func ghAbsentWhenNoCandidateExists() {
        let locator = ToolLocator.resolve(
            fileExists: { $0 == "/usr/bin/git" },   // only git present
            shellProbe: { _ in nil })
        #expect(locator.gitPath == "/usr/bin/git")
        #expect(locator.ghPath == nil)
    }

    @Test func usesShellProbeAsLastResort() {
        let locator = ToolLocator.resolve(
            fileExists: { $0 == "/opt/weird/gh" },
            shellProbe: { name in name == "gh" ? "/opt/weird/gh" : nil })
        #expect(locator.ghPath == "/opt/weird/gh")
    }

    @Test func searchDirectoriesIncludeToolDirs() {
        let locator = ToolLocator(gitPath: "/usr/bin/git", ghPath: "/opt/homebrew/bin/gh")
        #expect(locator.searchDirectories.contains("/opt/homebrew/bin"))
        #expect(locator.searchDirectories.contains("/usr/bin"))
    }
}

@Suite struct ProcessToolingTests {
    @Test func throwsToolNotFoundWhenPathMissing() async {
        let tooling = ProcessTooling(locator: ToolLocator(gitPath: nil, ghPath: nil))
        await #expect(throws: ToolingError.toolNotFound(.git)) {
            try await tooling.run(.git, ["status"], workingDirectory: nil, timeout: .seconds(5))
        }
    }

    // Real subprocess sanity — only when a git binary is actually
    // present. Skipped in a bare CI sandbox.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/git")))
    func runsRealGitVersion() async throws {
        let tooling = ProcessTooling(locator: ToolLocator(gitPath: "/usr/bin/git", ghPath: nil))
        let result = try await tooling.run(.git, ["--version"],
                                           workingDirectory: nil, timeout: .seconds(10))
        #expect(result.succeeded)
        #expect(result.stdoutString.contains("git version"))
    }

    @Test func unauthenticatedStderrIsRecognised() {
        #expect(ProcessTooling.looksUnauthenticated("gh auth login required"))
        #expect(ProcessTooling.looksUnauthenticated("HTTP 401: Bad credentials"))
        #expect(!ProcessTooling.looksUnauthenticated("some unrelated error"))
    }
}
