import Foundation
import simd

// Force layout in three dimensions, advanced a slice at a time.
//
// The previous 3D view was removed because "both 3D paths cost too much
// memory/time to render" (S5). The cost was never the triangles — a
// modern GPU is bored by ten thousand spheres. It was doing all the
// work before showing anything: settle the whole layout, build every
// buffer, then present. On a real repository that is seconds of a
// frozen window, which reads as a hang.
//
// So this never runs to completion in one call. `step()` advances a
// bounded number of iterations and returns; the renderer draws whatever
// exists and asks for another step. The view is on screen and moving
// within one frame of being opened, and settles visibly rather than
// appearing finished. Same total work, spread where it is not felt.
//
// Deterministic throughout: a seeded generator, fixed iteration counts,
// and molecule centres placed before any force runs. The same
// repository lays out identically every time it is opened, which is
// what makes a spatial memory of a codebase worth forming.

public struct Layout3D: Sendable {
    /// Positions by atom index, parallel to `MolecularScene.atoms`.
    public private(set) var positions: [SIMD3<Float>]
    /// Molecule centres, refined as their atoms move.
    public private(set) var centers: [SIMD3<Float>]
    public private(set) var iterationsRun = 0

    private let scene: MolecularScene
    private var velocities: [SIMD3<Float>]

    /// Iterations per `step()`. Enough to make visible progress in a
    /// frame, few enough that a frame is never dropped for it.
    public static let iterationsPerStep = 4
    /// Where the layout is called settled. Past this the motion is
    /// below a pixel and only costs battery.
    public static let totalIterations = 260

    public var isSettled: Bool { iterationsRun >= Self.totalIterations }
    /// 0…1, for a progress affordance while the scene assembles.
    public var progress: Float {
        min(1, Float(iterationsRun) / Float(Self.totalIterations))
    }

    public init(scene: MolecularScene, seed: UInt64 = 0xC5C1) {
        self.scene = scene
        var generator = SplitMix64(seed: seed)
        // Atoms start scattered around their molecule's seed centre, so
        // the first frame already shows the group structure and the
        // layout only has to refine it.
        positions = scene.atoms.map { atom in
            let center = scene.molecules[atom.molecule].seedCenter
            return center + SIMD3(generator.unitFloat(), generator.unitFloat(),
                                  generator.unitFloat()) * 3.5
        }
        velocities = Array(repeating: .zero, count: scene.atoms.count)
        centers = scene.molecules.map(\.seedCenter)
    }

    /// Advance the layout. Returns true while there is more to do.
    @discardableResult
    public mutating func step() -> Bool {
        guard !isSettled, !scene.atoms.isEmpty else { return false }
        for _ in 0..<Self.iterationsPerStep where !isSettled {
            iterate()
            iterationsRun += 1
        }
        return !isSettled
    }

    private mutating func iterate() {
        let count = positions.count
        var forces = [SIMD3<Float>](repeating: .zero, count: count)

        // Cohesion: an atom is pulled toward its own molecule's centre.
        // This is what makes a group read as an object rather than a
        // region — without it, bonds alone leave clusters smeared.
        for index in 0..<count {
            let center = centers[scene.atoms[index].molecule]
            forces[index] += (center - positions[index]) * 0.045
        }

        // Bonds pull. Internal bonds are stiffer, so a molecule holds
        // its shape while coupling between molecules stretches — the
        // visual signal that inter-group coupling is load-bearing.
        for bond in scene.bonds {
            let delta = positions[bond.to] - positions[bond.from]
            let distance = max(simd_length(delta), 0.001)
            let rest: Float = bond.isInternal ? 3.0 : 9.0
            let stiffness: Float = bond.isInternal ? 0.020 : 0.006
            let pull = (delta / distance) * (distance - rest) * stiffness
            forces[bond.from] += pull
            forces[bond.to] -= pull
        }

        // Repulsion, bucketed. All-pairs is O(n²) and is what makes a
        // naive 3D layout unusable past a few hundred nodes; a uniform
        // grid keeps it near-linear by only comparing neighbours, at
        // the cost of dropping long-range repulsion — which molecule
        // cohesion already supplies.
        let cell: Float = 6
        var buckets: [SIMD3<Int32>: [Int]] = [:]
        for index in 0..<count {
            buckets[Self.bucket(positions[index], cell), default: []].append(index)
        }
        for index in 0..<count {
            let home = Self.bucket(positions[index], cell)
            for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 {
                        let key = home &+ SIMD3(Int32(dx), Int32(dy), Int32(dz))
                        guard let neighbours = buckets[key] else { continue }
                        for other in neighbours where other != index {
                            let delta = positions[index] - positions[other]
                            let distance = max(simd_length(delta), 0.4)
                            guard distance < cell else { continue }
                            let minimum = scene.atoms[index].radius
                                + scene.atoms[other].radius + 0.6
                            let strength: Float = distance < minimum ? 2.2 : 0.7
                            forces[index] += (delta / distance)
                                * (strength / (distance * distance))
                        }
                    }
                }
            }
        }

        // Integrate with heavy damping. Velocity carries just enough to
        // let the structure unfold; more and it oscillates for hundreds
        // of frames without looking any better settled.
        let damping: Float = 0.82
        for index in 0..<count {
            velocities[index] = (velocities[index] + forces[index]) * damping
            positions[index] += simd_clamp(velocities[index],
                                           SIMD3(repeating: -2.5),
                                           SIMD3(repeating: 2.5))
        }

        // Molecule centres follow their atoms, so groups drift apart
        // rather than staying pinned to their seeds.
        var sums = [SIMD3<Float>](repeating: .zero, count: centers.count)
        var counts = [Float](repeating: 0, count: centers.count)
        for index in 0..<count {
            sums[scene.atoms[index].molecule] += positions[index]
            counts[scene.atoms[index].molecule] += 1
        }
        for molecule in 0..<centers.count where counts[molecule] > 0 {
            centers[molecule] = sums[molecule] / counts[molecule]
        }
    }

    static func bucket(_ position: SIMD3<Float>, _ cell: Float) -> SIMD3<Int32> {
        SIMD3(Int32(floorf(position.x / cell)),
              Int32(floorf(position.y / cell)),
              Int32(floorf(position.z / cell)))
    }

    /// The bounding radius, for framing the camera.
    public var extent: Float {
        guard !positions.isEmpty else { return 1 }
        let centroid = positions.reduce(SIMD3<Float>.zero, +) / Float(positions.count)
        return max(1, positions.map { simd_distance($0, centroid) }.max() ?? 1)
    }
}

/// The 2D layout's generator already exists and is already seeded the
/// same way; a second copy would be two things to keep in step.
extension SplitMix64 {
    /// −1…1.
    mutating func unitFloat() -> Float {
        Float(next() >> 40) / Float(1 << 23) * 2 - 1
    }
}
