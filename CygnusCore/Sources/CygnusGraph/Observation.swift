import Foundation

// Observations are part of the canonical model — the observed layer's
// raw material. They are atomic facts directly supported by repository
// contents, intentionally literal, zero interpretation. "File A
// imports module B" is an observation; "this is the auth service" is
// a conclusion and belongs to later layers.
//
// The extractor seam that produces observations lives in
// CygnusObservation; the facts themselves belong to the graph.

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
    /// A rule read from a build file: this target exists, and this is
    /// one thing it is written to depend on. Literal — whether the
    /// dependency names a real file is resolution's problem, not the
    /// extractor's.
    public static let buildRule = ObservationKind("core:buildRule")
    /// A CI workflow file runs a build command: ".github/workflows/
    /// deploy.yml runs `fastlane ios beta`". Literal — which lane
    /// that names is resolution's problem.
    public static let ciInvocation = ObservationKind("core:ciInvocation")
    /// One authorship touch: this commit, by this author, changed
    /// this file. Literal — it says nothing about ownership.
    public static let authorship = ObservationKind("core:authorship")
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
