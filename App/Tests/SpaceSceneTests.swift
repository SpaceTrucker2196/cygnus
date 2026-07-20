import Testing
import RealityKit
import CygnusKit
@testable import Cygnus

// RealityKit scene construction — runs where RealityKit is available
// (app test bundle).

@Suite struct SpaceSceneTests {
    @MainActor
    @Test func buildsInstancedNodesAndOneEdgeEntity() async {
        let scene = GraphScene.dependencies(from: .sample)
        let frame = Layout3D.solveSync(scene, seed: 1, maxIterations: 50)
        let root = GraphSceneBuilder.build(scene: scene, frame: frame)

        let named = root.children.filter { !$0.name.isEmpty }
        #expect(named.count == scene.nodes.count)          // one entity per node
        #expect(root.children.count == scene.nodes.count + 1)   // + ONE edge batch

        // Node entities are pickable.
        let node = named.first!
        #expect(node.components[InputTargetComponent.self] != nil)
        #expect(node.components[CollisionComponent.self] != nil)
    }

    @MainActor
    @Test func edgeMeshBatchesAllEdges() {
        let scene = GraphScene.dependencies(from: .sample)
        let frame = Layout3D.solveSync(scene, seed: 1, maxIterations: 50)
        let mesh = GraphSceneBuilder.edgeMesh(scene: scene, frame: frame)
        #expect(mesh != nil)
    }
}
