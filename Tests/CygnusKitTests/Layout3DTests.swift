import Testing
import Foundation
@testable import CygnusKit

@Suite struct Layout3DTests {
    @Test func solvesDeterministicallyOffMain() async {
        let scene = GraphScene.dependencies(from: .sample)
        let a = Layout3D.solveSync(scene, seed: 7, maxIterations: 300)
        let b = Layout3D.solveSync(scene, seed: 7, maxIterations: 300)
        #expect(a.positions.count == 2)
        for (id, position) in a.positions {
            #expect(b.positions[id] == position)
        }

        // Nodes actually use the third dimension (not a flat plane).
        let spread = a.positions.values.map(\.z)
        #expect(spread.min() != spread.max())

        let async_ = await Layout3D.solve(scene, seed: 7)
        #expect(async_.positions.count == 2)
    }

    @Test func emptySceneYieldsEmptyFrame() {
        let frame = Layout3D.solveSync(GraphScene(nodes: [], edges: []),
                                       seed: 1, maxIterations: 10)
        #expect(frame.positions.isEmpty)
    }
}
