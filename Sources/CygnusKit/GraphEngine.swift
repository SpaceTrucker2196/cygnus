import Foundation

// The shell's contract with the graph engine. This protocol states
// exactly what the app needs; CygnusCore's facade conforms to it
// (S2/S6). FixtureGraphEngine lets the shell build, run, and demo
// before the engine lands.

public struct RepoID: Hashable, Codable, Sendable {
    public let raw: UUID
    public init(_ raw: UUID = UUID()) { self.raw = raw }
}

/// Progress events emitted during analysis.
public enum AnalysisEvent: Sendable {
    case phase(String)
    case progress(Double)
    case partialCounts(entities: Int, edges: Int)
    /// A growing, incomplete snapshot emitted while analysis runs —
    /// views render it immediately so the graph builds up in
    /// realtime instead of appearing all at once.
    case partial(GraphSnapshot)
    case finished(GraphSnapshot)
}

/// Immutable, render-ready projection of a graph revision. Renderers
/// and the inspector consume this — never live engine objects.
public struct GraphSnapshot: Sendable, Equatable {
    public struct Node: Sendable, Equatable, Identifiable {
        public let id: String          // engine stable key
        public let kind: String        // namespaced kind, e.g. core:file
        public let label: String
        public let path: String?       // source anchor, when file-backed
        public let line: Int?          // anchor start line (1-based)
        /// A small, explicitly projected slice of the entity's
        /// properties — never the whole bag. Renderers ask questions
        /// the structural fields cannot answer (when did this person
        /// last commit), and the alternative is overloading a field
        /// that means something else.
        public let attributes: [String: String]

        public init(id: String, kind: String, label: String,
                    path: String? = nil, line: Int? = nil,
                    attributes: [String: String] = [:]) {
            self.id = id
            self.kind = kind
            self.label = label
            self.path = path
            self.line = line
            self.attributes = attributes
        }
    }

    public struct Edge: Sendable, Equatable {
        public let from: String
        public let to: String
        public let kind: String
        /// How many underlying references this edge aggregates (1 for
        /// structural edges; the reference count for enrichment
        /// edges). Renderers scale thickness by it.
        public let weight: Int
        public init(from: String, to: String, kind: String, weight: Int = 1) {
            self.from = from
            self.to = to
            self.kind = kind
            self.weight = weight
        }
    }

    public let nodes: [Node]
    public let edges: [Edge]

    public init(nodes: [Node], edges: [Edge]) {
        self.nodes = nodes
        self.edges = edges
    }
}

/// One committed revision of the graph.
public struct GraphRevision: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let createdAt: Date
    /// What the commit was for ("enrich: 38 file + 112 symbol
    /// reference edges") — the analysis's own history, in prose.
    public let note: String?
    public init(id: Int64, createdAt: Date, note: String?) {
        self.id = id
        self.createdAt = createdAt
        self.note = note
    }
}

/// What changed for one repository across a revision interval.
///
/// Split by the interval semantics rather than guessed: a key whose
/// version was only asserted is new, only retracted is gone, and both
/// means the entity survived with different content.
public struct RevisionDelta: Sendable, Equatable {
    public let addedNodes: Set<String>
    public let removedNodes: Set<String>
    public let changedNodes: Set<String>
    public let addedEdges: Int
    public let removedEdges: Int

    public init(addedNodes: Set<String> = [], removedNodes: Set<String> = [],
                changedNodes: Set<String> = [], addedEdges: Int = 0,
                removedEdges: Int = 0) {
        self.addedNodes = addedNodes
        self.removedNodes = removedNodes
        self.changedNodes = changedNodes
        self.addedEdges = addedEdges
        self.removedEdges = removedEdges
    }

    public var isEmpty: Bool {
        addedNodes.isEmpty && removedNodes.isEmpty && changedNodes.isEmpty
            && addedEdges == 0 && removedEdges == 0
    }
}

/// What the shell needs from an engine, nothing more.
public protocol GraphEngine: Sendable {
    func analyze(repoAt url: URL) -> AsyncThrowingStream<AnalysisEvent, any Error>

