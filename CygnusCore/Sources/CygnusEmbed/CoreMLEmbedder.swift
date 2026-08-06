import Foundation
import CoreML

// The real embedder: a converted transformer encoder run through Core
// ML.
//
// Core ML rather than mlx-swift, and the reason is dependency weight
// rather than capability. Core ML is a system framework, so this adds
// nothing to Package.swift; mlx-swift is a large Swift + C++/Metal
// package with no semver guarantee, and its strengths — dynamic graphs,
// quantized generation — are irrelevant to a small encoder. ANE
// execution also keeps the CPU free while indexing is running.
//
// An actor because MLModel is not Sendable and this package is strict
// concurrency with no `nonisolated(unsafe)` escape hatch.

public actor CoreMLEmbedder: TextEmbedder {
    public nonisolated let identity: EmbedderIdentity

    private let model: MLModel
    private let tokenizer: WordPiece
    private let descriptor: EmbedderDescriptor

    /// Load from a directory holding `model.mlmodelc`, `vocab.txt` and
    /// `descriptor.json` — the layout `tools/convert-embedder.py`
    /// produces.
    public init(directory: URL) throws {
        let descriptor = try EmbedderLocator.descriptor(at: directory)
        let compiled = directory.appendingPathComponent("model.mlmodelc")
        guard FileManager.default.fileExists(atPath: compiled.path) else {
            throw EmbedderError.modelNotFound(compiled.path)
        }
        let configuration = MLModelConfiguration()
        // All available: let Core ML place it on the Neural Engine when
        // it can, CPU when it cannot, rather than forcing either.
        configuration.computeUnits = .all

        self.model = try MLModel(contentsOf: compiled, configuration: configuration)
        self.tokenizer = try WordPiece(
            vocabularyFile: directory.appendingPathComponent("vocab.txt"),
            maxTokens: descriptor.maxTokens)
        self.descriptor = descriptor
        self.identity = descriptor.identity
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        try texts.map { text in
            try embedOne(descriptor.documentPrefix + text)
        }
    }

    /// Queries take the query prefix, not the document one. Model
    /// families disagree about these strings, and using the wrong one
    /// measurably degrades recall — which is why they are shipped as
    /// data beside the weights rather than hardcoded.
    public func embedQuery(_ text: String) throws -> [Float] {
        try embedOne(descriptor.queryPrefix + text)
    }

    private func embedOne(_ text: String) throws -> [Float] {
        let encoded = tokenizer.encode(text)
        let length = encoded.ids.count

        let ids = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
        for (index, id) in encoded.ids.enumerated() {
            ids[index] = NSNumber(value: id)
            mask[index] = NSNumber(value: encoded.mask[index])
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: ids),
            "attention_mask": MLFeatureValue(multiArray: mask),
        ])
        let output = try model.prediction(from: input)

        guard let name = output.featureNames.first(where: {
                  output.featureValue(for: $0)?.multiArrayValue != nil
              }),
              let hidden = output.featureValue(for: name)?.multiArrayValue else {
            throw EmbedderError.shapeMismatch(expected: descriptor.dimension, got: 0)
        }
        return VectorMath.normalized(Self.meanPool(hidden, mask: encoded.mask,
                                                   dimension: descriptor.dimension))
    }

    /// Mean-pool the token embeddings over the attention mask.
    /// Averaging over padding as well would drag every vector toward
    /// whatever the pad token encodes, which is the classic way to get
    /// a model that scores everything as similar to everything.
    static func meanPool(_ hidden: MLMultiArray, mask: [Int32],
                         dimension: Int) -> [Float] {
        var summed = [Float](repeating: 0, count: dimension)
        var counted: Float = 0
        let tokens = min(mask.count, hidden.count / max(dimension, 1))

        for token in 0..<tokens where mask[token] == 1 {
            counted += 1
            let base = token * dimension
            for component in 0..<dimension {
                summed[component] += hidden[base + component].floatValue
            }
        }
        guard counted > 0 else { return summed }
        return summed.map { $0 / counted }
    }
}
