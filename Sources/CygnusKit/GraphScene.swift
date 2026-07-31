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
        // A source file charts whether or not it is wired. Deriving
        // nodes from edges alone erased every file whose imports are
        // all system frameworks — an Xcode app importing only SwiftUI
        // and Foundation rendered as two nodes. Absence of a charted
        // import is not absence of code.
        //
        // "Source file" is read off the evidence, not off the
        // extension: a file charts when it declares something. That
        // keeps READMEs, JSON and asset files out without a hardcoded
        // language list.
        let declaring = Set(snapshot.edges.lazy
            .filter { $0.kind == "core:declares" }
            .map(\.from))
        let ids = Set(edges.flatMap { [$0.from, $0.to] })
        let nodes = snapshot.nodes.filter {
            ids.contains($0.id) || ($0.kind == "core:file" && declaring.contains($0.id))
        }
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

    /// The caller graph at type granularity: **which class uses which
    /// class**. Each symbol reference (decl → decl) is lifted to the
    /// types that enclose its endpoints and aggregated, so a class
    /// links to every class it calls into — the who-calls-whom wiring,
    /// not import dependencies. Needs an index build; empty otherwise.
    public static func callers(from snapshot: GraphSnapshot) -> GraphScene {
        let byID = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
        // Child decl → its declaring parent (declares edges point
        // parent → child).
        var parent: [String: String] = [:]
        for edge in snapshot.edges where edge.kind == "core:declares" {
            parent[edge.to] = edge.from
        }
        func isType(_ node: GraphSnapshot.Node) -> Bool {
            node.kind.hasSuffix(":type") || node.kind.hasSuffix(":interface")
                || node.kind.hasSuffix(":enumeration")
        }
        // Walk up to the nearest enclosing type declaration.
        func enclosingType(_ id: String) -> String? {
            var current: String? = id
            var guardrail = 0
            while let node = current.flatMap({ byID[$0] }), guardrail < 64 {
                if isType(node) { return node.id }
                current = parent[node.id]; guardrail += 1
            }
            return nil
        }
        // Aggregate type → type with summed weight.
        var weights: [String: Int] = [:]      // "from\u{1}to" → weight
        for edge in snapshot.edges where edge.kind == "core:refersToSymbol" {
            guard let from = enclosingType(edge.from),
                  let to = enclosingType(edge.to), from != to else { continue }
            weights["\(from)\u{1}\(to)", default: 0] += edge.weight
        }
        let edges = weights.map { key, weight -> GraphSnapshot.Edge in
            let parts = key.split(separator: "\u{1}")
            return GraphSnapshot.Edge(from: String(parts[0]), to: String(parts[1]),
                                      kind: "core:refersToSymbol", weight: weight)
        }
        let ids = Set(edges.flatMap { [$0.from, $0.to] })
        return GraphScene(nodes: snapshot.nodes.filter { ids.contains($0.id) }, edges: edges)
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

    /// The full containing folder — the node's whole directory path,
    /// so grouping mirrors the repo's folder tree exactly. Files at
    /// the repo root and modules fall into "/".
    public static func folder(of node: GraphSnapshot.Node) -> String {
        guard node.kind != "core:module" else { return "modules" }
        guard let path = node.path else { return "/" }
        let directory = path.split(separator: "/").dropLast().joined(separator: "/")
        return directory.isEmpty ? "/" : directory
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
        /// Every containing folder is its own cluster — the repo's
        /// directory structure, one region per folder.
        case folder = "Folder"
        /// Three bands: production code, test code, imported modules.
        case layer = "Layer"
        /// Architectural roles by naming convention (MVVM / MVC):
        /// Models, Views, ViewModels, Controllers, Services, Stores.
        case pattern = "Pattern"
        /// Structural role inferred from the dependency graph itself —
        /// no names. Where a node sits in the flow (Core/Hub/Entry/Leaf).
        case role = "Role"
        /// Who owns the file: an author, Shared, or Unowned. Needs
        /// git history, which the engine reads during analysis.
        case owner = "Owner"
        /// No spatial grouping; pure force layout (color still by area).
        case none = "None"
    }

    /// Kinds that mean "A depends on B" (as opposed to containment or
    /// declaration structure) — the substrate for structural roles.
    private static let dependencyKinds: Set<String> = [
        "core:imports", "core:dependsOn", "core:references", "core:refersToSymbol",
    ]

    /// Structural role per node, inferred from position in the
    /// dependency flow — depended-upon vs depends-on, name-free:
    ///   Core  — depended-upon, depends on little (foundations)
    ///   Hub   — depends on and is depended-upon (orchestrators)
    ///   Entry — depends on much, depended-upon by little (drivers)
    ///   Leaf  — barely connected (utilities, isolated)
    /// Threshold `t` is the fan-in/out above which a direction counts
    /// as "significant"; 2 keeps single incidental edges from
    /// promoting a node.
    public func structuralRoles(threshold t: Int = 2) -> [String: String] {
        var fanOut: [String: Set<String>] = [:]
        var fanIn: [String: Set<String>] = [:]
        for edge in edges where Self.dependencyKinds.contains(edge.kind) && edge.from != edge.to {
            fanOut[edge.from, default: []].insert(edge.to)
            fanIn[edge.to, default: []].insert(edge.from)
        }
        var roles: [String: String] = [:]
        for node in nodes {
            let out = fanOut[node.id]?.count ?? 0
            let into = fanIn[node.id]?.count ?? 0
            roles[node.id] = switch (into >= t, out >= t) {
            case (true, false): "Core"
            case (true, true): "Hub"
            case (false, true): "Entry"
            case (false, false): "Leaf"
            }
        }
        return roles
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

    /// The build coupling graph: build targets and the files and
    /// sibling targets they are declared to need.
    ///
    /// *Kill It With Fire* calls this overgrowth — "a particular type
    /// of coupling between the software and the layers of abstraction
    /// making up the platform on which it runs" (p. 64) — and its
    /// point is that this is the software you must migrate *first*,
    /// which is hard to plan when it is invisible. A file here is one
    /// a build target actually references, so the answer to "what
    /// else moves if this moves" includes the build.
    public static func build(from snapshot: GraphSnapshot) -> GraphScene {
        let edges = snapshot.edges.filter { $0.kind == "core:builds" }
        let ids = Set(edges.flatMap { [$0.from, $0.to] })
        // Targets chart even with nothing resolved under them: a lane
        // that couples to nothing is itself worth seeing.
        let targets = snapshot.nodes.filter { $0.kind == "core:buildTarget" }
        let nodes = snapshot.nodes.filter { ids.contains($0.id) }
            + targets.filter { !ids.contains($0.id) }
        return GraphScene(nodes: nodes, edges: edges)
    }

    // MARK: - Path tracing

    /// Every node and edge lying on a shortest path from `from` to
    /// `to`, following dependency direction.
    public struct PathTrace: Sendable, Equatable {
        public let nodes: Set<String>
        public let edges: [GraphSnapshot.Edge]
        /// Hops on the shortest route; nil when `to` is unreachable.
        public let length: Int?
        public var isConnected: Bool { length != nil }
    }

    /// "How does A reach B" — the question the graph could not answer.
    /// Focus shows what touches a node; this shows the route between
    /// two, which is what *Kill It With Fire* means by tracing the
    /// flow through an application to complete one request.
    ///
    /// Returns the union of all *shortest* paths rather than every
    /// path: enumerating all simple paths is exponential, while the
    /// shortest-path union is two breadth-first sweeps and is the part
    /// a reader can actually follow. An edge is on a shortest path
    /// when `distance(from → u) + 1 + distance(v → to)` equals the
    /// total — so alternates of equal length all survive.
    public func paths(from: String, to: String, limit: Int = 500) -> PathTrace {
        guard from != to else { return PathTrace(nodes: [from], edges: [], length: 0) }

        var forward: [String: [GraphSnapshot.Edge]] = [:]
        var backward: [String: [GraphSnapshot.Edge]] = [:]
        for edge in edges where edge.from != edge.to {
            forward[edge.from, default: []].append(edge)
            backward[edge.to, default: []].append(edge)
        }

        func distances(from source: String,
                       following adjacency: [String: [GraphSnapshot.Edge]],
                       step: (GraphSnapshot.Edge) -> String) -> [String: Int] {
            var distance: [String: Int] = [source: 0]
            var frontier = [source]
            while !frontier.isEmpty {
                var next: [String] = []
                for node in frontier {
                    let hop = distance[node]! + 1
                    for edge in adjacency[node] ?? [] where distance[step(edge)] == nil {
                        distance[step(edge)] = hop
                        next.append(step(edge))
                    }
                }
                frontier = next
            }
            return distance
        }

        let fromStart = distances(from: from, following: forward, step: \.to)
        guard let total = fromStart[to] else {
            return PathTrace(nodes: [], edges: [], length: nil)
        }
        let toEnd = distances(from: to, following: backward, step: \.from)

        var onPath: [GraphSnapshot.Edge] = []
        var nodes: Set<String> = [from, to]
        for edge in edges {
            guard let head = fromStart[edge.from], let tail = toEnd[edge.to],
                  head + 1 + tail == total
            else { continue }
            onPath.append(edge)
            nodes.insert(edge.from)
            nodes.insert(edge.to)
        }
        // Deterministic order, then bound: a wide graph can put a lot
        // of equal-length alternates on the same route.
        onPath.sort { ($0.from, $0.to) < ($1.from, $1.to) }
        return PathTrace(nodes: nodes, edges: Array(onPath.prefix(limit)), length: total)
    }

    // MARK: - Ownership

    /// File → the cluster its ownership puts it in: an owner's name,
    /// `Shared`, or `Unowned`.
    ///
    /// Reads the snapshot rather than a scene, because ownership edges
    /// are not part of the dependency projection — the point is to
    /// colour the *dependency* graph by who owns it.
    ///
    /// The three states are the finding, not a fallback:
    ///   - **owned** — one author holds most of the file's history.
    ///   - **Shared** — several authors, none dominant. *Kill It With
    ///     Fire*: "the most productive places to mine are gaps between
    ///     what two components of the same organization officially
    ///     own" (p. 98).
    ///   - **Unowned** — in the repository, but nobody has committed
    ///     to it within the history that was read.
    public static func owners(from snapshot: GraphSnapshot) -> [String: String] {
        let names = Dictionary(uniqueKeysWithValues: snapshot.nodes
            .filter { $0.kind == "core:person" }
            .map { ($0.id, $0.label) })
        var owner: [String: String] = [:]
        var authored = Set<String>()
        for edge in snapshot.edges {
            switch edge.kind {
            case "core:ownedBy": owner[edge.from] = names[edge.to] ?? "Owned"
            case "core:authoredBy": authored.insert(edge.from)
            default: continue
            }
        }
        var result: [String: String] = [:]
        for node in snapshot.nodes where node.kind == "core:file" {
            result[node.id] = owner[node.id]
                ?? (authored.contains(node.id) ? "Shared" : "Unowned")
        }
        return result
    }

    /// Files several people work on with no clear owner — the seam
    /// where responsibility falls between two parties.
    public static func responsibilityGaps(from snapshot: GraphSnapshot) -> Set<String> {
        Set(owners(from: snapshot).filter { $0.value == "Shared" }.keys)
    }

    // MARK: - Naming versus structure

    /// A node whose name claims one architectural role while its
    /// position in the dependency graph says another.
    public struct RoleDisagreement: Sendable, Equatable {
        public let nodeID: String
        /// Role read from naming convention (Pattern grouping).
        public let named: String
        /// Role inferred from fan-in/fan-out (Role grouping).
        public let structural: String
    }

    /// What each naming convention implies about position in the
    /// dependency flow. Roles absent here make no structural claim —
    /// "Other" says nothing, and tests and modules are their own
    /// layer.
    private static let expectedRoles: [String: Set<String>] = [
        // Depended upon: things that provide.
        "Services": ["Core", "Hub"],
        "Stores": ["Core", "Hub"],
        "Models": ["Core", "Hub", "Leaf"],
        // Depending: things that drive.
        "Views": ["Entry", "Hub", "Leaf"],
        "ViewModels": ["Entry", "Hub"],
        "Controllers": ["Entry", "Hub"],
    ]

    /// Nodes where naming and structure disagree.
    ///
    /// *Kill It With Fire* calls the failure mode artificial
    /// consistency: form and classification standardized over
    /// function, so things that look alike are assumed to fit
    /// together. Pattern grouping reads names; Role grouping reads the
    /// graph. Rendering the disagreement is the cheapest way to catch
    /// a name that has stopped describing what the code does — a
    /// `…Service` nothing depends on, a `…View` everything does.
    public func roleDisagreements(threshold t: Int = 2) -> [String: RoleDisagreement] {
        let structural = structuralRoles(threshold: t)
        var result: [String: RoleDisagreement] = [:]
        for node in nodes {
            let named = Self.patternRole(of: node)
            guard let expected = Self.expectedRoles[named],
                  let actual = structural[node.id],
                  !expected.contains(actual)
            else { continue }
            result[node.id] = RoleDisagreement(
                nodeID: node.id, named: named, structural: actual)
        }
        return result
    }

    /// The cluster key a node belongs to under a grouping mode, or nil
    /// when the mode imposes no spatial grouping.
    public static func clusterKey(of node: GraphSnapshot.Node,
                                  grouping: Grouping) -> String? {
        switch grouping {
        case .none: nil
        case .area: group(of: node)
        case .folder: folder(of: node)
        case .layer:
            if node.kind == "core:module" { "Modules" }
            else if isTest(node) { "Tests" }
            else { "Production" }
        case .pattern: patternRole(of: node)
        // Structural role needs whole-graph context — computed in
        // bulk by clusters(grouping:), not per node. Ownership needs
        // more still: edges the dependency scene does not carry, so
        // it comes from owners(from:) against the snapshot.
        case .role, .owner: nil
        }
    }

    /// Node → cluster key for every node in the scene (empty for
    /// `.none`). This is what the layout engine, palette, and region
    /// renderer consume; they never re-derive membership separately.
    public func clusters(grouping: Grouping) -> [String: String] {
        switch grouping {
        case .none: return [:]
        case .role: return structuralRoles()
        default:
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
}
