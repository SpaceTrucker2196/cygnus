import Foundation

// Metrics tracked across revisions. *Kill It With Fire* argues that a
// modernization needs a measurable problem — "objective and
// irrefutable" — because it is what lets anyone see whether things are
// getting better without waiting for a feature launch. A snapshot
// answers "how is it now"; only a series answers "is this working".

/// A number worth watching move.
public enum GraphMetric: String, CaseIterable, Sendable, Identifiable {
    case nodes = "Nodes"
    case edges = "Edges"
    case cycles = "Cyclic edges"
    case orphans = "Unconnected"

    public var id: String { rawValue }

    /// What a rising line means. Shown next to the chart so a trend is
    /// not silently read the wrong way — more nodes is growth, more
    /// cycles is decay.
    public var risingIsGood: Bool? {
        switch self {
        case .nodes, .edges: nil        // neither, on its own
        case .cycles, .orphans: false
        }
    }

    public func value(in scene: GraphScene) -> Int {
        switch self {
        case .nodes: scene.nodes.count
        case .edges: scene.edges.count
        case .cycles: scene.cyclicEdges.count
        // Charted but wired to nothing: the graph's version of the
        // book's "forgotten and lost" code.
        case .orphans: scene.nodes.filter { (scene.degree[$0.id] ?? 0) == 0 }.count
        }
    }
}

/// One metric's value at one revision.
public struct TrendPoint: Sendable, Equatable, Identifiable {
    public let revision: Int64
    public let createdAt: Date
    public let value: Int
    public var id: Int64 { revision }

    public init(revision: Int64, createdAt: Date, value: Int) {
        self.revision = revision
        self.createdAt = createdAt
        self.value = value
    }
}

public enum GraphTrend {
    /// How many revisions back a trend reaches. Each point costs a
    /// full historical projection, so this is a real cost, not a
    /// display choice — and a long tail of ancient revisions rarely
    /// changes what the recent shape tells you.
    public static let defaultWindow = 20

    /// Build one metric's series from already-projected snapshots.
    /// Pure, so the arithmetic tests without a store.
    public static func series(_ metric: GraphMetric,
                              over snapshots: [(revision: GraphRevision,
                                                snapshot: GraphSnapshot)],
                              showExternal: Bool = false) -> [TrendPoint] {
        snapshots.map { entry in
            let scene = GraphScene.dependencies(from: entry.snapshot,
                                                showExternal: showExternal)
            return TrendPoint(revision: entry.revision.id,
                              createdAt: entry.revision.createdAt,
                              value: metric.value(in: scene))
        }
    }
}
