import Testing
import Foundation
@testable import CygnusKit

// Containment is a DAG (shared declarations, generated+original file
// copies) and can even carry cycles. The index must stay linear —
// the exponential rebuild of shared subtrees is what once drove the
// app to 25 GB on a real repo.

struct SnapshotIndexDAGTests {
    private func node(_ id: String, kind: String = "core:file") -> GraphSnapshot.Node {
        GraphSnapshot.Node(id: id, kind: kind, label: id)
    }
    private func declares(_ from: String, _ to: String) -> GraphSnapshot.Edge {
        GraphSnapshot.Edge(from: from, to: to, kind: "core:declares")
    }

    /// A 40-level ladder DAG where every level's two nodes both
    /// declare both nodes of the next level: 2^40 paths. Linear
    /// (memoized) indexing finishes instantly; path-wise rebuilding
    /// would never return.
    @Test(.timeLimit(.minutes(1))) func sharedSubtreeDAGIndexesInLinearTime() {
        var nodes = [node("repo", kind: "core:repository")]
        var edges: [GraphSnapshot.Edge] = []
        for level in 0..<40 {
            for side in 0...1 {
                nodes.append(node("n\(level)-\(side)"))
                let parents = level == 0 ? ["repo"] : ["n\(level - 1)-0", "n\(level - 1)-1"]
                for parent in parents { edges.append(declares(parent, "n\(level)-\(side)")) }
            }
        }
        let index = SnapshotIndex(GraphSnapshot(nodes: nodes, edges: edges))
        #expect(index.trees.count == 1)
        #expect(index.trees[0].children?.count == 2)
    }

    @Test(.timeLimit(.minutes(1))) func cyclesAndSelfLoopsTerminate() {
        let snapshot = GraphSnapshot(
            nodes: [node("repo", kind: "core:repository"),
                    node("a"), node("b"), node("selfie")],
            edges: [declares("repo", "a"),
                    declares("a", "b"), declares("b", "a"),      // 2-cycle
                    declares("repo", "selfie"), declares("selfie", "selfie")])
        let index = SnapshotIndex(snapshot)
        #expect(index.trees.count == 1)
        let labels = Set((index.trees[0].children ?? []).map(\.node.label))
        #expect(labels.contains("selfie"))
    }

    @Test func duplicateEdgesProduceOneChildRow() {
        let snapshot = GraphSnapshot(
            nodes: [node("repo", kind: "core:repository"), node("a")],
            edges: [declares("repo", "a"), declares("repo", "a")])
        let index = SnapshotIndex(snapshot)
        #expect(index.trees[0].children?.count == 1)
    }
}
