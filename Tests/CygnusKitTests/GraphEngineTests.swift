import Testing
import Foundation
@testable import CygnusKit

@Suite struct GraphEngineTests {
    @Test func fixtureEngineStreamsPhasesThenSnapshot() async throws {
        let engine = FixtureGraphEngine()
        var events: [AnalysisEvent] = []
        for try await event in engine.analyze(repoAt: URL(fileURLWithPath: "/dev/null")) {
            events.append(event)
        }
        guard case .finished(let snapshot) = events.last else {
            Issue.record("expected .finished as the final event")
            return
        }
        #expect(snapshot == .sample)
        #expect(snapshot.nodes.count == 3)
        #expect(snapshot.edges.count == 3)
    }
}
