import Testing
import Foundation
@testable import CygnusKit

// Hammer the subprocess runner with many fast-exiting children — the
// exact shape (a child that exits before we finish wiring up) that
// raced the pipe teardown and corrupted the heap. Run under
// --sanitize=thread to catch any residual race in ProcessRunner.
struct ProcessToolingStressTests {
    @Test func manyFastConcurrentProcessesCompleteCleanly() async throws {
        // /usr/bin/git resolves on every dev machine; --version exits
        // immediately, maximizing the terminate-vs-drain window.
        let locator = ToolLocator(gitPath: "/usr/bin/git", ghPath: nil)
        let tooling = ProcessTooling(locator: locator)
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<80 {
                group.addTask {
                    let r = try await tooling.run(.git, ["--version"],
                                                  workingDirectory: nil, timeout: .seconds(10))
                    return r.succeeded && r.stdoutString.contains("git")
                }
            }
            var ok = 0
            for try await result in group where result { ok += 1 }
            #expect(ok == 80)
        }
    }
}
