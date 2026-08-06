import Foundation
import CygnusGraph

// The universal result value. Every tier produces these, so an agent
// learns one shape — and, more importantly, every result says how it
// was found. MISSION invariant 9 requires observed, derived and
// inferred to be visibly distinct; at the retrieval boundary that
// means a lexical guess can never be mistaken for a compiler-resolved
// fact, however convenient that would be to render.

/// How a result was arrived at. Ordered weakest-evidence last.
public enum Resolution: String, Sendable, Hashable {
    /// The compiler resolved it (index store).
    case compiler
    /// A parser saw it in this file.
    case syntactic
    /// A text match. Says nothing about meaning.
    case lexical
    /// Embedding similarity. Heuristic; always carries a score.
    case semantic
}

public struct RetrievalResult: Sendable, Hashable {
    public let repository: RepositoryID
    /// Repository display name, for citations an agent can act on.
    public let repositoryName: String
    public let path: String
    public let startLine: Int
    public let endLine: Int
    /// The graph entity enclosing this span, when one does.
    public let stableKey: StableKey?
    public let entityKind: EntityKind?
    public let layer: KnowledgeLayer
    public let resolution: Resolution
    /// Present for heuristic resolutions, absent for facts.
    public let score: Double?
    public let snippet: String?

    public init(repository: RepositoryID, repositoryName: String, path: String,
                startLine: Int, endLine: Int, stableKey: StableKey? = nil,
                entityKind: EntityKind? = nil, layer: KnowledgeLayer,
                resolution: Resolution, score: Double? = nil, snippet: String? = nil) {
        self.repository = repository
        self.repositoryName = repositoryName
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
        self.stableKey = stableKey
        self.entityKind = entityKind
        self.layer = layer
        self.resolution = resolution
        self.score = score
        self.snippet = snippet
    }

    /// `repo/path:start-end` — copyable straight into a read tool.
    public var citation: String {
        startLine == endLine
            ? "\(repositoryName)/\(path):\(startLine)"
            : "\(repositoryName)/\(path):\(startLine)-\(endLine)"
    }
}
