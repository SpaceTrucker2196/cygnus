import Testing
import Foundation
@testable import CygnusKit

// How much of a repository the compiler-resolved reference data
// reaches. Reported as a lower bound, because "no references either
// way" cannot distinguish a file the index never saw from one that is
// genuinely unconnected.

@Suite struct ReferenceCoverageTests {
    private func file(_ name: String) -> GraphSnapshot.Node {
        GraphSnapshot.Node(id: "phys:file:r/\(name)", kind: "core:file",
                           label: name, path: "Sources/\(name)")
    }

    private func declares(_ name: String) -> GraphSnapshot.Edge {
        GraphSnapshot.Edge(from: "phys:file:r/\(name)", to: "decl:\(name)",
                           kind: "core:declares")
    }

    private func references(_ from: String, _ to: String) -> GraphSnapshot.Edge {
        GraphSnapshot.Edge(from: "phys:file:r/\(from)", to: "phys:file:r/\(to)",
                           kind: "core:references")
    }

    @Test func countsFilesTheIndexDemonstrablySaw() {
        let snapshot = GraphSnapshot(
            nodes: ["A.swift", "B.swift", "C.swift"].map(file),
            edges: [declares("A.swift"), declares("B.swift"), declares("C.swift"),
                    references("A.swift", "B.swift")])
        let coverage = GraphScene.referenceCoverage(from: snapshot)
        // A and B are provably covered; C is ambiguous and therefore
        // not counted.
        #expect(coverage.covered == 2)
        #expect(coverage.total == 3)
        #expect(coverage.isComplete == false)
    }

    @Test func aRepoWithNoEnrichmentReportsNone() {
        let snapshot = GraphSnapshot(
            nodes: [file("A.swift")], edges: [declares("A.swift")])
        let coverage = GraphScene.referenceCoverage(from: snapshot)
        #expect(coverage.covered == 0)
        #expect(coverage.ratio == 0)
    }

    /// Non-source files are not part of the denominator — a README
    /// missing from the index is not a coverage gap.
    @Test func onlyDeclaringFilesCount() {
        let snapshot = GraphSnapshot(
            nodes: [file("A.swift"), file("README.md")],
            edges: [declares("A.swift"), references("A.swift", "A.swift")])
        #expect(GraphScene.referenceCoverage(from: snapshot).total == 1)
    }

    @Test func noSourceFilesMeansNoRatioRatherThanZero() {
        let coverage = GraphScene.referenceCoverage(from: GraphSnapshot(nodes: [], edges: []))
        #expect(coverage.ratio == nil)
        // Vacuously complete, and the nil ratio is what stops a view
        // from announcing "0% covered" for an unanalyzed repo.
        #expect(coverage.isComplete)
    }

    @Test func fullCoverageIsReportedAsComplete() {
        let snapshot = GraphSnapshot(
            nodes: ["A.swift", "B.swift"].map(file),
            edges: [declares("A.swift"), declares("B.swift"),
                    references("A.swift", "B.swift")])
        let coverage = GraphScene.referenceCoverage(from: snapshot)
        #expect(coverage.isComplete)
        #expect(coverage.ratio == 1)
    }
}
