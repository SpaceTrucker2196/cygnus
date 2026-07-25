import Foundation

// Renderer-agnostic force-directed layout. Runs off the main actor,
// emits progressive frames (the renderer animates toward the latest),
// is cancellable, and is deterministic for a given scene + seed so
// layouts are testable and stable across runs.
//
// Fruchterman–Reingold with cooling. Repulsion uses a uniform spatial
// grid with a cutoff radius — near-linear per step — so debug builds
// stay fluid at real-repo scale. Warm-start: pass previous positions
// and new nodes join a stable layout instead of restarting it.

public struct LayoutFrame: Sendable {
    public let positions: [String: SIMD2<Double>]
    public let settled: Bool

    public static let empty = LayoutFrame(positions: [:], settled: false)

    public init(positions: [String: SIMD2<Double>], settled: Bool) {
        self.positions = positions
        self.settled = settled
    }
}

public struct LayoutEngine: Sendable {
    private let scene: GraphScene
    private let seed: UInt64
    private let initial: [String: SIMD2<Double>]
    private let clusters: [String: String]
    private let focusCluster: String?

    public init(scene: GraphScene, seed: UInt64 = 0xC516,
                initial: [String: SIMD2<Double>] = [:],
                clusters: [String: String] = [:],
                focusCluster: String? = nil) {
        self.scene = scene
        self.seed = seed
        self.initial = initial
        self.clusters = clusters
        self.focusCluster = focusCluster
    }

