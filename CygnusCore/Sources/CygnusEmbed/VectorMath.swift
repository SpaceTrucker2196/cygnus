import Foundation
import Accelerate

// Similarity search, done by multiplying the whole matrix at once.
//
// There is no ANN index here and that is deliberate (DECISIONS.md D6):
// the factory corpus is ~13k chunks, so an exact pass over every vector
// is a single `cblas_sgemv` — memory-bound, low single-digit
// milliseconds — and an approximate index would trade exact recall and
// a new C dependency for time already inside budget.
//
// Vectors are stored L2-normalized, so cosine similarity *is* the dot
// product and the whole search is one matrix-vector multiply.

public enum VectorMath {
    /// Normalize in place to unit length. A zero vector stays zero
    /// rather than becoming NaN — an empty chunk should score zero
    /// against everything, not poison the results.
    public static func normalize(_ vector: inout [Float]) {
        var sumOfSquares: Float = 0
        vDSP_svesq(vector, 1, &sumOfSquares, vDSP_Length(vector.count))
        guard sumOfSquares > 0 else { return }
        var inverse = 1 / sqrtf(sumOfSquares)
        vDSP_vsmul(vector, 1, &inverse, &vector, 1, vDSP_Length(vector.count))
    }

    public static func normalized(_ vector: [Float]) -> [Float] {
        var copy = vector
        normalize(&copy)
        return copy
    }

    /// Top-k by cosine similarity against a row-major matrix of
    /// `count` × `dimension` normalized vectors.
    ///
    /// `allowed`, when given, restricts scoring to those row indices —
    /// this is how a repository or path filter applies without a second
    /// pass over SQL, since the caller already knows which rows survive.
    public static func topK(query: [Float],
                            matrix: [Float],
                            dimension: Int,
                            k: Int,
                            allowed: Set<Int>? = nil) -> [(index: Int, score: Float)] {
        guard dimension > 0, k > 0, query.count == dimension else { return [] }
        let rows = matrix.count / dimension
        guard rows > 0 else { return [] }

        var scores = [Float](repeating: 0, count: rows)
        // One multiply for the entire corpus: (rows × dim) · (dim × 1).
        // vDSP_mmul rather than cblas_sgemv — the CBLAS entry point is
        // deprecated in favour of an ILP64 interface that needs build
        // flags, and this package is warning-clean.
        vDSP_mmul(matrix, 1, query, 1, &scores, 1,
                  vDSP_Length(rows), 1, vDSP_Length(dimension))

        var ranked = (0..<rows).compactMap { index -> (index: Int, score: Float)? in
            if let allowed, !allowed.contains(index) { return nil }
            return (index, scores[index])
        }
        // Ties break on index so results are byte-identical run to run;
        // truncation downstream must always drop the same rows.
        ranked.sort { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
        return Array(ranked.prefix(k))
    }

    /// Pack normalized vectors into the flat row-major buffer `topK`
    /// expects.
    public static func pack(_ vectors: [[Float]], dimension: Int) -> [Float] {
        var matrix = [Float]()
        matrix.reserveCapacity(vectors.count * dimension)
        for vector in vectors {
            precondition(vector.count == dimension, "ragged vector matrix")
            matrix.append(contentsOf: vector)
        }
        return matrix
    }

    /// Float32 → little-endian bytes for BLOB storage, and back.
    public static func encode(_ vector: [Float]) -> Data {
        var copy = vector
        return copy.withUnsafeMutableBufferPointer { Data(buffer: $0) }
    }

    public static func decode(_ data: Data, dimension: Int) -> [Float]? {
        guard data.count == dimension * MemoryLayout<Float>.size else { return nil }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }
}
