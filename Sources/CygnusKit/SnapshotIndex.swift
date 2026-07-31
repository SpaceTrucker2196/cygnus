import Foundation

// Derived lookups over an immutable GraphSnapshot: containment tree
// for the outline, adjacency for the inspector, label search. Built
// once per snapshot — selection and filtering never rebuild it.

public struct SnapshotIndex: Sendable {
    public struct TreeNode: Identifiable, Sendable {
        public let node: GraphSnapshot.Node
        public let children: [TreeNode]?     // nil = leaf (OutlineGroup contract)
        public var id: String { node.id }
    }

    public let snapshot: GraphSnapshot
    public let byID: [String: GraphSnapshot.Node]
    public let outgoing: [String: [GraphSnapshot.Edge]]
    public let incoming: [String: [GraphSnapshot.Edge]]
    /// Roots of the containment forest (repository nodes).
    public let trees: [TreeNode]

    public init(_ snapshot: GraphSnapshot) {
        self.snapshot = snapshot
        self.byID = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })

        var outgoing: [String: [GraphSnapshot.Edge]] = [:]
        var incoming: [String: [GraphSnapshot.Edge]] = [:]
        var children: [String: [String]] = [:]
        var contained = Set<String>()
        for edge in snapshot.edges {
            outgoing[edge.from, default: []].append(edge)
            incoming[edge.to, default: []].append(edge)
            if edge.kind == "core:containsPhysical" || edge.kind == "core:declares" {
                children[edge.from, default: []].append(edge.to)
                contained.insert(edge.to)
            }
        }
        self.outgoing = outgoing
        self.incoming = incoming

        let byID = self.byID
        // The containment relation is a DAG, not a tree: the same
        // declaration key can be declared from several files (split
        // originals + a combined/generated copy, extensions across
        // files). Memoize per node — without this, every shared
        // subtree rebuilds once per path and materialization goes
        // exponential (a real repo drove this to 25 GB). The `building`
        // set cuts true cycles (self-declares) instead of recursing
        // forever.
        var memo: [String: TreeNode] = [:]
        var building = Set<String>()
        func build(_ id: String) -> TreeNode? {
            if let cached = memo[id] { return cached }
            guard let node = byID[id] else { return nil }
            guard building.insert(id).inserted else { return nil }   // cycle: cut here
            defer { building.remove(id) }
            var seen = Set<String>()
            let kids = (children[id] ?? [])
                .filter { seen.insert($0).inserted }    // duplicate edges → one row
                .compactMap(build)
                .sorted { $0.node.label.localizedStandardCompare($1.node.label) == .orderedAscending }
            let tree = TreeNode(node: node, children: kids.isEmpty ? nil : kids)
            memo[id] = tree
            return tree
        }
        self.trees = snapshot.nodes
            .filter { $0.kind == "core:repository" && !contained.contains($0.id) }
            .compactMap { build($0.id) }
    }

    /// The focus set for a node: itself plus everything within
    /// `depth` hops in either direction (dependencies and
    /// dependents). Drives the graph's blast-radius highlight — "what
    /// touches this."
    ///
    /// Depth is the whole point rather than a tuning knob. *Kill It
    /// With Fire* argues that traversing the entire graph is "a lot of
    /// work without a lot of payoff" and that mapping dependencies
    /// two levels down is what actually informs a migration. Depth 1
    /// is the immediate blast radius; `nil` is the unbounded reachable
    /// set, which is the view the book is skeptical of.
    ///
    /// Breadth-first and iterative: a deep graph must not recurse
    /// (the same rule `stronglyConnectedComponents()` follows).
    public func neighborhood(of id: String, depth: Int? = 1) -> Set<String> {
        guard byID[id] != nil else { return [id] }
        var result: Set<String> = [id]
        var frontier: [String] = [id]
        var hop = 0
        while !frontier.isEmpty, depth.map({ hop < $0 }) ?? true {
            var next: [String] = []
            for node in frontier {
                for edge in outgoing[node] ?? [] where result.insert(edge.to).inserted {
                    next.append(edge.to)
                }
                for edge in incoming[node] ?? [] where result.insert(edge.from).inserted {
                    next.append(edge.from)
                }
            }
            frontier = next
            hop += 1
        }
        return result
    }

    public func search(_ text: String, limit: Int = 50) -> [GraphSnapshot.Node] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return snapshot.nodes
            .filter { $0.label.localizedCaseInsensitiveContains(query) }
            .prefix(limit)
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }
}
