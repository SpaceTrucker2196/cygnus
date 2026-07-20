import Foundation

// 3D force-directed layout for the RealityKit view. Same
// Fruchterman–Reingold shape as the 2D LayoutEngine, lifted to
// SIMD3; deterministic for a scene + seed. The 3D view renders the
// settled layout (progressive animation is a Flat-view feature for
// now).

public struct LayoutFrame3D: Sendable {
    public let positions: [String: SIMD3<Double>]
    public init(positions: [String: SIMD3<Double>]) {
        self.positions = positions
    }
}

public enum Layout3D {
    /// Solve to a settled frame off the main actor.
    public static func solve(_ scene: GraphScene, seed: UInt64 = 0xC516,
                             maxIterations: Int = 300) async -> LayoutFrame3D {
        let solved = await Task.detached(priority: .userInitiated) {
            solveSync(scene, seed: seed, maxIterations: maxIterations)
        }.value
        return solved
    }

    public static func solveSync(_ scene: GraphScene, seed: UInt64,
                          maxIterations: Int) -> LayoutFrame3D {
        let ids = scene.nodes.map(\.id)
        let n = ids.count
        guard n > 0 else { return LayoutFrame3D(positions: [:]) }
        let indexByID = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let edges: [(Int, Int)] = scene.edges.compactMap {
            guard let a = indexByID[$0.from], let b = indexByID[$0.to], a != b else { return nil }
            return (a, b)
        }

        // Deterministic initial placement: jittered spiral on a sphere.
        var rng = SplitMix64(seed: seed)
        var pos = (0..<n).map { i -> SIMD3<Double> in
            let golden = 2 * Double.pi * Double(i) / 1.618_033_988_75
            let y = 1 - 2 * (Double(i) + 0.5) / Double(n)
            let r = (1 - y * y).squareRoot()
            let radius = 200.0 + Double(rng.next(upperBound: 1000)) / 20.0
            return SIMD3(radius * r * cos(golden), radius * y, radius * r * sin(golden))
        }

        let k = 60.0
        var temperature = 0.12 * Double(n).squareRoot() * k

        for _ in 0..<maxIterations {
            var displacement = [SIMD3<Double>](repeating: .zero, count: n)

            for i in 0..<n {
                for j in (i + 1)..<n {
                    var delta = pos[i] - pos[j]
                    var distance = (delta * delta).sum().squareRoot()
                    if distance < 0.01 {
                        delta = SIMD3(Double(rng.next(upperBound: 100)) / 100 - 0.5,
                                      Double(rng.next(upperBound: 100)) / 100 - 0.5,
                                      Double(rng.next(upperBound: 100)) / 100 - 0.5)
                        distance = 0.87
                    }
                    let force = (k * k / distance) / distance
                    displacement[i] += delta * force
                    displacement[j] -= delta * force
                }
            }

            for (a, b) in edges {
                let delta = pos[a] - pos[b]
                let distance = max((delta * delta).sum().squareRoot(), 0.01)
                let force = distance / k
                displacement[a] -= delta * force
                displacement[b] += delta * force
            }

            var maxStep = 0.0
            for i in 0..<n {
                displacement[i] -= pos[i] * 0.03
                let length = max((displacement[i] * displacement[i]).sum().squareRoot(), 0.01)
                let step = min(length, temperature)
                pos[i] += displacement[i] / length * step
                maxStep = max(maxStep, step)
            }
            temperature = max(temperature * 0.95, 1.0)
            if maxStep < 0.5 { break }
        }

        return LayoutFrame3D(positions: Dictionary(uniqueKeysWithValues: zip(ids, pos)))
    }
}