    /// Committed revisions, oldest first. Workspace-wide: revisions
    /// are not partitioned by repository, so a workspace holding
    /// several repos lists all of them. Deltas *are* filtered, so a
    /// revision that did not touch this repo reports no change.
    func revisions(repoAt url: URL) async throws -> [GraphRevision]

    /// What changed for this repository in `(from, to]`.
    func delta(repoAt url: URL, from: Int64, to: Int64) async throws -> RevisionDelta

    /// The repository's graph as it stood at a revision. Trends are
    /// computed from these, so metric definitions stay in the scene
    /// where they are already tested rather than moving into the
    /// engine.
    func snapshot(repoAt url: URL, asOf revision: Int64) async throws -> GraphSnapshot
}

/// Deterministic in-memory engine for demos and tests.
public struct FixtureGraphEngine: GraphEngine {
    public let snapshot: GraphSnapshot

    public init(snapshot: GraphSnapshot = .sample) {
        self.init(snapshot: snapshot, history: [])
    }

    /// Optional canned history, so tests and demos can exercise the
    /// revision UI without a store. Empty by default — a fixture with
    /// no history is the honest default, not a fabricated one.
    public let history: [GraphRevision]
    public let snapshotsByRevision: [Int64: GraphSnapshot]

    public init(snapshot: GraphSnapshot = .sample,
                history: [GraphRevision],
                snapshotsByRevision: [Int64: GraphSnapshot] = [:]) {
        self.snapshot = snapshot
        self.history = history
        self.snapshotsByRevision = snapshotsByRevision
    }

    public func revisions(repoAt url: URL) async throws -> [GraphRevision] { history }

    /// Derived from the canned snapshots when present, so a fixture
    /// delta agrees with its own history instead of being asserted
    /// separately.
    public func delta(repoAt url: URL, from: Int64, to: Int64) async throws -> RevisionDelta {
        guard let before = snapshotsByRevision[from], let after = snapshotsByRevision[to] else {
            return RevisionDelta()
        }
        let old = Set(before.nodes.map(\.id))
        let new = Set(after.nodes.map(\.id))
        return RevisionDelta(
            addedNodes: new.subtracting(old),
            removedNodes: old.subtracting(new),
            addedEdges: max(0, after.edges.count - before.edges.count),
            removedEdges: max(0, before.edges.count - after.edges.count))
    }

    public func snapshot(repoAt url: URL, asOf revision: Int64) async throws -> GraphSnapshot {
        snapshotsByRevision[revision] ?? snapshot
    }

    public func analyze(repoAt url: URL) -> AsyncThrowingStream<AnalysisEvent, any Error> {
        let snapshot = self.snapshot
        return AsyncThrowingStream { continuation in
            continuation.yield(.phase("scanning"))
            continuation.yield(.progress(0.5))
            continuation.yield(.partialCounts(entities: snapshot.nodes.count,
                                              edges: snapshot.edges.count))
            continuation.yield(.progress(1.0))
            continuation.yield(.finished(snapshot))
            continuation.finish()
        }
    }
}

extension GraphSnapshot {
    /// Tiny fixture graph: a repo containing two files, one import.
    public static let sample = GraphSnapshot(
        nodes: [
            Node(id: "phys:repo:fixture", kind: "core:repository", label: "fixture"),
            Node(id: "phys:file:fixture/A.swift", kind: "core:file", label: "A.swift"),
            Node(id: "phys:file:fixture/B.swift", kind: "core:file", label: "B.swift"),
        ],
        edges: [
            Edge(from: "phys:repo:fixture", to: "phys:file:fixture/A.swift", kind: "core:containsPhysical"),
            Edge(from: "phys:repo:fixture", to: "phys:file:fixture/B.swift", kind: "core:containsPhysical"),
            Edge(from: "phys:file:fixture/A.swift", to: "phys:file:fixture/B.swift", kind: "core:imports"),
        ]
    )
}
