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
    /// edges. System modules (Apple frameworks, stdlibs) are never
    /// charted. Internal modules — names matching a directory in the
    /// repo — always are; other externals (third-party deps) only
    /// when `showExternal`.
    public static func dependencies(from snapshot: GraphSnapshot,
                                    showExternal: Bool = false) -> GraphScene {
        let directoryNames = Set(snapshot.nodes
            .filter { $0.kind == "core:directory" || $0.kind == "core:repository" }
            .map(\.label))
        let byID = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })

        func charted(_ id: String) -> Bool {
            guard let node = byID[id] else { return false }
            guard node.kind == "core:module" else { return true }   // files always chart
            if SystemModules.isSystem(nodeID: node.id, label: node.label) { return false }
            if directoryNames.contains(node.label) { return true }  // internal target
            return showExternal
        }

        let imports = snapshot.edges.filter {
            $0.kind == "core:imports" && charted($0.from) && charted($0.to)
        }
        let ids = Set(imports.flatMap { [$0.from, $0.to] })
        let nodes = snapshot.nodes.filter { ids.contains($0.id) }
        return GraphScene(nodes: nodes, edges: imports)
    }

    /// Grouping key for color coding: the project area a file lives
    /// in ("Sources/CygnusKit", "App", "Tests"…). Modules group as
    /// "modules".
    public static func group(of node: GraphSnapshot.Node) -> String {
        guard node.kind != "core:module" else { return "modules" }
        guard let path = node.path else { return "other" }
        let components = path.split(separator: "/")
        guard let first = components.first else { return "other" }
        if components.count > 1,
           ["Sources", "Tests", "src", "lib", "test", "tests"].contains(String(first)) {
            return "\(first)/\(components[1])"
        }
        return String(first)
    }
}
