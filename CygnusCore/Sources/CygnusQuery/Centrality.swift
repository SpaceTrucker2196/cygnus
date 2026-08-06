import Foundation
import CygnusGraph

// Weighted PageRank over graph edges.
//
// Retrieval needs an importance ordering for two jobs: choosing what a
// repo map shows, and deciding which results survive a token budget.
// Both truncate, and truncation without a ranking drops whatever the
// hash order happened to surface — so this is what makes "we showed
// you the 8 that matter" a true statement rather than a hopeful one.
//
// Deterministic by construction: fixed iteration count, sorted node
// order, no randomness. The same graph always yields the same scores.

public enum Centrality {
    public static let defaultIterations = 20
    public static let damping = 0.85

    /// Rank nodes by weighted PageRank.
    ///
    /// `personalization`, when non-empty, restarts the random walk on
    /// those nodes instead of uniformly — which turns "what matters in
    /// this repository" into "what matters *for this task*". That is
    /// the difference between a repo map and a useful repo map.
    public static func pageRank(nodes: [EntityID],
                                edges: [(source: EntityID, target: EntityID, weight: Double)],
                                personalization: Set<EntityID> = [],
                                iterations: Int = defaultIterations) -> [EntityID: Double] {
        guard !nodes.isEmpty else { return [:] }
        let count = Double(nodes.count)
        let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1, $0) })

        // Restart distribution.
        var restart = [Double](repeating: 0, count: nodes.count)
        let seeds = personalization.compactMap { index[$0] }
        if seeds.isEmpty {
            for i in restart.indices { restart[i] = 1 / count }
        } else {
            let share = 1 / Double(seeds.count)
            for seed in seeds { restart[seed] = share }
        }

        // Outgoing weight per node, for normalizing contributions.
        var outWeight = [Double](repeating: 0, count: nodes.count)
        var adjacency: [[(Int, Double)]] = Array(repeating: [], count: nodes.count)
        for edge in edges {
            guard let from = index[edge.source], let to = index[edge.target] else { continue }
            let weight = max(edge.weight, 0.0001)
            adjacency[from].append((to, weight))
            outWeight[from] += weight
        }

        var rank = restart
        for _ in 0..<max(iterations, 1) {
            var next = [Double](repeating: 0, count: nodes.count)
            // A node with no outgoing edges would leak its rank out of
            // the system; spread it over the restart distribution
            // instead so the vector stays normalized.
            var dangling = 0.0
            for i in nodes.indices where outWeight[i] == 0 { dangling += rank[i] }

            for i in nodes.indices where outWeight[i] > 0 {
                let share = rank[i] / outWeight[i]
                for (target, weight) in adjacency[i] {
                    next[target] += share * weight
                }
            }
            for i in nodes.indices {
                next[i] = (1 - damping) * restart[i]
                    + damping * (next[i] + dangling * restart[i])
            }
            rank = next
        }

        return Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1, rank[$0]) })
    }
}
