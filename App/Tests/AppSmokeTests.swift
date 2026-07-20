import Testing
import CygnusKit

@Suite struct AppSmokeTests {
    @Test func fixtureSnapshotIsRenderable() {
        let snapshot = GraphSnapshot.sample
        #expect(!snapshot.nodes.isEmpty)
        // Every edge endpoint resolves to a node — renderers rely on it.
        let ids = Set(snapshot.nodes.map(\.id))
        for edge in snapshot.edges {
            #expect(ids.contains(edge.from))
            #expect(ids.contains(edge.to))
        }
    }
}
