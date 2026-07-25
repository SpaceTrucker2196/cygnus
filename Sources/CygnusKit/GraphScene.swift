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

        // Imports (file → module) plus compiler-resolved references
        // (file → file, index-store enrichment) — the latter is the
        // real wiring between files, present when the repo has been
        // built with an index.
        let edges = snapshot.edges.filter {
            ($0.kind == "core:imports" || $0.kind == "core:references")
                && charted($0.from) && charted($0.to)
        }
        let ids = Set(edges.flatMap { [$0.from, $0.to] })
        let nodes = snapshot.nodes.filter { ids.contains($0.id) }
        return GraphScene(nodes: nodes, edges: edges)
    }

    /// The symbol reference graph: declaration → declaration edges
    /// (`core:refersToSymbol`, the compiler-resolved caller/callee
    /// wiring from index-store enrichment). Present only after a repo
    /// has been built with an index; empty otherwise.
    public static func symbols(from snapshot: GraphSnapshot) -> GraphScene {
        let refs = snapshot.edges.filter { $0.kind == "core:refersToSymbol" }
        let ids = Set(refs.flatMap { [$0.from, $0.to] })
        let nodes = snapshot.nodes.filter { ids.contains($0.id) }
        return GraphScene(nodes: nodes, edges: refs)
    }

    // MARK: - Pattern analysis

    /// Edges that lie on a dependency cycle — the first architecture
    /// smell a reviewer looks for. Computed via Tarjan's strongly-
    /// connected components: an edge is cyclic when both endpoints
    /// share an SCC of size > 1 (or it's a self-loop). Keyed
    /// "from\u{1}to" so the renderer can test membership per edge.
    public var cyclicEdges: Set<String> {
        let component = stronglyConnectedComponents()
        var sizes: [Int: Int] = [:]
        for id in component.values { sizes[id, default: 0] += 1 }
        var result = Set<String>()
        for edge in edges {
            guard let a = component[edge.from], let b = component[edge.to] else { continue }
            if a == b, edge.from == edge.to || (sizes[a] ?? 0) > 1 {
                result.insert("\(edge.from)\u{1}\(edge.to)")
            }
        }
        return result
    }

    /// node id → SCC id. Iterative Tarjan (no recursion — deep graphs
    /// must not blow the stack, the SnapshotIndex lesson).
    public func stronglyConnectedComponents() -> [String: Int] {
        var adjacency: [String: [String]] = [:]
        for edge in edges where edge.from != edge.to {
            adjacency[edge.from, default: []].append(edge.to)
        }
        var index = 0
        var indices: [String: Int] = [:]
        var lowlink: [String: Int] = [:]
        var onStack = Set<String>()
        var stack: [String] = []
        var component: [String: Int] = [:]
        var nextComponent = 0

        for node in nodes.map(\.id) where indices[node] == nil {
            // Explicit work stack of (node, nextNeighborIndex).
            var work: [(String, Int)] = [(node, 0)]
            while let (v, i) = work.last {
                if i == 0 {
                    indices[v] = index; lowlink[v] = index; index += 1
                    stack.append(v); onStack.insert(v)
                }
                let neighbors = adjacency[v] ?? []
                if i < neighbors.count {
                    work[work.count - 1].1 += 1
                    let w = neighbors[i]
                    if indices[w] == nil {
                        work.append((w, 0))
                    } else if onStack.contains(w) {
                        lowlink[v] = min(lowlink[v]!, indices[w]!)
                    }
                } else {
                    if lowlink[v] == indices[v] {
                        while true {
                            let w = stack.removeLast(); onStack.remove(w)
                            component[w] = nextComponent
                            if w == v { break }
                        }
                        nextComponent += 1
                    }
                    work.removeLast()
                    if let (parent, _) = work.last {
                        lowlink[parent] = min(lowlink[parent]!, lowlink[v]!)
                    }
                }
            }
        }
        return component
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

    // MARK: - Grouping

    /// How the graph view organizes nodes into spatial clusters.
    /// Grouping is a projection choice — paths and kinds are observed
    /// facts; the partition drawn from them is disposable render state.
    public enum Grouping: String, CaseIterable, Sendable {
        /// Project areas: top-level directory, one level deeper under
        /// source/test umbrella folders ("Sources/CygnusKit").
        case area = "Area"
        /// Three bands: production code, test code, imported modules.
        case layer = "Layer"
        /// Architectural roles by naming convention (MVVM / MVC):
        /// Models, Views, ViewModels, Controllers, Services, Stores.
        case pattern = "Pattern"
        /// No spatial grouping; pure force layout (color still by area).
        case none = "None"
    }

    /// Path components that mark everything beneath them as test code.
    private static let testDirectories: Set<Substring> = [
        "Tests", "tests", "test", "Test", "__tests__",
        "spec", "specs", "Spec", "UITests",
    ]

    /// A node is test code when it lives under a test directory or its
    /// filename follows a test naming convention (`FooTests.swift`,
    /// `test_foo.py`, `foo_test.c`, `foo.spec.ts`).
    public static func isTest(_ node: GraphSnapshot.Node) -> Bool {
        guard let path = node.path else { return false }
        let components = path.split(separator: "/")
        if components.dropLast().contains(where: { testDirectories.contains($0) }) {
            return true
        }
        guard let file = components.last else { return false }
        let stem = file.prefix(while: { $0 != "." })
        return stem.hasSuffix("Tests") || stem.hasSuffix("Test")
            || stem.hasPrefix("test_") || stem.hasSuffix("_test")
            || file.contains(".test.") || file.contains(".spec.")
    }

    /// Architectural role by naming convention. This is *convention
    /// reading*, not inference: "FooViewModel.swift" observably follows
    /// the ViewModel naming pattern; whether it truly is one is a
    /// derived-layer question for the engine. Order matters — ViewModel
    /// before View before Model, so compound names classify correctly.
    public static func patternRole(of node: GraphSnapshot.Node) -> String {
        guard node.kind != "core:module" else { return "Modules" }
        if isTest(node) { return "Tests" }
        guard let path = node.path else { return "Other" }
        let file = path.split(separator: "/").last ?? ""
        let stem = String(file.prefix(while: { $0 != "." }))
        let directories = Set(path.split(separator: "/").dropLast().map(String.init))

        func matches(_ suffixes: [String], _ folders: [String]) -> Bool {
            suffixes.contains(where: stem.hasSuffix)
                || folders.contains(where: directories.contains)
        }
        if matches(["ViewModel", "ViewModels"], ["ViewModels"]) { return "ViewModels" }
        if matches(["View", "Screen", "Page", "Window", "Cell"], ["Views", "Screens", "UI"]) {
            return "Views"
        }
        if matches(["Controller", "Coordinator", "Router", "Presenter"],
                   ["Controllers", "Coordinators"]) { return "Controllers" }
        if matches(["Store", "Repository", "Persistence", "Database", "DAO"],
                   ["Stores", "Repositories"]) { return "Stores" }
        if matches(["Service", "Client", "Provider", "Manager", "Engine", "API"],
                   ["Services", "Providers", "Networking"]) { return "Services" }
        if matches(["Model", "Entity", "DTO", "Record"], ["Models", "Entities"]) {
            return "Models"
        }
        return "Other"
    }

    /// The cluster key a node belongs to under a grouping mode, or nil
    /// when the mode imposes no spatial grouping.
    public static func clusterKey(of node: GraphSnapshot.Node,
                                  grouping: Grouping) -> String? {
        switch grouping {
        case .none: nil
        case .area: group(of: node)
        case .layer:
            if node.kind == "core:module" { "Modules" }
            else if isTest(node) { "Tests" }
            else { "Production" }
        case .pattern: patternRole(of: node)
        }
    }

    /// Node → cluster key for every node in the scene (empty for
    /// `.none`). This is what the layout engine and region renderer
    /// consume; they never re-derive membership separately.
    public func clusters(grouping: Grouping) -> [String: String] {
        guard grouping != .none else { return [:] }
        var clusters: [String: String] = [:]
        clusters.reserveCapacity(nodes.count)
        for node in nodes {
            if let key = Self.clusterKey(of: node, grouping: grouping) {
                clusters[node.id] = key
            }
        }
        return clusters
    }
}
