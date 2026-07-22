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
        public init(id: String, kind: String, label: String, path: String? = nil) {
            self.id = id
            self.kind = kind
            self.label = label
            self.path = path
        }
    }

    public struct Edge: Sendable, Equatable {
        public let from: String
        public let to: String
        public let kind: String
        public init(from: String, to: String, kind: String) {
            self.from = from
            self.to = to
            self.kind = kind
        }
    }

    public let nodes: [Node]
    public let edges: [Edge]

    public init(nodes: [Node], edges: [Edge]) {
        self.nodes = nodes
        self.edges = edges
    }
}

/// What the shell needs from an engine, nothing more.
public protocol GraphEngine: Sendable {
    func analyze(repoAt url: URL) -> AsyncThrowingStream<AnalysisEvent, any Error>
}

/// Deterministic in-memory engine for demos and tests.
public struct FixtureGraphEngine: GraphEngine {
    public let snapshot: GraphSnapshot

    public init(snapshot: GraphSnapshot = .sample) {
        self.snapshot = snapshot
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
