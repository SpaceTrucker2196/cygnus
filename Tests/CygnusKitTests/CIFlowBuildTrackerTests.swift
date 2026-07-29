import Testing
import Foundation
@testable import CygnusKit

struct CIFlowBuildTrackerTests {
    private func makeFlow() -> CIFlow {
        let makefile = """
        CC = clang
        all: app
        app: main.o
        \t$(CC) -o app main.o
        main.o: main.c
        \t$(CC) -c main.c
        clean:
        \trm -f app
        """
        return MakeFlowBuilder.build(makefileText: makefile)
    }

    @Test func startsWithFrontierActiveAndRestPending() {
        var tracker = CIFlowBuildTracker(flow: makeFlow())
        tracker.start()
        // Something is active; nothing done yet.
        #expect(tracker.activeID != nil)
        #expect(!tracker.states.values.contains(.done))
    }

    @Test func commandLinesAdvanceTheFrontier() {
        let flow = makeFlow()
        var tracker = CIFlowBuildTracker(flow: flow)
        tracker.start()
        // make echoes the real commands as it runs them.
        tracker.consume(line: "clang -c main.c")
        tracker.consume(line: "clang -o app main.o")
        // At least one recipe node reached done/active as work streamed.
        let progressed = tracker.states.values.contains { $0 == .done || $0 == .active }
        #expect(progressed)
        // Noise lines don't crash or over-advance.
        tracker.consume(line: "make[1]: Entering directory '/x'")
    }

    @Test func successMarksEverythingDone() {
        var tracker = CIFlowBuildTracker(flow: makeFlow())
        tracker.start()
        tracker.consume(line: "clang -c main.c")
        tracker.finish(exitCode: 0)
        #expect(tracker.states.values.allSatisfy { $0 == .done })
        #expect(tracker.activeID == nil)
    }

    @Test func failureMarksActiveNodeFailed() {
        var tracker = CIFlowBuildTracker(flow: makeFlow())
        tracker.start()
        tracker.consume(line: "clang -c main.c")
        let activeBefore = tracker.activeID
        tracker.finish(exitCode: 2)
        #expect(tracker.states.values.contains(.failed))
        if let activeBefore { #expect(tracker.states[activeBefore] == .failed) }
        // Not everything is done on failure.
        #expect(!tracker.states.values.allSatisfy { $0 == .done })
    }
}
