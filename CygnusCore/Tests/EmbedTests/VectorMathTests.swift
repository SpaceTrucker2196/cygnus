import Testing
import Foundation
@testable import CygnusEmbed

// Similarity search is one matrix multiply, so if the multiply is
// wrong every semantic result is wrong in a way that still looks
// plausible. These check it against a naive reference.

@Suite struct VectorMathTests {
    private func reference(_ query: [Float], _ row: [Float]) -> Float {
        zip(query, row).reduce(0) { $0 + $1.0 * $1.1 }
    }

    @Test func normalizationProducesUnitLength() {
        var vector: [Float] = [3, 4]
        VectorMath.normalize(&vector)
        #expect(abs(vector[0] - 0.6) < 0.0001)
        #expect(abs(vector[1] - 0.8) < 0.0001)
    }

    /// A zero vector must stay zero rather than becoming NaN — an empty
    /// chunk should score nothing, not poison every comparison.
    @Test func aZeroVectorSurvivesNormalization() {
        var vector: [Float] = [0, 0, 0]
        VectorMath.normalize(&vector)
        #expect(vector == [0, 0, 0])
    }

    @Test func topKMatchesANaiveDotProduct() {
        let dimension = 8
        let rows = 50
        // Deterministic pseudo-random, so a failure reproduces.
        var seed: UInt64 = 42
        func next() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(seed >> 33) / Float(UInt32.max) - 0.5
        }
        let vectors = (0..<rows).map { _ in
            VectorMath.normalized((0..<dimension).map { _ in next() })
        }
        let query = VectorMath.normalized((0..<dimension).map { _ in next() })
        let matrix = VectorMath.pack(vectors, dimension: dimension)

        let top = VectorMath.topK(query: query, matrix: matrix, dimension: dimension, k: 5)

        var scored: [(index: Int, score: Float)] = []
        for (index, vector) in vectors.enumerated() {
            scored.append((index, reference(query, vector)))
        }
        scored.sort { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
        let expected = Array(scored.prefix(5))

        #expect(top.map(\.index) == expected.map(\.index))
        for (actual, want) in zip(top, expected) {
            #expect(abs(actual.score - want.score) < 0.0001)
        }
    }

    /// An identical vector is the best possible match.
    @Test func anExactMatchScoresOne() {
        let vector = VectorMath.normalized([1, 2, 3, 4])
        let matrix = VectorMath.pack([vector], dimension: 4)
        let top = VectorMath.topK(query: vector, matrix: matrix, dimension: 4, k: 1)
        #expect(abs((top.first?.score ?? 0) - 1) < 0.0001)
    }

    /// The scope filter is how a repository or path restriction applies
    /// without a second pass over SQL.
    @Test func theAllowedSetRestrictsScoring() {
        let vectors = [[1, 0], [0, 1], [1, 0]].map { VectorMath.normalized($0.map(Float.init)) }
        let matrix = VectorMath.pack(vectors, dimension: 2)
        let top = VectorMath.topK(query: [1, 0], matrix: matrix, dimension: 2,
                                  k: 5, allowed: [1, 2])
        #expect(Set(top.map(\.index)) == [1, 2])
    }

    /// Ties break on index, so truncation drops the same rows every run.
    @Test func tiesBreakDeterministically() {
        let vectors = Array(repeating: VectorMath.normalized([1, 1]), count: 4)
        let matrix = VectorMath.pack(vectors, dimension: 2)
        let runs = (0..<3).map { _ in
            VectorMath.topK(query: VectorMath.normalized([1, 1]),
                            matrix: matrix, dimension: 2, k: 3).map(\.index)
        }
        #expect(runs[0] == [0, 1, 2])
        #expect(runs[0] == runs[1] && runs[1] == runs[2])
    }

    @Test func blobEncodingRoundTrips() {
        let vector = VectorMath.normalized([0.5, -0.25, 0.125, 1])
        let decoded = VectorMath.decode(VectorMath.encode(vector), dimension: 4)
        #expect(decoded == vector)
    }

    /// A truncated or wrong-dimension BLOB decodes to nil rather than
    /// garbage — a corrupt row must not become a plausible vector.
    @Test func aMalformedBlobDecodesToNil() {
        #expect(VectorMath.decode(Data([1, 2, 3]), dimension: 4) == nil)
        #expect(VectorMath.decode(VectorMath.encode([1, 2]), dimension: 4) == nil)
    }

    @Test func anEmptyCorpusReturnsNothingRatherThanCrashing() {
        #expect(VectorMath.topK(query: [1, 0], matrix: [], dimension: 2, k: 5).isEmpty)
    }
}
