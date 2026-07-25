import Testing
import Foundation
@testable import CygnusKit

// Grouping for the 2D visualizer: test-code classification, pattern
// roles, cluster maps, hull geometry, and the layout actually pulling
// clusters apart.

@Suite struct GroupingTests {
    private func file(_ path: String) -> GraphSnapshot.Node {
        GraphSnapshot.Node(id: "phys:file:r/\(path)", kind: "core:file",
                           label: String(path.split(separator: "/").last ?? ""),
                           path: path)
    }

    @Test func testCodeIsClassifiedByDirectoryAndName() {
        #expect(GraphScene.isTest(file("Tests/KitTests/FooTests.swift")))
        #expect(GraphScene.isTest(file("Sources/Kit/BarTests.swift")))
        #expect(GraphScene.isTest(file("src/test_alerts.py")))
        #expect(GraphScene.isTest(file("src/alerts_test.c")))
        #expect(GraphScene.isTest(file("app/foo.spec.ts")))
        #expect(!GraphScene.isTest(file("Sources/Kit/Contest.swift")))   // no suffix match
        #expect(!GraphScene.isTest(file("Sources/Kit/Store.swift")))
    }

    @Test func patternRolesFollowNamingConventions() {
        #expect(GraphScene.patternRole(of: file("App/Views/DashboardView.swift")) == "Views")
        #expect(GraphScene.patternRole(of: file("App/FooViewModel.swift")) == "ViewModels")
        #expect(GraphScene.patternRole(of: file("App/NavCoordinator.swift")) == "Controllers")
        #expect(GraphScene.patternRole(of: file("Kit/WorkspaceStore.swift")) == "Stores")
        #expect(GraphScene.patternRole(of: file("Kit/LayoutEngine.swift")) == "Services")
        #expect(GraphScene.patternRole(of: file("Kit/Models/User.swift")) == "Models")
        #expect(GraphScene.patternRole(of: file("Tests/FooTests.swift")) == "Tests")
        #expect(GraphScene.patternRole(of: file("README.md")) == "Other")
        // ViewModel wins over View despite both suffixes matching.
        #expect(GraphScene.patternRole(of: file("App/LoginViewModel.swift")) != "Views")
    }

    @Test func clusterMapCoversEveryNodeExceptInNoneMode() {
        let scene = GraphScene.dependencies(from: .sample)
        #expect(scene.clusters(grouping: .none).isEmpty)
        let layer = scene.clusters(grouping: .layer)
        #expect(layer.count == scene.nodes.count)
    }

    @Test func convexHullOfSquareIsItsCorners() {
        let square: [SIMD2<Double>] = [
            SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10), SIMD2(5, 5),
        ]
        let hull = ConvexHull.hull(of: square)
        #expect(hull.count == 4)
        #expect(!hull.contains(SIMD2(5, 5)))
        // Degenerate inputs come back unchanged.
        #expect(ConvexHull.hull(of: [SIMD2(1, 1)]) == [SIMD2(1, 1)])
    }

    @Test func clusteredLayoutSeparatesGroups() {
        // Two 3-node cliques with one bridging edge. Ungrouped, the
        // bridge pulls them together; grouped, each clique coheres
        // around its own anchor and the group centroids separate.
        var nodes: [GraphSnapshot.Node] = []
        var edges: [GraphSnapshot.Edge] = []
        for group in ["a", "b"] {
            for i in 0..<3 {
                nodes.append(GraphSnapshot.Node(
                    id: "\(group)\(i)", kind: "core:file", label: "\(group)\(i)",
                    path: group == "a" ? "Sources/M/\(group)\(i).swift"
                                       : "Tests/M/\(group)\(i)Tests.swift"))
            }
            for i in 0..<3 {
                edges.append(GraphSnapshot.Edge(from: "\(group)\(i)",
                                                to: "\(group)\((i + 1) % 3)",
                                                kind: "core:imports"))
            }
        }
        edges.append(GraphSnapshot.Edge(from: "a0", to: "b0", kind: "core:imports"))
        let scene = GraphScene(nodes: nodes, edges: edges)
        let clusters = scene.clusters(grouping: .layer)
        #expect(Set(clusters.values) == ["Production", "Tests"])

        var final = LayoutFrame.empty
        LayoutEngine.run(scene: scene, seed: 7, clusters: clusters,
                         maxIterations: 300, emitEvery: 10) { frame in
            final = frame
            return true
        }
        func centroid(_ prefix: String) -> SIMD2<Double> {
            let points = final.positions.filter { $0.key.hasPrefix(prefix) }.map(\.value)
            return points.reduce(SIMD2(0, 0), +) / Double(points.count)
        }
        let a = centroid("a"), b = centroid("b")
        let separation = ((a - b) * (a - b)).sum().squareRoot()
        // Group centroids sit apart, and members stay near their own
        // centroid rather than drifting into the other group.
        #expect(separation > 100)
        for (id, position) in final.positions {
            let own = id.hasPrefix("a") ? a : b
            let other = id.hasPrefix("a") ? b : a
            let toOwn = ((position - own) * (position - own)).sum().squareRoot()
            let toOther = ((position - other) * (position - other)).sum().squareRoot()
            #expect(toOwn < toOther, "\(id) drifted toward the other group")
        }
    }
}

@Suite struct StructuralRoleTests {
    private func file(_ id: String) -> GraphSnapshot.Node {
        GraphSnapshot.Node(id: id, kind: "core:file", label: id, path: "\(id).swift")
    }
    private func ref(_ from: String, _ to: String) -> GraphSnapshot.Edge {
        GraphSnapshot.Edge(from: from, to: to, kind: "core:references")
    }

    @Test func classifiesByFanInFanOut() {
        // model ← (a,b,c) ; hub ← (a,b) and hub → (model,x,y) ;
        // entry → (a,b,c) ; leaf isolated.
        let nodes = ["model","hub","entry","leaf","a","b","c","x","y"].map(file)
        let edges = [
            ref("a","model"), ref("b","model"), ref("c","model"),
            ref("a","hub"), ref("b","hub"),
            ref("hub","model"), ref("hub","x"), ref("hub","y"),
            ref("entry","a"), ref("entry","b"), ref("entry","c"),
        ]
        let roles = GraphScene(nodes: nodes, edges: edges).structuralRoles()
        #expect(roles["model"] == "Core")     // in≥2, out<2
        #expect(roles["hub"] == "Hub")         // in≥2, out≥2
        #expect(roles["entry"] == "Entry")     // out≥2, in<2
        #expect(roles["leaf"] == "Leaf")       // isolated
    }

    @Test func roleGroupingFlowsThroughClusters() {
        let scene = GraphScene(
            nodes: ["a","b","core"].map(file),
            edges: [ref("a","core"), ref("b","core")])
        let clusters = scene.clusters(grouping: .role)
        #expect(clusters["core"] == "Core")
        #expect(clusters["a"] == "Entry" || clusters["a"] == "Leaf")
    }

    @Test func containmentEdgesDoNotCountAsDependencies() {
        // A repo→file contains edge must not make the file a "Core".
        let scene = GraphScene(
            nodes: [file("repo"), file("f")],
            edges: [GraphSnapshot.Edge(from: "repo", to: "f", kind: "core:containsPhysical")])
        #expect(scene.structuralRoles()["f"] == "Leaf")
    }
}
