import Foundation
import CygnusGraph

// Combining lexical and semantic results.
//
// Reciprocal rank fusion rather than score blending, because BM25 and
// cosine are not on the same scale and never will be — normalizing them
// against each other invents a comparison that does not exist. RRF only
// uses each list's *ordering*, which is the part both agree on.
//
// The published evidence is that grep-plus-semantic beats either alone,
// and the shape of the win is complementary failure: lexical misses the
// concept expressed in different words, semantic misses the exact
// identifier you already know. Fusing keeps both.

public enum HybridFusion {
    /// The RRF constant. 60 is the value from the original paper and
    /// the usual default; it damps the head of each list so a single
    /// confident-but-wrong first result cannot dominate.
    public static let k = 60.0

    /// A result's identity for fusion: two hits are the same finding
    /// when they land in the same file and overlap. Without this, a
    /// lexical hit at line 42 and a semantic hit covering 30–60 count
    /// twice and crowd out everything else.
    struct Key: Hashable {
        let repository: String
        let path: String
        let bucket: Int
    }

    static func key(_ result: RetrievalResult) -> Key {
        // Bucket by 60 lines so overlapping spans collapse without
        // needing interval arithmetic.
        Key(repository: result.repository.raw, path: result.path,
            bucket: (result.startLine - 1) / SourceWindows.windowLines)
    }

    /// Fuse ranked lists. `boost` adds to a result's fused score —
    /// this is where cross-file graph signal enters, having been kept
    /// deliberately out of the embedding itself.
    public static func fuse(_ lists: [[RetrievalResult]],
                            limit: Int,
                            boost: (RetrievalResult) -> Double = { _ in 0 })
        -> [RetrievalResult] {
        var scores: [Key: Double] = [:]
        var best: [Key: RetrievalResult] = [:]

        for list in lists {
            for (rank, result) in list.enumerated() {
                let key = key(result)
                scores[key, default: 0] += 1 / (Self.k + Double(rank + 1))
                // Keep the strongest evidence for a fused finding: a
                // compiler-resolved or lexical hit is a better thing to
                // show than an inferred one covering the same lines.
                if let existing = best[key] {
                    if evidenceRank(existing.resolution) > evidenceRank(result.resolution) {
                        best[key] = result
                    }
                } else {
                    best[key] = result
                }
            }
        }

        var fused: [(result: RetrievalResult, score: Double)] = []
        for (key, score) in scores {
            guard let result = best[key] else { continue }
            fused.append((result, score + boost(result)))
        }
        fused.sort { lhs, rhs in
            lhs.score == rhs.score
                ? lhs.result.citation < rhs.result.citation   // deterministic ties
                : lhs.score > rhs.score
        }
        return fused.prefix(limit).map(\.result)
    }

    /// Evidence strength, strongest first.
    private static func evidenceRank(_ resolution: Resolution) -> Int {
        switch resolution {
        case .compiler: return 0
        case .syntactic: return 1
        case .lexical: return 2
        case .semantic: return 3
        }
    }
}
