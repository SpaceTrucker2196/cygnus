// Canonical graph model. This target depends on nothing and owns the
// vocabulary every other subsystem speaks. See MISSION.md §2 for the
// invariants these types encode.

// MARK: - Identifiers

/// Globally unique identity of a repository, independent of path,
/// remote URL, branch, or clone location.
public struct RepositoryID: Hashable, Codable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

/// Monotonic revision number, scoped to a workspace. Graph revisions
/// are immutable; facts carry [validFrom, validTo) intervals of these.
public struct RevisionID: Hashable, Codable, Sendable, Comparable {
    public let raw: Int64
    public init(_ raw: Int64) { self.raw = raw }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.raw < rhs.raw }
}

/// Store-local surrogate key for an entity row.
public struct EntityID: Hashable, Codable, Sendable {
    public let raw: Int64
    public init(_ raw: Int64) { self.raw = raw }
}

/// Deterministic, human-readable identity that survives moves and
/// layout changes. Examples:
///   phys:file:<repo>/Sources/App/Main.swift
///   swift:type:<repo>/Networking.HTTPClient
///   swift:function:<repo>/Networking.HTTPClient.send#a1b2c3
public struct StableKey: Hashable, Codable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

// MARK: - Knowledge layers

/// How a fact was obtained. Observed facts come straight from
/// repository artifacts; derived facts are computed mechanically;
/// inferred facts come from semantic reasoning. The distinction is
/// user-visible and load-bearing (MISSION.md §2.9).
public enum KnowledgeLayer: String, Codable, Sendable {
    case observed, derived, inferred
}

// MARK: - Kinds (namespaced strings, not enums — plugin extensibility)

/// Entity kind such as `core:function` or `swift:actor`. Namespaced
/// strings rather than an enum so plugins extend the vocabulary
/// without forking the model.
public struct EntityKind: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

extension EntityKind {
    public static let repository = EntityKind("core:repository")
    public static let directory = EntityKind("core:directory")
    public static let file = EntityKind("core:file")
    public static let module = EntityKind("core:module")
    public static let type = EntityKind("core:type")
    public static let interface = EntityKind("core:interface")
    public static let enumeration = EntityKind("core:enumeration")
    public static let function = EntityKind("core:function")
    public static let variable = EntityKind("core:variable")
    /// A named unit of the build: a Make target, a fastlane lane. The
    /// auxiliary software a system must be migrated *with* — coupling
    /// to the platform, not to the code.
    public static let buildTarget = EntityKind("core:buildTarget")
    /// A contributor. Not repository-scoped: the same person works
    /// across repositories, and that is the interesting part.
    public static let person = EntityKind("core:person")
}

/// Relationship kind such as `core:declares` or `core:imports`.
public struct RelationshipKind: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

extension RelationshipKind {
    /// Physical containment: repo → directory → file.
    public static let containsPhysical = RelationshipKind("core:containsPhysical")
    /// Logical declaration: file/type → member.
    public static let declares = RelationshipKind("core:declares")
    public static let imports = RelationshipKind("core:imports")
    public static let dependsOn = RelationshipKind("core:dependsOn")
    /// File → file: a symbol defined in the target is referenced from
    /// the source (compiler-resolved, index-store enrichment).
    public static let references = RelationshipKind("core:references")
    /// Declaration → declaration: the source declaration references a
    /// symbol defined by the target declaration (the file→file edge at
    /// symbol granularity — the caller/callee wiring).
    public static let refersToSymbol = RelationshipKind("core:refersToSymbol")
    public static let inherits = RelationshipKind("core:inherits")
    public static let conformsTo = RelationshipKind("core:conformsTo")
    /// Build target → what it is declared to need: a source file, or
    /// another target. Kept distinct from `dependsOn` so build
    /// coupling can be charted (or hidden) on its own, and so the
    /// derived import rollups stay unambiguous.
    public static let builds = RelationshipKind("core:builds")
    /// CI workflow file → build target: the workflow's command line
    /// names this lane. What puts the trigger column on a fastlane
    /// pipeline chart.
    public static let invokes = RelationshipKind("core:invokes")
    /// File → person: this person has committed to this file, with a
    /// commit count. Derived — arithmetic over authorship
    /// observations.
    public static let authoredBy = RelationshipKind("core:authoredBy")
    /// File → person: this person is *the* owner. Inferred — a
    /// judgement about concentration, held to a higher bar than the
    /// counting that supports it.
    public static let ownedBy = RelationshipKind("core:ownedBy")
}

