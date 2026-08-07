import Testing
import Foundation
import simd
@testable import CygnusKit

// The 3D view's correctness lives here rather than in the renderer.
//
// The previous 3D attempt was removed partly because nothing could say
// whether it was right — it existed only as view code, so the only
// available verdict was "it looks wrong". Projection and layout are
// values, so they can be asserted; the renderer only turns them into
// triangles.

@Suite struct MolecularSceneTests {
    /// Two clusters of two files each, joined by one cross-cluster edge.
    private func makeScene() -> GraphScene {
        func node(_ id: String, _ label: String) -> GraphSnapshot.Node {
            GraphSnapshot.Node(id: id, kind: "core:file", label: label,
                               path: id, line: nil, attributes: [:])
        }
        func edge(_ from: String, _ to: String) -> GraphSnapshot.Edge {
            GraphSnapshot.Edge(from: from, to: to, kind: "core:imports")
        }
        return GraphScene(
            nodes: [node("Core/A.swift", "A.swift"), node("Core/B.swift", "B.swift"),
                    node("UI/C.swift", "C.swift"), node("UI/D.swift", "D.swift")],
            edges: [edge("Core/A.swift", "Core/B.swift"),
                    edge("UI/C.swift", "UI/D.swift"),
                    edge("Core/A.swift", "UI/C.swift")])
    }

    @Test func everyNodeBecomesAnAtomInSomeMolecule() {
        let molecular = MolecularScene(scene: makeScene(), grouping: .folder)
        #expect(molecular.atoms.count == 4)
        #expect(molecular.molecules.count >= 2)
        #expect(molecular.atoms.allSatisfy { $0.molecule < molecular.molecules.count })
    }

    /// The distinction the whole metaphor rests on: bonds inside a
    /// molecule are structure, bonds between them are coupling, and
    /// they are drawn differently.
    @Test func bondsKnowWhetherTheyCrossAMolecule() {
        let molecular = MolecularScene(scene: makeScene(), grouping: .folder)
        #expect(molecular.bonds.contains { $0.isInternal })
        #expect(molecular.bonds.contains { !$0.isInternal })
    }

    /// A doubled bond is invisible and costs a draw call.
    @Test func duplicateEdgesCollapseToOneBond() {
        func node(_ id: String) -> GraphSnapshot.Node {
            GraphSnapshot.Node(id: id, kind: "core:file", label: id,
                               path: id, line: nil, attributes: [:])
        }
        func edge(_ from: String, _ to: String) -> GraphSnapshot.Edge {
            GraphSnapshot.Edge(from: from, to: to, kind: "core:imports")
        }
        let scene = GraphScene(nodes: [node("A"), node("B")],
                               edges: [edge("A", "B"), edge("B", "A"), edge("A", "B")])
        #expect(MolecularScene(scene: scene, grouping: .none).bonds.count == 1)
    }

    /// Hubs are bigger, but sublinearly — linear growth lets one hub
    /// fill the scene and hide everything it connects to.
    @Test func atomRadiusGrowsSublinearlyWithDegree() {
        let small = MolecularScene.radius(forDegree: 1)
        let medium = MolecularScene.radius(forDegree: 10)
        let large = MolecularScene.radius(forDegree: 100)
        #expect(medium > small)
        #expect(large > medium)
        #expect(large < small * 6, "a hub must not swallow the scene")
    }

    /// Molecule seeds must not clump, or the layout starts as a knot it
    /// then has to spend its whole budget untangling.
    @Test func moleculeSeedsAreSpreadAndDeterministic() {
        let points = (0..<12).map { MolecularScene.fibonacciPoint($0, of: 12) }
        for i in 0..<points.count {
            for j in (i + 1)..<points.count {
                #expect(simd_distance(points[i], points[j]) > 1)
            }
        }
        #expect(MolecularScene.fibonacciPoint(3, of: 12) == points[3])
    }

