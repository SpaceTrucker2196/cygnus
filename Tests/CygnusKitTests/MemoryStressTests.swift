import Testing
import Foundation
import CygnusEngine
@testable import CygnusKit

// Gated app-pipeline memory stress: the real WorkspaceStore + engine
// + event pump + partial builder on a live local repo — everything
// the app does except SwiftUI rendering. Run with:
//   CYGNUS_STRESS_REPO=/path/to/repo swift test --filter MemoryStressTests

@MainActor
struct MemoryStressTests {
    nonisolated static var stressRepo: String? {
        ProcessInfo.processInfo.environment["CYGNUS_STRESS_REPO"]
    }

    @Test(.enabled(if: stressRepo != nil))
    func analysisStaysUnderMemoryBudget() async throws {
        let repoPath = Self.stressRepo!
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-stress-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }

        let store = WorkspaceStore(
            engine: WorkspaceGraphEngine(directory: base.appendingPathComponent("engine")),
            persistence: WorkspacePersistence(
                fileURL: base.appendingPathComponent("workspace.json")))
        let repo = RegisteredRepo(displayName: (repoPath as NSString).lastPathComponent,
                                  pathHint: repoPath, bookmark: Data())
        store.testInject(repo: repo)

        let start = MemoryFootprint.currentBytes() ?? 0
        var peak: UInt64 = start
        store.analyze(repo.id)

        let deadline = ContinuousClock.now + .seconds(300)
        while ContinuousClock.now < deadline {
            if let used = MemoryFootprint.currentBytes() { peak = max(peak, used) }
            switch store.states[repo.id] {
            case .ready, .failed, .needsRelink, .idle: break
            default:
                try await Task.sleep(for: .milliseconds(200))
                continue
            }
            break
        }

        let state = store.states[repo.id]
        let peakMB = peak / 1_048_576
        print("STRESS: state=\(String(describing: state).prefix(80)) peakMB=\(peakMB) startMB=\(start / 1_048_576)")

        guard case .ready? = state else {
            Issue.record("analysis did not finish: \(String(describing: state).prefix(200)), peak \(peakMB) MB")
            return
        }
        // The whole pipeline on a real repo must stay far under the
        // 5 GB app budget.
        #expect(peakMB < 2048, "peak \(peakMB) MB")
    }
}
