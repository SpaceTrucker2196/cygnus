import Foundation

// 3D force-directed layout for the RealityKit view. Same
// Fruchterman–Reingold shape as the 2D LayoutEngine, lifted to
// SIMD3; deterministic for a scene + seed. The 3D view renders the
// settled layout (progressive animation is a Flat-view feature for
// now).

public struct LayoutFrame3D: Sendable {
    public let positions: [String: SIMD3<Double>]
    public let settled: Bool

    public init(positions: [String: SIMD3<Double>], settled: Bool = true) {
        self.positions = positions
        self.settled = settled
    }

    /// Center on the centroid and scale so the farthest node sits at
    /// `radius`. Graph size varies by orders of magnitude; the camera
    /// frames a known radius instead of chasing the layout.
    public func normalized(toRadius radius: Double) -> LayoutFrame3D {
        guard !positions.isEmpty else { return self }
        let centroid = positions.values.reduce(SIMD3<Double>.zero, +)
            / Double(positions.count)
        var maxDistance = 0.0
        for position in positions.values {
            let d = position - centroid
            maxDistance = max(maxDistance, (d * d).sum().squareRoot())
        }
        let scale = maxDistance > 0 ? radius / maxDistance : 1
        return LayoutFrame3D(positions: positions.mapValues { ($0 - centroid) * scale },
                             settled: settled)
    }
}

public enum Layout3D {
    /// Iteration budget scaled to graph size: the O(n²) repulsion
    /// step is the wall-clock driver, and big graphs converge to a
    /// usable shape in fewer steps than small ones need for polish.
    public static func iterationBudget(nodeCount: Int) -> Int {
        switch nodeCount {
        case ..<200: 300
        case ..<600: 180
        default: 100
        }
    }

    /// Progressive frames from a detached solver — the renderer draws
    /// (and orbits) immediately while the layout settles, exactly
    /// like the Flat view's LayoutEngine.
    public static func frames(_ scene: GraphScene, seed: UInt64 = 0xC516,
                              initial: [String: SIMD3<Double>] = [:],
                              emitEvery: Int = 5) -> AsyncStream<LayoutFrame3D> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                solveSync(scene, seed: seed, initial: initial,
                          maxIterations: iterationBudget(nodeCount: scene.nodes.count),
                          emitEvery: emitEvery) { frame in
                    continuation.yield(frame)
                    return !Task.isCancelled
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

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
        var final = LayoutFrame3D(positions: [:], settled: true)
        solveSync(scene, seed: seed, maxIterations: maxIterations, emitEvery: maxIterations) {
            final = $0
            return true
        }
        return final
    }

    static func solveSync(_ scene: GraphScene, seed: UInt64,
                          initial: [String: SIMD3<Double>] = [:],
                          maxIterations: Int,
                          emitEvery: Int, emit: (LayoutFrame3D) -> Bool) {
        let ids = scene.nodes.map(\.id)
        let n = ids.count
        guard n > 0 else {
            _ = emit(LayoutFrame3D(positions: [:], settled: true))
            return
        }
        let indexByID = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let edges: [(Int, Int)] = scene.edges.compactMap {
            guard let a = indexByID[$0.from], let b = indexByID[$0.to], a != b else { return nil }
            return (a, b)
        }

        // Deterministic initial placement: jittered spiral on a sphere.
        var rng = SplitMix64(seed: seed)
        var seededCount = 0
        var pos = (0..<n).map { i -> SIMD3<Double> in
            if let prior = initial[ids[i]] {
                seededCount += 1
                return prior
            }
            let golden = 2 * Double.pi * Double(i) / 1.618_033_988_75
            let y = 1 - 2 * (Double(i) + 0.5) / Double(n)
            let r = (1 - y * y).squareRoot()
            let radius = 200.0 + Double(rng.next(upperBound: 1000)) / 20.0
            return SIMD3(radius * r * cos(golden), radius * y, radius * r * sin(golden))
        }

        let k = 60.0
        let cutoff = 2.5 * k
        let warmStarted = seededCount * 2 >= n
        var temperature = (warmStarted ? 0.03 : 0.12) * Double(n).squareRoot() * k
        struct Cell: Hashable { let x, y, z: Int }

        for iteration in 0..<maxIterations {
            var displacement = [SIMD3<Double>](repeating: .zero, count: n)

            var grid: [Cell: [Int]] = [:]
            grid.reserveCapacity(n)
            for i in 0..<n {
                grid[Cell(x: Int(pos[i].x / cutoff), y: Int(pos[i].y / cutoff),
                          z: Int(pos[i].z / cutoff)), default: []].append(i)
            }
            for i in 0..<n {
                let cell = Cell(x: Int(pos[i].x / cutoff), y: Int(pos[i].y / cutoff),
                                z: Int(pos[i].z / cutoff))
                for dx in -1...1 {
                    for dy in -1...1 {
                        for dz in -1...1 {
                            guard let bucket = grid[Cell(x: cell.x + dx, y: cell.y + dy,
                                                         z: cell.z + dz)] else { continue }
                            for j in bucket where j != i {
                                var delta = pos[i] - pos[j]
                                var distance = (delta * delta).sum().squareRoot()
                                if distance < 0.01 {
                                    delta = SIMD3(Double(rng.next(upperBound: 100)) / 100 - 0.5,
                                                  Double(rng.next(upperBound: 100)) / 100 - 0.5,
                                                  Double(rng.next(upperBound: 100)) / 100 - 0.5)
                                    distance = 0.87
                                }
                                guard distance < cutoff else { continue }
                                displacement[i] += delta * ((k * k / distance) / distance)
                            }
                        }
                    }
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

            let settled = maxStep < 0.5 || iteration == maxIterations - 1
            if settled || iteration % emitEvery == 0 {
                let frame = LayoutFrame3D(
                    positions: Dictionary(uniqueKeysWithValues: zip(ids, pos)),
                    settled: settled)
                if !emit(frame) || settled { return }
            }
        }
    }
}
