import Foundation

// The store contract. CygnusStore implements it over GRDB/SQLite;
// everything above the store (pipeline, derivers, query) speaks only
// these types. Semantics the implementation must keep (MISSION.md §2):
// rows are append-only — never mutated except to close a valid_to
// interval — and a revision commit is exactly one transaction.

public struct SnapshotID: Hashable, Codable, Sendable {
    public let raw: Int64
    public init(_ raw: Int64) { self.raw = raw }
}

public struct ObservationID: Hashable, Codable, Sendable {
    public let raw: Int64
    public init(_ raw: Int64) { self.raw = raw }
}

/// Which graph state a read targets: the current graph, or the graph
/// as it stood at a historical revision. Same queries, different
/// interval predicate.
public enum RevisionQuery: Hashable, Sendable {
    case current
    case asOf(RevisionID)
}

/// An entity together with the version row satisfying the query.
public struct ResolvedEntity: Hashable, Codable, Sendable {
    public let entity: Entity
    public let version: EntityVersion
    public init(entity: Entity, version: EntityVersion) {
        self.entity = entity
        self.version = version
    }
}

/// Upsert of an entity's state at commit. If the entity is new, an
/// identity row and a version row are created; if its state changed,
/// the old version's interval is closed and a new one opened; if
/// unchanged, the assertion is a no-op (plus provenance merge).
/// `anchors` order is significant — callers sort deterministically.
public struct EntityAssertion: Hashable, Sendable {
    public let stableKey: StableKey
    public let kind: EntityKind
    public let repository: RepositoryID?
    public let name: String
    public let properties: PropertyBag
    public let anchors: [SourceAnchor]
    public let supportedBy: [ObservationID]
    public init(stableKey: StableKey, kind: EntityKind, repository: RepositoryID?,
                name: String, properties: PropertyBag = [:],
                anchors: [SourceAnchor] = [], supportedBy: [ObservationID] = []) {
        self.stableKey = stableKey
        self.kind = kind
        self.repository = repository
        self.name = name
        self.properties = properties
        self.anchors = anchors
        self.supportedBy = supportedBy
    }
}

/// Assertion of a directional relationship between two entities that
/// must exist by the end of the same commit. Identical current
/// relationships (same endpoints, kind, layer, properties) dedupe to
/// a no-op plus provenance merge.
public struct RelationshipAssertion: Hashable, Sendable {
    public let source: StableKey
    public let target: StableKey
    public let kind: RelationshipKind
    public let layer: KnowledgeLayer
    public let properties: PropertyBag
    public let supportedBy: [ObservationID]
    public init(source: StableKey, target: StableKey, kind: RelationshipKind,
                layer: KnowledgeLayer, properties: PropertyBag = [:],
                supportedBy: [ObservationID] = []) {
        self.source = source
        self.target = target
        self.kind = kind
        self.layer = layer
        self.properties = properties
        self.supportedBy = supportedBy
    }
}

/// Everything that changes in one revision. Applied atomically;
/// retractions close intervals at the new revision, they never
/// delete history.
public struct RevisionChanges: Sendable {
    public var entities: [EntityAssertion]
    public var retractEntities: [StableKey]
    public var relationships: [RelationshipAssertion]
    public var retractRelationships: [Int64]
    public init(entities: [EntityAssertion] = [],
                retractEntities: [StableKey] = [],
                relationships: [RelationshipAssertion] = [],
                retractRelationships: [Int64] = []) {
        self.entities = entities
        self.retractEntities = retractEntities
        self.relationships = relationships
        self.retractRelationships = retractRelationships
    }

    public var isEmpty: Bool {
        entities.isEmpty && retractEntities.isEmpty
            && relationships.isEmpty && retractRelationships.isEmpty
    }
}

public struct RevisionInfo: Hashable, Codable, Sendable {
    public let id: RevisionID
    public let note: String?
    public let createdAt: Date
    public init(id: RevisionID, note: String?, createdAt: Date) {
        self.id = id
        self.note = note
        self.createdAt = createdAt
    }
}

public enum GraphStoreError: Error, Equatable {
    /// A relationship assertion referenced a stable key that does not
    /// resolve to an entity in this commit or the current graph.
    case unknownEntity(StableKey)
    /// A retraction referenced a relationship that is not current.
    case unknownRelationship(Int64)
}

public protocol GraphStore: Sendable {
    func currentRevision() throws -> RevisionID?
    func revisions() throws -> [RevisionInfo]

    /// Apply one revision's changes atomically. Returns the new
    /// revision id. Assertion order within the commit is irrelevant;
    /// relationships may reference entities asserted in the same
    /// commit.
    @discardableResult
    func commit(_ changes: RevisionChanges, note: String?) throws -> RevisionID

    func entity(stableKey: StableKey, at query: RevisionQuery) throws -> ResolvedEntity?
    func entities(kind: EntityKind, at query: RevisionQuery) throws -> [ResolvedEntity]
    /// Batch id → entity resolution — derivers and projection
    /// builders map relationship endpoints back to keys with this.
    func entities(ids: [EntityID], at query: RevisionQuery) throws -> [ResolvedEntity]
    func relationships(from source: StableKey, kind: RelationshipKind?,
                       at query: RevisionQuery) throws -> [Relationship]
    func relationships(to target: StableKey, kind: RelationshipKind?,
                       at query: RevisionQuery) throws -> [Relationship]
    /// Whole-graph scan of one relationship kind — the bulk read a
    /// rollup deriver starts from.
    func relationships(kind: RelationshipKind, at query: RevisionQuery) throws -> [Relationship]

    /// Prefix/substring name search over the current graph (FTS).
    func searchNames(_ text: String, limit: Int) throws -> [ResolvedEntity]

    /// Observation ids supporting a fact — the "why" chain.
    func provenance(ofRelationship id: Int64) throws -> [ObservationID]
    func provenance(ofEntityVersion id: Int64) throws -> [ObservationID]
}
