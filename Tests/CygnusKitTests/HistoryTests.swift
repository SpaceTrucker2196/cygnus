import Testing
import Foundation
@testable import CygnusKit

// Revision history surfaced to the app: deltas between two commits,
// and metric series across them. The engine stored this all along.

@Suite struct HistoryTests {
    private func file(_ name: String) -> GraphSnapshot.Node {
        GraphSnapshot.Node(id: "phys:file:r/\(name)", kind: "core:file",
                           label: name, path: "Sources/\(name)")
    }

    private func declares(_ from: String, _ to: String) -> GraphSnapshot.Edge {
        GraphSnapshot.Edge(from: "phys:file:r/\(from)", to: "decl:\(to)",
                           kind: "core:declares")
    }

    private func references(_ from: String, _ to: String) -> GraphSnapshot.Edge {
        GraphSnapshot.Edge(from: "phys:file:r/\(from)", to: "phys:file:r/\(to)",
                           kind: "core:references")
    }

    private func revision(_ id: Int64) -> GraphRevision {
        GraphRevision(id: id, createdAt: Date(timeIntervalSince1970: Double(id) * 86_400),
                      note: "r\(id)")
    }

    /// Two revisions: B.swift arrives, C.swift leaves.
    private var engine: FixtureGraphEngine {
        let before = GraphSnapshot(
            nodes: [file("A.swift"), file("C.swift")],
            edges: [declares("A.swift", "A"), declares("C.swift", "C")])
        let after = GraphSnapshot(
            nodes: [file("A.swift"), file("B.swift")],
            edges: [declares("A.swift", "A"), declares("B.swift", "B"),
                    references("A.swift", "B.swift")])
        return FixtureGraphEngine(
            snapshot: after,
            history: [revision(1), revision(2)],
            snapshotsByRevision: [1: before, 2: after])
    }

    @Test func deltaReportsWhatArrivedAndWhatLeft() async throws {
        let delta = try await engine.delta(repoAt: URL(fileURLWithPath: "/tmp/r"),
                                           from: 1, to: 2)
        #expect(delta.addedNodes == ["phys:file:r/B.swift"])
        #expect(delta.removedNodes == ["phys:file:r/C.swift"])
        #expect(!delta.isEmpty)
    }

    @Test func anEmptyDeltaIsEmpty() async throws {
        let delta = try await engine.delta(repoAt: URL(fileURLWithPath: "/tmp/r"),
                                           from: 2, to: 2)
        #expect(delta.isEmpty)
        #expect(RevisionDelta().isEmpty)
    }

    @Test func historicalSnapshotsDifferFromCurrent() async throws {
        let url = URL(fileURLWithPath: "/tmp/r")
        let old = try await engine.snapshot(repoAt: url, asOf: 1)
        #expect(old.nodes.contains { $0.label == "C.swift" })
        #expect(!old.nodes.contains { $0.label == "B.swift" })
    }

    // MARK: - Trends

    @Test func seriesTracksAMetricAcrossRevisions() async throws {
        let url = URL(fileURLWithPath: "/tmp/r")
        var projected: [(revision: GraphRevision, snapshot: GraphSnapshot)] = []
        for id in [Int64(1), 2] {
            projected.append((revision(id),
                              try await engine.snapshot(repoAt: url, asOf: id)))
        }
        let points = GraphTrend.series(.nodes, over: projected)
        #expect(points.map(\.revision) == [1, 2])
        // Both revisions chart two declaring files; the shape is what
        // matters, and it is read off real projections.
        #expect(points.allSatisfy { $0.value == 2 })
    }

    /// Unconnected nodes are the graph's "forgotten and lost" code, so
    /// the count must mean exactly that.
    @Test func orphansCountNodesWiredToNothing() {
        let scene = GraphScene.dependencies(from: GraphSnapshot(
            nodes: [file("Wired.swift"), file("Lonely.swift"), file("Target.swift")],
            edges: [declares("Wired.swift", "W"), declares("Lonely.swift", "L"),
                    declares("Target.swift", "T"),
                    references("Wired.swift", "Target.swift")]))
        #expect(GraphMetric.orphans.value(in: scene) == 1)
        #expect(GraphMetric.nodes.value(in: scene) == 3)
    }

    @Test func metricsDeclareWhetherRisingIsBad() {
        #expect(GraphMetric.cycles.risingIsGood == false)
        #expect(GraphMetric.orphans.risingIsGood == false)
        // Growth alone is neither good nor bad, and must not be
        // colored as if it were.
        #expect(GraphMetric.nodes.risingIsGood == nil)
    }

    /// A fixture without canned history reports none rather than
    /// inventing a plausible one.
    @Test func aFixtureWithoutHistoryHasNone() async throws {
        let bare = FixtureGraphEngine()
        let url = URL(fileURLWithPath: "/tmp/r")
        #expect(try await bare.revisions(repoAt: url).isEmpty)
        #expect(try await bare.delta(repoAt: url, from: 1, to: 2).isEmpty)
    }
}
