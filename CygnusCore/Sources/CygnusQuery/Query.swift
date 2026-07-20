import CygnusGraph

// Query surface the viewer consumes. Projections are computed on
// demand and returned as plain values — disposable, never persisted
// as separate models. Full API lands in E5.

/// A renderable slice of the graph: entities plus the relationships
/// among them.
public struct Subgraph: Hashable, Codable, Sendable {
    public let entities: [Entity]
    public let relationships: [Relationship]
    public init(entities: [Entity], relationships: [Relationship]) {
        self.entities = entities
        self.relationships = relationships
    }
}