    @Test func anEmptySceneProducesAnEmptyMolecularScene() {
        let empty = GraphScene(nodes: [], edges: [])
        #expect(MolecularScene(scene: empty, grouping: .folder).isEmpty)
    }

    @Test func projectionIsDeterministic() {
        let scene = makeScene()
        let runs = (0..<3).map { _ in MolecularScene(scene: scene, grouping: .folder) }
        #expect(runs[0] == runs[1])
        #expect(runs[1] == runs[2])
    }
}

@Suite struct Layout3DTests {
    private func makeMolecular(molecules: Int, perMolecule: Int) -> MolecularScene {
        var nodes: [GraphSnapshot.Node] = []
        var edges: [GraphSnapshot.Edge] = []
        for molecule in 0..<molecules {
            for atom in 0..<perMolecule {
                let id = "M\(molecule)/f\(atom).swift"
                nodes.append(GraphSnapshot.Node(id: id, kind: "core:file", label: id,
                                                path: id, line: nil, attributes: [:]))
                if atom > 0 {
                    edges.append(GraphSnapshot.Edge(from: "M\(molecule)/f0.swift", to: id,
                                                    kind: "core:imports"))
                }
            }
        }
        return MolecularScene(scene: GraphScene(nodes: nodes, edges: edges),
                              grouping: .folder)
    }

    /// The point of the whole design: it never runs to completion in
    /// one call, so the view is on screen within a frame.
    @Test func stepAdvancesIncrementallyRatherThanSettlingAtOnce() {
        var layout = Layout3D(scene: makeMolecular(molecules: 3, perMolecule: 6))
        #expect(!layout.isSettled)
        layout.step()
        #expect(layout.iterationsRun == Layout3D.iterationsPerStep)
        #expect(!layout.isSettled, "one step must not finish the layout")
        #expect(layout.progress > 0 && layout.progress < 1)
    }

    @Test func steppingToCompletionSettlesAndThenStops() {
        var layout = Layout3D(scene: makeMolecular(molecules: 2, perMolecule: 4))
        var steps = 0
        while layout.step() { steps += 1; if steps > 1000 { break } }
        #expect(layout.isSettled)
        #expect(layout.progress == 1)
        #expect(layout.step() == false, "a settled layout must stop doing work")
    }

    /// Cohesion has to actually pull groups together, or a "molecule"
    /// is just a colour.
    @Test func atomsEndUpNearerTheirOwnMoleculeThanOthers() {
        let scene = makeMolecular(molecules: 3, perMolecule: 8)
        var layout = Layout3D(scene: scene)
        while layout.step() {}

        var correct = 0
        for (index, atom) in scene.atoms.enumerated() {
            let own = simd_distance(layout.positions[index], layout.centers[atom.molecule])
            let others = (0..<layout.centers.count)
                .filter { $0 != atom.molecule }
                .map { simd_distance(layout.positions[index], layout.centers[$0]) }
            if own < (others.min() ?? .infinity) { correct += 1 }
        }
        #expect(Double(correct) / Double(scene.atoms.count) > 0.9,
                "atoms should cluster with their own molecule")
    }

    /// Same repository, same picture, every time it is opened — which
    /// is what lets someone build a spatial memory of a codebase.
    @Test func layoutIsDeterministic() {
        let scene = makeMolecular(molecules: 2, perMolecule: 5)
        func run() -> [SIMD3<Float>] {
            var layout = Layout3D(scene: scene)
            while layout.step() {}
            return layout.positions
        }
        #expect(run() == run())
    }

    @Test func positionsStayFiniteUnderLoad() {
        let scene = makeMolecular(molecules: 6, perMolecule: 20)
        var layout = Layout3D(scene: scene)
        while layout.step() {}
        #expect(layout.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite },
                "a diverging layout produces NaN and an empty-looking scene")
        #expect(layout.extent > 0)
    }

    @Test func anEmptySceneDoesNoWork() {
        var layout = Layout3D(scene: MolecularScene(scene: GraphScene(nodes: [], edges: []),
                                                    grouping: .none))
        #expect(layout.step() == false)
    }
}
