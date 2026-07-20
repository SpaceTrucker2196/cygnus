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
        func build(_ id: String) -> TreeNode? {
            guard let node = byID[id] else { return nil }
            let kids = (children[id] ?? [])
                .compactMap(build)
                .sorted { $0.node.label.localizedStandardCompare($1.node.label) == .orderedAscending }
            return TreeNode(node: node, children: kids.isEmpty ? nil : kids)
        }
        self.trees = snapshot.nodes
            .filter { $0.kind == "core:repository" && !contained.contains($0.id) }
            .compactMap { build($0.id) }
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
