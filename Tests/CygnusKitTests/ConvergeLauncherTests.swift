import Testing
import Foundation
@testable import CygnusKit

struct ConvergeLauncherTests {
    @Test func scriptCdsIntoRepoAndRunsConverge() {
        let script = ConvergeLauncher.script(repoPath: "/Users/x/projects/repo", issue: 42)
        #expect(script.contains("cd '/Users/x/projects/repo'"))
        #expect(script.contains("/converge 42"))
        #expect(script.hasPrefix("#!/bin/zsh"))
    }

    @Test func scriptQuotesPathsWithSpacesAndQuotes() {
        let script = ConvergeLauncher.script(repoPath: "/a/it's here/repo", issue: 1)
        // The apostrophe is escaped for single-quoting; the launch is
        // one line, so injection can't break out of the cd.
        #expect(script.contains("cd '/a/it'\\''s here/repo'"))
    }

    @Test func writesExecutableCommandFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-converge-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let launcher = ConvergeLauncher(scriptDirectory: dir)
        let url = try launcher.writeScript(repoPath: "/tmp/repo", issue: 7)

        #expect(url.pathExtension == "command")
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o755)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("/converge 7"))
    }
}