// MARK: - Properties

/// Strongly typed property value. Extension properties use namespaced
/// keys (e.g. `swift:accessLevel`) inside a PropertyBag.
public indirect enum PropertyValue: Hashable, Codable, Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case entityRef(EntityID)
    case array([PropertyValue])
}

public typealias PropertyBag = [String: PropertyValue]

// MARK: - Source anchoring

/// Byte/line range inside a file blob.
public struct SourceRange: Hashable, Codable, Sendable {
    public let startLine: Int
    public let startColumn: Int
    public let endLine: Int
    public let endColumn: Int
    public init(startLine: Int, startColumn: Int, endLine: Int, endColumn: Int) {
        self.startLine = startLine
        self.startColumn = startColumn
        self.endLine = endLine
        self.endColumn = endColumn
    }
}

/// Content-addressed hash of a file blob (SHA-256, lowercase hex).
public struct BlobHash: Hashable, Codable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

/// Where in the snapshot an entity/observation is anchored. Provenance
/// stays valid even after the live file changes, because it points at
/// the blob, not the path.
public struct SourceAnchor: Hashable, Codable, Sendable {
    public let path: String
    public let blob: BlobHash
    public let range: SourceRange?
    public init(path: String, blob: BlobHash, range: SourceRange?) {
        self.path = path
        self.blob = blob
        self.range = range
    }
}

// MARK: - Graph elements

/// The identity of a thing that exists. State lives in EntityVersion
/// rows; the Entity row itself never changes.
public struct Entity: Hashable, Codable, Sendable {
    public let id: EntityID
    public let stableKey: StableKey
    public let kind: EntityKind
    public let repository: RepositoryID?
    public let firstSeen: RevisionID
    public init(id: EntityID, stableKey: StableKey, kind: EntityKind,
                repository: RepositoryID?, firstSeen: RevisionID) {
        self.id = id
        self.stableKey = stableKey
        self.kind = kind
        self.repository = repository
        self.firstSeen = firstSeen
    }
}

/// State of an entity over a revision interval. `validTo == nil`
/// means current. `id` is the store's version-row id — provenance
/// links attach to it.
public struct EntityVersion: Hashable, Codable, Sendable {
    public let id: Int64
    public let entity: EntityID
    public let validFrom: RevisionID
    public let validTo: RevisionID?
    public let name: String
    public let properties: PropertyBag
    public let anchors: [SourceAnchor]
    public init(id: Int64, entity: EntityID, validFrom: RevisionID, validTo: RevisionID?,
                name: String, properties: PropertyBag, anchors: [SourceAnchor]) {
        self.id = id
        self.entity = entity
        self.validFrom = validFrom
        self.validTo = validTo
        self.name = name
        self.properties = properties
        self.anchors = anchors
    }
}

/// Directional, first-class connection between entities. Carries its
/// own layer, interval, and properties (confidence, cardinality, …).
public struct Relationship: Hashable, Codable, Sendable {
    public let id: Int64
    public let kind: RelationshipKind
    public let source: EntityID
    public let target: EntityID
    public let layer: KnowledgeLayer
    public let validFrom: RevisionID
    public let validTo: RevisionID?
    public let properties: PropertyBag
    public init(id: Int64, kind: RelationshipKind, source: EntityID, target: EntityID,
                layer: KnowledgeLayer, validFrom: RevisionID, validTo: RevisionID?,
                properties: PropertyBag) {
        self.id = id
        self.kind = kind
        self.source = source
        self.target = target
        self.layer = layer
        self.validFrom = validFrom
        self.validTo = validTo
        self.properties = properties
    }
}
