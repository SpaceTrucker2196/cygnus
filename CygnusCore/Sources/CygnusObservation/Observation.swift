import Foundation
import CygnusGraph
import CygnusProviders

// Observations are atomic facts directly supported by repository
// contents — intentionally literal, zero interpretation. "File A
// imports module B" is an observation; "this is the auth service"
// is a conclusion and belongs to later layers.

public struct ObservationKind: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

extension ObservationKind {
    public static let declaration = ObservationKind("core:declaration")
    public static let importStatement = ObservationKind("core:importStatement")
    public static let reference = ObservationKind("core:reference")
    public static let fileFact = ObservationKind("core:fileFact")
}

/// Name + semantic version of the extractor that produced an
/// observation. Version bumps trigger re-extraction.
public struct ExtractorIdentity: Hashable, Codable, Sendable {
    public let name: String
    public let version: String
    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct Observation: Hashable, Codable, Sendable {
    public let kind: ObservationKind
    public let file: SourceAnchor
    public let payload: PropertyBag
    public let extractor: ExtractorIdentity
    public init(kind: ObservationKind, file: SourceAnchor, payload: PropertyBag,
                extractor: ExtractorIdentity) {
        self.kind = kind
        self.file = file
        self.payload = payload
        self.extractor = extractor
    }
}

/// The seam all language extractors plug into. Per-file, pure,
/// parallelizable. Cross-file work (import resolution, linking) is
/// not an extractor concern.
public protocol ObservationExtractor: Sendable {
    var identity: ExtractorIdentity { get }
    func claims(file: SnapshotFile) -> Bool
    func extract(file: SnapshotFile, content: Data) throws -> [Observation]
}
