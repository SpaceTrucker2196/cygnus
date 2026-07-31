import Foundation

// Revision history: what changed between two commits of the graph,
// and how a metric has moved across them. The engine has stored this
// since the beginning — interval columns are the change log — and the
// app has never shown it.

extension WorkspaceStore {
    /// Load the workspace's revision list for this repo's engine.
    /// Cheap: one table read, no projection.
    public func loadHistory(for id: UUID) async {
        guard let repo = repos.first(where: { $0.id == id }),
              let url = Self.resolveReadableURL(repo) else { return }
        let engine = self.engine
        let revisions = try? await RepoAccess.withAccess(to: url) { url in
            try await engine.revisions(repoAt: url)
        }
        history[id] = revisions ?? []
    }

    /// Draw what changed in `(from, to]` on the graph.
    public func showDelta(for id: UUID, from: Int64, to: Int64) async {
        guard from < to,
              let repo = repos.first(where: { $0.id == id }),
              let url = Self.resolveReadableURL(repo) else { return }
        let engine = self.engine
        let delta = try? await RepoAccess.withAccess(to: url) { url in
            try await engine.delta(repoAt: url, from: from, to: to)
        }
        deltaRange = RevisionRange(from: from, to: to)
        activeDelta = delta
    }

    public func clearDelta() {
        deltaRange = nil
        activeDelta = nil
    }

    /// Project the last `window` revisions and read one metric off
    /// each. Every point is a full historical projection, so this runs
    /// detached and replaces any run already in flight — scrubbing
    /// through metrics must not queue up a backlog of projections.
    public func loadTrend(for id: UUID, metric: GraphMetric,
                          window: Int = GraphTrend.defaultWindow) {
        historyTask?.cancel()
        guard let repo = repos.first(where: { $0.id == id }),
              let url = Self.resolveReadableURL(repo) else { return }
        let engine = self.engine
        let known = history[id] ?? []
        let showExternal = showExternalModules

        historyTask = Task.detached(priority: .utility) { [weak self] in
            let revisions = known.isEmpty
                ? ((try? await RepoAccess.withAccess(to: url) { url in
                    try await engine.revisions(repoAt: url)
                }) ?? [])
                : known
            let recent = Array(revisions.suffix(window))
            guard !recent.isEmpty else { return }

            var projected: [(revision: GraphRevision, snapshot: GraphSnapshot)] = []
            for revision in recent {
                if Task.isCancelled { return }
                guard let snapshot = try? await RepoAccess.withAccess(to: url, { url in
                    try await engine.snapshot(repoAt: url, asOf: revision.id)
                }) else { continue }
                projected.append((revision, snapshot))
            }
            if Task.isCancelled { return }
            let points = GraphTrend.series(metric, over: projected,
                                           showExternal: showExternal)
            await self?.applyTrend(points, revisions: revisions, for: id)
        }
    }

    func applyTrend(_ points: [TrendPoint], revisions: [GraphRevision], for id: UUID) {
        history[id] = revisions
        trendPoints = points
    }
}
