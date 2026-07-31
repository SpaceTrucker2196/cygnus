import Testing
import Foundation
@testable import CygnusKit

// Ownership as a lens over the dependency graph. Three states, and
// the two that are not "someone owns this" are the interesting ones.

@Suite struct OwnershipSceneTests {
    private func file(_ name: String) -> GraphSnapshot.Node {
        GraphSnapshot.Node(id: "phys:file:r/\(name)", kind: "core:file",
                           label: name, path: "Sources/\(name)")
    }

    private func person(_ name: String) -> GraphSnapshot.Node {
        GraphSnapshot.Node(id: "person:\(name.lowercased())@x.com",
                           kind: "core:person", label: name)
    }

    private func edge(_ file: String, _ person: String, _ kind: String,
                      weight: Int = 1) -> GraphSnapshot.Edge {
        GraphSnapshot.Edge(from: "phys:file:r/\(file)",
                           to: "person:\(person.lowercased())@x.com",
                           kind: kind, weight: weight)
    }

    /// Owned, shared, and untouched — all three in one snapshot.
    private var snapshot: GraphSnapshot {
        GraphSnapshot(
            nodes: [file("Owned.swift"), file("Shared.swift"), file("Untouched.swift"),
                    person("Ada"), person("Grace")],
            edges: [edge("Owned.swift", "Ada", "core:authoredBy", weight: 9),
                    edge("Owned.swift", "Ada", "core:ownedBy"),
                    edge("Shared.swift", "Ada", "core:authoredBy", weight: 3),
                    edge("Shared.swift", "Grace", "core:authoredBy", weight: 3)])
    }

    @Test func classifiesOwnedSharedAndUntouched() {
        let owners = GraphScene.owners(from: snapshot)
        #expect(owners["phys:file:r/Owned.swift"] == "Ada")
        #expect(owners["phys:file:r/Shared.swift"] == "Shared")
        #expect(owners["phys:file:r/Untouched.swift"] == "Unowned")
    }

    /// The gap set is the seam the book points at: worked on by
    /// several people, owned by none.
    @Test func gapsAreFilesWithAuthorsButNoOwner() {
        #expect(GraphScene.responsibilityGaps(from: snapshot)
                == ["phys:file:r/Shared.swift"])
    }

    /// People are not files and must not be given an ownership
    /// cluster of their own.
    @Test func onlyFilesAreClassified() {
        let owners = GraphScene.owners(from: snapshot)
        #expect(owners["person:ada@x.com"] == nil)
        #expect(owners.count == 3)
    }

    /// A repository analyzed before ownership existed, or one without
    /// git, reports everything unowned rather than crashing or
    /// inventing owners.
    @Test func aSnapshotWithNoOwnershipFactsIsAllUnowned() {
        let bare = GraphSnapshot(nodes: [file("A.swift")], edges: [])
        #expect(GraphScene.owners(from: bare) == ["phys:file:r/A.swift": "Unowned"])
        #expect(GraphScene.responsibilityGaps(from: bare).isEmpty)
    }

    /// Commit counts ride in as edge weight, so a renderer can size
    /// by them without a second lookup.
    @Test func commitCountsArriveAsEdgeWeight() {
        let authored = snapshot.edges.filter { $0.kind == "core:authoredBy" }
        #expect(authored.first { $0.from.hasSuffix("Owned.swift") }?.weight == 9)
    }
}