    /// Progressive layout frames, ending with a settled frame (or on
    /// cancellation). Solving runs detached off the main actor.
    /// Buffering keeps only the newest frame: a renderer that falls
    /// behind skips straight to the latest layout — stale frames are
    /// never queued (each one is a full position table; queueing them
    /// is how memory blows up on big graphs).
    public func frames(maxIterations: Int = 300,
                       emitEvery: Int = 5) -> AsyncStream<LayoutFrame> {
        let scene = self.scene
        let seed = self.seed
        let initial = self.initial
        let clusters = self.clusters
        let focusCluster = self.focusCluster
        return AsyncStream(LayoutFrame.self, bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                Self.run(scene: scene, seed: seed, initial: initial, clusters: clusters,
                         focusCluster: focusCluster,
                         maxIterations: maxIterations, emitEvery: emitEvery) { frame in
                    continuation.yield(frame)
                    return !Task.isCancelled
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Synchronous solver core. `emit` returns false to stop early.
    static func run(scene: GraphScene, seed: UInt64,
                    initial: [String: SIMD2<Double>] = [:],
                    clusters: [String: String] = [:],
                    focusCluster: String? = nil,
                    maxIterations: Int, emitEvery: Int,
                    emit: (LayoutFrame) -> Bool) {
        let ids = scene.nodes.map(\.id)
        let n = ids.count
        guard n > 0 else {
            _ = emit(LayoutFrame(positions: [:], settled: true))
            return
        }
        let indexByID = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let edges: [(Int, Int)] = scene.edges.compactMap {
            guard let a = indexByID[$0.from], let b = indexByID[$0.to], a != b else { return nil }
            return (a, b)
        }

        // Deterministic initial placement: warm-start from prior
        // positions where available, jittered ring for new nodes.
        var rng = SplitMix64(seed: seed)
        var seededCount = 0
        var pos = (0..<n).map { i -> SIMD2<Double> in
            if let prior = initial[ids[i]] {
                seededCount += 1
                return prior
            }
            let angle = 2 * .pi * Double(i) / Double(n)
            let radius = 200.0 + Double(rng.next(upperBound: 1000)) / 20.0
            return SIMD2(radius * cos(angle), radius * sin(angle))
        }

        let k = 60.0
        let cutoff = 2.5 * k

        // Cluster anchors: one fixed point per group, on a ring whose
        // radius grows with graph size. Anchors depend only on the
        // sorted group names — the same groups always land in the same
        // directions, so users keep their spatial memory across
        // re-analyses and grouping toggles (software-cartography
        // stability, the Kuhn/ELK "consistent layout" principle).
        let groupNames = Set(clusters.values).sorted()
        var anchorByGroup: [String: SIMD2<Double>] = [:]
        if let focus = focusCluster, groupNames.contains(focus) {
            // Explode around a chosen group: it sits at the center, the
            // rest ring around it at a wide radius. Reading one group's
            // relationship to everything else.
            anchorByGroup[focus] = .zero
            let others = groupNames.filter { $0 != focus }
            let ringRadius = max(4.0 * k, 1.3 * k * Double(n).squareRoot())
            for (index, name) in others.enumerated() {
                let angle = 2 * .pi * Double(index) / Double(max(others.count, 1))
                anchorByGroup[name] = SIMD2(ringRadius * cos(angle),
                                            ringRadius * sin(angle))
            }
        } else if groupNames.count == 1 {
            anchorByGroup[groupNames[0]] = .zero
        } else {
            let ringRadius = max(2.0 * k, 0.75 * k * Double(n).squareRoot())
            for (index, name) in groupNames.enumerated() {
                let angle = 2 * .pi * Double(index) / Double(groupNames.count)
                anchorByGroup[name] = SIMD2(ringRadius * cos(angle),
                                            ringRadius * sin(angle))
            }
        }
        let anchorForNode: [SIMD2<Double>?] = ids.map { id in
            clusters[id].flatMap { anchorByGroup[$0] }
        }
        // Toward the anchor per step; strong enough to overcome
        // cross-group edge springs, weak enough that intra-group
        // structure still comes from edges and repulsion.
        let clusterPull = 0.08

        let warmStarted = seededCount * 2 >= n
        var temperature = (warmStarted ? 0.03 : 0.12) * Double(n).squareRoot() * k
        let settleThreshold = 0.5
        // Emitting allocates a full position table — rate-limit it.
        let clock = ContinuousClock()
        var lastEmit = clock.now - .seconds(1)

        struct Cell: Hashable { let x, y: Int }

        for iteration in 0..<maxIterations {
            var displacement = [SIMD2<Double>](repeating: .zero, count: n)

            // Grid-bucketed repulsion: only pairs within the cutoff
            // interact; one-sided accumulation over neighbor cells.
            var grid: [Cell: [Int]] = [:]
            grid.reserveCapacity(n)
            for i in 0..<n {
                grid[Cell(x: Int(pos[i].x / cutoff), y: Int(pos[i].y / cutoff)), default: []]
                    .append(i)
            }
            for i in 0..<n {
                let cell = Cell(x: Int(pos[i].x / cutoff), y: Int(pos[i].y / cutoff))
                for dx in -1...1 {
                    for dy in -1...1 {
                        guard let bucket = grid[Cell(x: cell.x + dx, y: cell.y + dy)]
                        else { continue }
                        for j in bucket where j != i {
                            var delta = pos[i] - pos[j]
                            var distance = (delta * delta).sum().squareRoot()
                            if distance < 0.01 {
                                delta = SIMD2(Double(rng.next(upperBound: 100)) / 100 - 0.5,
                                              Double(rng.next(upperBound: 100)) / 100 - 0.5)
                                distance = 0.71
                            }
                            guard distance < cutoff else { continue }
                            displacement[i] += delta * ((k * k / distance) / distance)
                        }
                    }
                }
            }

            for (a, b) in edges {
                let delta = pos[a] - pos[b]
                let distance = max((delta * delta).sum().squareRoot(), 0.01)
                let force = (distance / k)
                displacement[a] -= delta * force
                displacement[b] += delta * force
            }

            var maxStep = 0.0
            for i in 0..<n {
                if let anchor = anchorForNode[i] {
                    // Grouped: cohere around the group's fixed anchor.
                    displacement[i] += (anchor - pos[i]) * clusterPull
                } else {
                    // Gentle gravity keeps disconnected components on screen.
                    displacement[i] -= pos[i] * 0.03
                }
                let length = max((displacement[i] * displacement[i]).sum().squareRoot(), 0.01)
                let step = min(length, temperature)
                pos[i] += displacement[i] / length * step
                maxStep = max(maxStep, step)
            }
            temperature = max(temperature * 0.95, 1.0)

            let settled = maxStep < settleThreshold || iteration == maxIterations - 1
            let due = iteration % emitEvery == 0
                && clock.now - lastEmit >= .milliseconds(80)
            if settled || due {
                lastEmit = clock.now
                let frame = LayoutFrame(
                    positions: Dictionary(uniqueKeysWithValues: zip(ids, pos)),
                    settled: settled)
                if !emit(frame) || settled { return }
            }
        }
    }
}

/// Deterministic RNG (same algorithm as the store benchmark).
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(upperBound: UInt64) -> UInt64 { next() % upperBound }
}
