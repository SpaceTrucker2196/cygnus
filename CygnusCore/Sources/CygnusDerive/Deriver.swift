import CygnusGraph

// Derivers compute the derived knowledge layer mechanically from
// observed facts. Every emitted fact carries provenance links to what
// it consumed — the provenance table is the invalidation index.
// First derivers (E4): contains hierarchy, import graph, metrics.

public struct DeriverIdentity: Hashable, Codable, Sendable {
    public let name: String
    public let version: String
    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}
