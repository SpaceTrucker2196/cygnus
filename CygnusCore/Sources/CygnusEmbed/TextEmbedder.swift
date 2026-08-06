import Foundation

// The embedding seam.
//
// One protocol, so the store, the chunker and the search path never
// learn which model produced a vector — and so tests can run the whole
// pipeline deterministically without a model artifact existing.
//
// Model identity is part of that contract. A vector is only comparable
// to another vector from the same model, so `identity` is written into
// every stored row and every query filters on it. Re-converting a model
// with different settings yields a different identity, which means the
// old vectors simply stop matching rather than silently polluting the
// space with incomparable numbers. Failing visibly beats mixing
// embedding spaces.

public struct EmbedderIdentity: Sendable, Hashable {
    public let name: String
    /// Short hash of the converted artifact. Two conversions of the
    /// same weights with different settings are different embedders.
    public let revision: String
    public let dimension: Int

    public init(name: String, revision: String, dimension: Int) {
        self.name = name
        self.revision = revision
        self.dimension = dimension
    }

    /// What lands in `retrieval_vector.model`.
    public var storageKey: String { "\(name)@\(revision)" }
}

public protocol TextEmbedder: Sendable {
    var identity: EmbedderIdentity { get }

    /// Embed a batch. Returns L2-normalized vectors in input order, so
    /// cosine similarity collapses to a dot product downstream.
    func embed(_ texts: [String]) async throws -> [[Float]]
}

extension TextEmbedder {
    public func embed(_ text: String) async throws -> [Float] {
        try await embed([text]).first ?? []
    }
}

public enum EmbedderError: Error, Equatable {
    case modelNotFound(String)
    case vocabularyNotFound(String)
    case malformedDescriptor(String)
    case shapeMismatch(expected: Int, got: Int)
}
