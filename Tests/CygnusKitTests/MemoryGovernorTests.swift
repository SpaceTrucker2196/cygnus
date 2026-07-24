import Testing
import Foundation
@testable import CygnusKit

// The hard memory ceiling: the governor's thresholds and the
// WorkspaceStore gate that refuses to start analysis at the cap.

@MainActor
struct MemoryGovernorTests {
    @Test func criticalWhenUsageMeetsAOneByteLimit() {
        // init() samples the real footprint, which is always far above
        // one byte — a deterministic way to force the critical state.
        let governor = MemoryGovernor(limitBytes: 1)
        #expect(governor.isCritical)
        #expect(governor.isHigh)
        #expect(governor.fraction == 1)
    }

    @Test func headroomUnderAHugeLimit() {
        let governor = MemoryGovernor(limitBytes: 1 << 62)
        #expect(!governor.isCritical)
        #expect(!governor.isHigh)
        #expect(governor.fraction < 1)
        #expect(governor.usedBytes > 0)   // real sample, not a stub
    }

    @Test func runningAnalysisIsCancelledAtTheHardLimit() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-mem-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }

        let store = WorkspaceStore(
            engine: FixtureGraphEngine(),
            persistence: WorkspacePersistence(
                fileURL: base.appendingPathComponent("workspace.json")),
            memory: MemoryGovernor(limitBytes: 1))   // always critical
        let repo = RegisteredRepo(displayName: "r", pathHint: "/tmp/r", bookmark: Data())
        store.testInject(repo: repo)

        // First event lands normally (idle → analyzing); the next event
        // arriving while critical must kill the run, not stream on.
        store.testApply(.phase("extracting"), to: repo.id)
        guard case .analyzing? = store.states[repo.id] else {
            Issue.record("expected analyzing after first event")
            return
        }
        store.testApply(.progress(0.5), to: repo.id)
        guard case .failed(let message)? = store.states[repo.id] else {
            Issue.record("expected cancellation, got \(String(describing: store.states[repo.id]))")
            return
        }
        #expect(message.contains("Stopped"))
    }

    @Test func analyzeRefusesAtTheHardLimit() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-mem-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }

        let store = WorkspaceStore(
            engine: FixtureGraphEngine(),
            persistence: WorkspacePersistence(
                fileURL: base.appendingPathComponent("workspace.json")),
            memory: MemoryGovernor(limitBytes: 1))   // always critical
        let repo = RegisteredRepo(displayName: "r", pathHint: "/tmp/r", bookmark: Data())
        store.testInject(repo: repo)

        store.analyze(repo.id)

        guard case .failed(let message)? = store.states[repo.id] else {
            Issue.record("expected analysis to be refused, got \(String(describing: store.states[repo.id]))")
            return
        }
        #expect(message.contains("Paused"))
    }
}
