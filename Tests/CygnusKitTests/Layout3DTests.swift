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

    @Test func normalizationCentersAndBoundsTheCloud() {
        let scene = GraphScene.dependencies(from: .sample)
        let frame = Layout3D.solveSync(scene, seed: 3, maxIterations: 100)
            .normalized(toRadius: 500)

        let centroid = frame.positions.values.reduce(SIMD3<Double>.zero, +)
            / Double(frame.positions.count)
        #expect(abs(centroid.x) < 0.001 && abs(centroid.y) < 0.001 && abs(centroid.z) < 0.001)

        let radii = frame.positions.values.map { ($0 * $0).sum().squareRoot() }
        #expect(abs(radii.max()! - 500) < 0.001)
    }

    @Test func emptySceneYieldsEmptyFrame() {
        let frame = Layout3D.solveSync(GraphScene(nodes: [], edges: []),
                                       seed: 1, maxIterations: 10)
        #expect(frame.positions.isEmpty)
        #expect(frame.settled)
    }

    @Test func framesStreamProgressivelyAndEndSettled() async {
        let scene = GraphScene.dependencies(from: .sample)
        var frames: [LayoutFrame3D] = []
        for await frame in Layout3D.frames(scene) {
            frames.append(frame)
        }
        // Multiple progressive frames, only the last one settled.
        #expect(frames.count > 1)
        #expect(frames.last?.settled == true)
        #expect(frames.dropLast().allSatisfy { !$0.settled })
        #expect(frames.last?.positions.count == scene.nodes.count)
    }

    @Test func iterationBudgetScalesDownForBigGraphs() {
        #expect(Layout3D.iterationBudget(nodeCount: 50) == 300)
        #expect(Layout3D.iterationBudget(nodeCount: 400) == 180)
        #expect(Layout3D.iterationBudget(nodeCount: 2000) == 100)
    }
}
