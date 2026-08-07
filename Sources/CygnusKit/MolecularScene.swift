import Foundation
import simd

// The 3D projection: groups become molecules, nodes become atoms,
// edges become bonds.
//
// The metaphor is doing real work rather than decoration. A molecular
// viewer's whole visual grammar is "tightly bound clusters, loosely
// coupled to each other", which is exactly the question an architecture
// diagram is asked — and it reads at a glance in a way a hairball of
// equal-length edges never does. Bonds inside a molecule are short and
// thick; bonds between molecules are long and thin, so coupling across
// module boundaries is visible as strain rather than as one more line.
//
// This file is deliberately GPU-free. Everything here is values a test
// can assert on; the renderer only turns them into triangles. That
// separation is why 3D can be tested at all this time — the previous
// 3D attempt lived entirely in the view layer and was removed without
// anything being able to say whether it was correct.

public struct MolecularScene: Sendable, Equatable {
    /// One atom: a node, its molecule, and how big it should be.
    public struct Atom: Sendable, Equatable {
        public let id: String
        public let label: String
        /// Index into `molecules`.
        public let molecule: Int
        /// Derived from degree — hubs are visibly larger, the same
        /// convention the 2D view uses so the two agree.
        public let radius: Float
        public let kind: String
    }

    /// A bond between two atoms.
    public struct Bond: Sendable, Equatable {
        public let from: Int          // index into `atoms`
        public let to: Int
        /// Both endpoints in the same molecule. Intra-molecular bonds
        /// are the structure; inter-molecular ones are the coupling.
        public let isInternal: Bool
    }

    /// A group, rendered as a cluster of atoms.
    public struct Molecule: Sendable, Equatable {
        public let name: String
        public let atomCount: Int
        /// Placed deterministically before any force layout runs, so a
        /// scene looks the same every time it is opened.
        public let seedCenter: SIMD3<Float>
    }

    public let atoms: [Atom]
    public let bonds: [Bond]
    public let molecules: [Molecule]

    public var isEmpty: Bool { atoms.isEmpty }

    /// Build from the same scene and grouping the 2D view uses, so the
    /// two never disagree about what a group is.
    public init(scene: GraphScene, grouping: GraphScene.Grouping) {
        let clusters = scene.clusters(grouping: grouping)

        // Molecule order is alphabetical, not dictionary order, so
        // seed positions are stable across runs.
        var names = Array(Set(scene.nodes.map { clusters[$0.id] ?? "—" })).sorted()
        if names.isEmpty { names = ["—"] }
        let indexOf = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })

        var counts = [Int](repeating: 0, count: names.count)
        var atoms: [Atom] = []
        var atomIndex: [String: Int] = [:]
        atoms.reserveCapacity(scene.nodes.count)

        for node in scene.nodes.sorted(by: { $0.id < $1.id }) {
            let molecule = indexOf[clusters[node.id] ?? "—"] ?? 0
            counts[molecule] += 1
            atomIndex[node.id] = atoms.count
            atoms.append(Atom(
                id: node.id,
                label: node.label,
                molecule: molecule,
                radius: Self.radius(forDegree: scene.degree[node.id] ?? 0),
                kind: node.kind))
        }

        var bonds: [Bond] = []
        bonds.reserveCapacity(scene.edges.count)
        var seen = Set<Int64>()
        for edge in scene.edges {
            guard let from = atomIndex[edge.from], let to = atomIndex[edge.to],
                  from != to else { continue }
            // One bond per pair: a doubled bond is invisible and costs
            // a draw call.
            let key = Int64(min(from, to)) << 32 | Int64(max(from, to))
            guard seen.insert(key).inserted else { continue }
            bonds.append(Bond(from: from, to: to,
                              isInternal: atoms[from].molecule == atoms[to].molecule))
        }

        self.atoms = atoms
        self.bonds = bonds
        self.molecules = names.enumerated().map { index, name in
            Molecule(name: name, atomCount: counts[index],
                     seedCenter: Self.fibonacciPoint(index, of: names.count))
        }
    }

    /// Cube-root growth: a node with 100 connections is larger than one
    /// with 10, but not ten times larger, or one hub would fill the
    /// scene and hide everything it connects to.
    static func radius(forDegree degree: Int) -> Float {
        let base: Float = 0.5
        return base * (1 + powf(Float(degree), 1.0 / 3.0) * 0.55)
    }

    /// Molecule centres on a Fibonacci sphere — even spacing with no
    /// clumping at the poles, and deterministic given the count. The
    /// force layout refines these; starting them spread out is what
    /// keeps it from having to untangle a single knot.
    static func fibonacciPoint(_ index: Int, of count: Int) -> SIMD3<Float> {
        guard count > 1 else { return .zero }
        let golden = Float.pi * (3 - sqrtf(5))
        let y = 1 - (Float(index) / Float(count - 1)) * 2
        let radius = sqrtf(max(0, 1 - y * y))
        let theta = golden * Float(index)
        let scale = 14 + Float(count) * 0.9
        return SIMD3(cosf(theta) * radius, y, sinf(theta) * radius) * scale
    }
}
