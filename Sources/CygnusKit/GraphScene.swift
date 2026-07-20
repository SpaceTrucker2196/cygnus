import Foundation

// A renderable subset of a snapshot: what the graph views draw.
// Scenes are projections — computed from the snapshot, never a
// second model.

public struct GraphScene: Sendable, Equatable {
    public let nodes: [GraphSnapshot.Node]
    public let edges: [GraphSnapshot.Edge]
    /// Node degree within this scene — renderers size nodes by it.
    public let degree: [String: Int]

    public init(nodes: [GraphSnapshot.Node], edges: [GraphSnapshot.Edge]) {
        self.nodes = nodes
        self.edges = edges
        var degree: [String: Int] = [:]
        for edge in edges {
            degree[edge.from, default: 0] += 1
            degree[edge.to, default: 0] += 1
        }
        self.degree = degree
    }

    /// The import graph: file and module nodes joined by imports
    /// edges. The first "wow" projection and the Flat view's default.
    public static func dependencies(from snapshot: GraphSnapshot) -> GraphScene {
        let imports = snapshot.edges.filter { $0.kind == "core:imports" }
        let ids = Set(imports.flatMap { [$0.from, $0.to] })
        let nodes = snapshot.nodes.filter { ids.contains($0.id) }
        return GraphScene(nodes: nodes, edges: imports)
    }
}
