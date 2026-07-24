import Foundation

// Convex hull for the graph view's group regions. Regions are drawn
// as padded hulls around each cluster's node positions — the
// established convention for group membership at a glance (Graphviz
// clusters, Bubble Sets). Andrew's monotone chain: O(n log n),
// degenerate inputs (0–2 points, collinear sets) return what they can.

public enum ConvexHull {
    /// Hull vertices in counter-clockwise order. Fewer than three
    /// input points come back unchanged (point or segment).
    public static func hull(of points: [SIMD2<Double>]) -> [SIMD2<Double>] {
        guard points.count > 2 else { return points }
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }

        func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        func half(_ sequence: [SIMD2<Double>]) -> [SIMD2<Double>] {
            var chain: [SIMD2<Double>] = []
            for point in sequence {
                while chain.count >= 2,
                      cross(chain[chain.count - 2], chain[chain.count - 1], point) <= 0 {
                    chain.removeLast()
                }
                chain.append(point)
            }
            chain.removeLast()   // endpoint repeats in the other half
            return chain
        }
        let lower = half(sorted)
        let upper = half(sorted.reversed())
        return lower + upper
    }
}
