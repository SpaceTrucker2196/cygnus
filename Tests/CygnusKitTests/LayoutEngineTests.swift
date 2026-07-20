import Testing
import Foundation
@testable import CygnusKit

@Suite struct LayoutEngineTests {
    func finalFrame(seed: UInt64 = 0xC516) -> LayoutFrame {
        let scene = GraphScene.dependencies(from: .sample)
        var final = LayoutFrame.empty
        LayoutEngine.run(scene: scene, seed: seed, maxIterations: 300, emitEvery: 5) { frame in
            final = frame
            return true
        }
        return final
    }

    @Test func dependencySceneExtractsImportEndpoints() {
        let scene = GraphScene.dependencies(from: .sample)
        #expect(Set(scene.nodes.map(\.id)) ==
                ["phys:file:fixture/A.swift", "phys:file:fixture/B.swift"])
        #expect(scene.edges.count == 1)
        #expect(scene.degree["phys:file:fixture/A.swift"] == 1)
    }

    @Test func layoutSettlesAndIsDeterministic() {
        let a = finalFrame()
        #expect(a.settled)
        #expect(a.positions.count == 2)

        let b = finalFrame()
        for (id, position) in a.positions {
            #expect(b.positions[id] == position)
        }

        // Connected nodes end up near the ideal edge length, not on
        // top of each other and not flung apart.
        let p1 = a.positions["phys:file:fixture/A.swift"]!
        let p2 = a.positions["phys:file:fixture/B.swift"]!
        let distance = ((p1 - p2) * (p1 - p2)).sum().squareRoot()
        #expect(distance > 10 && distance < 400)
    }

    @Test func emptySceneSettlesImmediately() {
        let scene = GraphScene(nodes: [], edges: [])
        var frames: [LayoutFrame] = []
        LayoutEngine.run(scene: scene, seed: 1, maxIterations: 10, emitEvery: 1) { frame in
            frames.append(frame)
            return true
        }
        #expect(frames.count == 1)
        #expect(frames[0].settled)
    }
}
