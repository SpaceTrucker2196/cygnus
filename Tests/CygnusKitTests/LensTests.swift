import Testing
import Foundation
@testable import CygnusKit

// The scoped-question lenses: depth-limited focus, path tracing, and
// naming-versus-structure disagreement. All three narrow the graph to
// answer one question instead of drawing everything.

@Suite struct LensTests {
    private func file(_ path: String) -> GraphSnapshot.Node {
        GraphSnapshot.Node(id: "phys:file:r/\(path)", kind: "core:file",
                           label: String(path.split(separator: "/").last ?? ""),
                           path: path)
    }

    private func edge(_ from: String, _ to: String) -> GraphSnapshot.Edge {
        GraphSnapshot.Edge(from: "phys:file:r/\(from)", to: "phys:file:r/\(to)",
                           kind: "core:references")
    }

    private func id(_ path: String) -> String { "phys:file:r/\(path)" }

    /// A → B → C → D, plus an unconnected island.
    private var chain: GraphSnapshot {
        GraphSnapshot(
            nodes: ["A.swift", "B.swift", "C.swift", "D.swift", "Island.swift"].map(file),
            edges: [edge("A.swift", "B.swift"),
                    edge("B.swift", "C.swift"),
                    edge("C.swift", "D.swift")])
    }

    // MARK: - Depth-limited neighborhood

    @Test func depthOneIsTheImmediateBlastRadius() {
        let index = SnapshotIndex(chain)
        #expect(index.neighborhood(of: id("B.swift")) ==
                Set([id("A.swift"), id("B.swift"), id("C.swift")]))
    }

    @Test func depthTwoReachesTwoHopsInEitherDirection() {
        let index = SnapshotIndex(chain)
        let two = index.neighborhood(of: id("B.swift"), depth: 2)
        #expect(two == Set(["A.swift", "B.swift", "C.swift", "D.swift"].map(id)))
        // Still bounded — the island never joins.
        #expect(!two.contains(id("Island.swift")))
    }

    @Test func nilDepthIsTheWholeReachableSet() {
        let index = SnapshotIndex(chain)
        #expect(index.neighborhood(of: id("A.swift"), depth: nil) ==
                Set(["A.swift", "B.swift", "C.swift", "D.swift"].map(id)))
    }

    /// A cycle must terminate the sweep rather than revisit forever.
    @Test func cyclesTerminate() {
        let snapshot = GraphSnapshot(
            nodes: ["A.swift", "B.swift", "C.swift"].map(file),
            edges: [edge("A.swift", "B.swift"), edge("B.swift", "C.swift"),
                    edge("C.swift", "A.swift")])
        let index = SnapshotIndex(snapshot)
        #expect(index.neighborhood(of: id("A.swift"), depth: nil).count == 3)
    }

    @Test func anUnknownNodeIsItsOwnNeighborhood() {
        #expect(SnapshotIndex(chain).neighborhood(of: "nope", depth: 3) == ["nope"])
    }

    // MARK: - Path tracing

    @Test func tracesTheRouteBetweenTwoNodes() {
        let trace = GraphScene(nodes: chain.nodes, edges: chain.edges)
            .paths(from: id("A.swift"), to: id("D.swift"))
        #expect(trace.length == 3)
        #expect(trace.nodes == Set(["A.swift", "B.swift", "C.swift", "D.swift"].map(id)))
        #expect(trace.edges.count == 3)
    }

    /// Equal-length alternates both survive; a longer detour does not.
    @Test func keepsEqualLengthAlternatesAndDropsDetours() {
        let snapshot = GraphSnapshot(
            nodes: ["A.swift", "L.swift", "R.swift", "Z.swift", "Long1.swift", "Long2.swift"]
                .map(file),
            edges: [edge("A.swift", "L.swift"), edge("L.swift", "Z.swift"),
                    edge("A.swift", "R.swift"), edge("R.swift", "Z.swift"),
                    edge("A.swift", "Long1.swift"), edge("Long1.swift", "Long2.swift"),
                    edge("Long2.swift", "Z.swift")])
        let trace = GraphScene(nodes: snapshot.nodes, edges: snapshot.edges)
            .paths(from: id("A.swift"), to: id("Z.swift"))
        #expect(trace.length == 2)
        #expect(trace.nodes == Set(["A.swift", "L.swift", "R.swift", "Z.swift"].map(id)))
        #expect(!trace.nodes.contains(id("Long1.swift")))
    }

    @Test func reportsNoRouteWhenUnreachable() {
        let trace = GraphScene(nodes: chain.nodes, edges: chain.edges)
            .paths(from: id("A.swift"), to: id("Island.swift"))
        #expect(trace.length == nil)
        #expect(!trace.isConnected)
        #expect(trace.edges.isEmpty)
    }

    /// Direction matters — this traces dependency flow, not adjacency.
    @Test func routesAreDirected() {
        let scene = GraphScene(nodes: chain.nodes, edges: chain.edges)
        #expect(scene.paths(from: id("D.swift"), to: id("A.swift")).isConnected == false)
    }

    @Test func aNodeReachesItselfInZeroHops() {
        let trace = GraphScene(nodes: chain.nodes, edges: chain.edges)
            .paths(from: id("A.swift"), to: id("A.swift"))
        #expect(trace.length == 0)
        #expect(trace.edges.isEmpty)
    }

    // MARK: - Naming versus structure

    /// A Service nothing depends on is either misnamed or misplaced.
    /// Two dependencies, so it clears the fan-out threshold and reads
    /// as Entry — a driver wearing a provider's name.
    @Test func flagsAServiceThatNothingDependsOn() {
        let dependencies = [file("App/Helper1.swift"), file("App/Helper2.swift")]
        let snapshot = GraphSnapshot(
            nodes: [file("App/PaymentService.swift")] + dependencies,
            edges: dependencies.map {
                GraphSnapshot.Edge(from: id("App/PaymentService.swift"), to: $0.id,
                                   kind: "core:references")
            })
        let disagreements = GraphScene(nodes: snapshot.nodes, edges: snapshot.edges)
            .roleDisagreements()
        let flagged = disagreements[id("App/PaymentService.swift")]
        #expect(flagged?.named == "Services")
        #expect(flagged?.structural == "Entry")
    }

    /// A Service everything depends on is exactly what the name
    /// claims, so it must not be flagged.
    @Test func doesNotFlagAServiceThatIsDependedUpon() {
        let dependents = (1...3).map { file("App/Client\($0).swift") }
        let snapshot = GraphSnapshot(
            nodes: [file("App/PaymentService.swift")] + dependents,
            edges: dependents.map {
                GraphSnapshot.Edge(from: $0.id, to: id("App/PaymentService.swift"),
                                   kind: "core:references")
            })
        let disagreements = GraphScene(nodes: snapshot.nodes, edges: snapshot.edges)
            .roleDisagreements()
        #expect(disagreements[id("App/PaymentService.swift")] == nil)
    }

    /// Names that make no structural claim are never flagged, however
    /// they sit in the graph.
    @Test func makesNoClaimAboutUnconventionalNames() {
        let snapshot = GraphSnapshot(
            nodes: [file("App/Helpers.swift"), file("Tests/FooTests.swift")],
            edges: [])
        let disagreements = GraphScene(nodes: snapshot.nodes, edges: snapshot.edges)
            .roleDisagreements()
        #expect(disagreements.isEmpty)
    }
}
