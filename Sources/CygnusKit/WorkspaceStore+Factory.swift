import Foundation

// Factory data loading: mirrors the analyze/apply/tasks pattern. Each
// dataset refreshes independently; a refresh cancels its in-flight
// task, marks the field .loading, runs the provider off the main actor
// (inside RepoAccess.withAccess), and writes .loaded/.failed back.

extension WorkspaceStore {

    /// Resolve a repo's folder URL (pathHint first, bookmark fallback).
    func repoURL(_ id: UUID) -> URL? {
        guard let repo = repos.first(where: { $0.id == id }) else { return nil }
        return resolveReadableURL(repo) ?? URL(fileURLWithPath: repo.pathHint)
    }

    // MARK: - Orchestration

    /// Detect capabilities on first selection, then load whatever the
    /// current section needs.
    public func selectRepoSection(_ section: RepoSection, for id: UUID) {
        sectionByRepo[id] = section
        ensureCapabilities(id)
        ensureLoaded(section, for: id)
    }

    /// Kick capability detection unless it's already loaded/loading.
    public func ensureCapabilities(_ id: UUID) {
        let caps = factoryState(for: id).capabilities
        guard caps.isIdle || caps.errorMessage != nil else { return }
        refreshCapabilities(id)
    }

    /// Load only the datasets a section needs, and only if idle.
    /// GitHub-gated datasets (issues, runs) wait until capabilities are
    /// known — otherwise they'd fail with a spurious "GitHub
    /// unavailable" before detection finishes. `refreshCapabilities`
    /// calls this again on completion to pick them up.
    public func ensureLoaded(_ section: RepoSection, for id: UUID) {
        let state = factoryState(for: id)
        let capsKnown = state.capabilities.value != nil
        switch section {
        case .dashboard:
            if state.runs.isIdle && capsKnown { refreshRuns(id) }
            if state.commits.isIdle { refreshCommits(id) }
            if state.metrics.isIdle { refreshMetrics(id) }
            if state.ledger.isIdle { refreshLedger(id) }
            if state.issues.isIdle && capsKnown { refreshIssues(id) }
        case .workflow:
            if state.runs.isIdle && capsKnown { refreshRuns(id) }
            if state.converge.isIdle { refreshConverge(id) }
        case .issues:
            if state.issues.isIdle && capsKnown { refreshIssues(id) }
        case .docs:
            if state.docs.isIdle { refreshDocs(id) }
        case .codeGraph:
            break
        }
    }

    /// Re-run a dataset regardless of current state (a Refresh button).
    public func refresh(_ dataset: FactoryDataset, for id: UUID) {
        switch dataset {
        case .capabilities: refreshCapabilities(id)
        case .issues: refreshIssues(id)
        case .runs: refreshRuns(id)
        case .commits: refreshCommits(id)
        case .metrics: refreshMetrics(id)
        case .ledger: refreshLedger(id)
        case .converge: refreshConverge(id)
        case .docs: refreshDocs(id)
        }
    }

    // MARK: - Task plumbing

    /// Spawn a MainActor-isolated dataset task, cancelling any prior
    /// task for the same (repo, dataset).
    private func spawn(_ id: UUID, _ dataset: FactoryDataset,
                       _ body: @escaping @MainActor @Sendable () async -> Void) {
        let key = FactoryTaskKey(repo: id, dataset: dataset)
        factoryTasks[key]?.cancel()
        factoryTasks[key] = Task { @MainActor [weak self] in
            await body()
            self?.factoryTasks[key] = nil
        }
    }

    public nonisolated static func describe(_ error: any Error) -> String {
        switch error {
        case ToolingError.toolNotFound(let tool): "`\(tool.rawValue)` not found — set its path in Settings."
        case ToolingError.notAuthenticated: "Not authenticated — run `gh auth login`."
        case ToolingError.timedOut(let tool): "`\(tool.rawValue)` timed out."
        case is CancellationError: "Cancelled."
        default: "\(error)"
        }
    }

    // MARK: - Per-dataset refreshers

    func refreshCapabilities(_ id: UUID) {
        guard let url = repoURL(id) else { return }
        mutateFactory(id) { $0.capabilities = .loading }
        let provider = factory
        spawn(id, .capabilities) { [weak self] in
            let caps = await provider.detectCapabilities(repoAt: url)
            guard let self else { return }
            self.mutateFactory(id) { $0.capabilities = .loaded(caps) }
            // Capabilities are known now — fire the GitHub-gated
            // datasets the current section was waiting on.
            self.ensureLoaded(self.sectionByRepo[id] ?? .dashboard, for: id)
        }
    }

    func refreshIssues(_ id: UUID) {
        guard let url = repoURL(id) else { return }
        guard factoryState(for: id).caps.github, let remote = factoryState(for: id).caps.remote else {
            mutateFactory(id) { $0.issues = .failed("GitHub unavailable — check the remote and `gh auth login`.") }
            return
        }
        let provider = factory
        mutateFactory(id) { $0.issues = .loading }
        spawn(id, .issues) { [weak self] in
            do {
                let issues = try await RepoAccess.withAccess(to: url) { _ in
                    try await provider.listIssues(remote: remote)
                }
                self?.mutateFactory(id) { $0.issues = .loaded(issues) }
            } catch is CancellationError {
            } catch {
                self?.mutateFactory(id) { $0.issues = .failed(WorkspaceStore.describe(error)) }
            }
        }
    }

    func refreshRuns(_ id: UUID) {
        guard let url = repoURL(id) else { return }
        guard factoryState(for: id).caps.github, let remote = factoryState(for: id).caps.remote else {
            mutateFactory(id) { $0.runs = .failed("GitHub unavailable — check the remote and `gh auth login`.") }
            return
        }
        let provider = factory
        mutateFactory(id) { $0.runs = .loading }
        spawn(id, .runs) { [weak self] in
            do {
                let runs = try await RepoAccess.withAccess(to: url) { _ in
                    try await provider.listRuns(remote: remote, limit: 20)
                }
                self?.mutateFactory(id) { $0.runs = .loaded(runs) }
            } catch is CancellationError {
            } catch {
                self?.mutateFactory(id) { $0.runs = .failed(WorkspaceStore.describe(error)) }
            }
        }
    }

    func refreshCommits(_ id: UUID) {
        guard let url = repoURL(id) else { return }
        let provider = factory
        mutateFactory(id) { $0.commits = .loading }
        spawn(id, .commits) { [weak self] in
            do {
                let commits = try await RepoAccess.withAccess(to: url) { url in
                    try await provider.recentCommits(repoAt: url, limit: 40)
                }
                self?.mutateFactory(id) { $0.commits = .loaded(commits) }
            } catch is CancellationError {
            } catch {
                self?.mutateFactory(id) { $0.commits = .failed(WorkspaceStore.describe(error)) }
            }
        }
    }

    func refreshMetrics(_ id: UUID) {
        guard let url = repoURL(id) else { return }
        let provider = factory
        mutateFactory(id) { $0.metrics = .loading }
        spawn(id, .metrics) { [weak self] in
            do {
                let rows = try await RepoAccess.withAccess(to: url) { url in
                    try await provider.metricsRows(repoAt: url)
                }
                self?.mutateFactory(id) { $0.metrics = .loaded(rows) }
            } catch is CancellationError {
            } catch {
                self?.mutateFactory(id) { $0.metrics = .failed(WorkspaceStore.describe(error)) }
            }
        }
    }

    func refreshLedger(_ id: UUID) {
        guard let url = repoURL(id) else { return }
        let provider = factory
        mutateFactory(id) { $0.ledger = .loading }
        spawn(id, .ledger) { [weak self] in
            do {
                let rows = try await RepoAccess.withAccess(to: url) { url in
                    try await provider.ledgerRows(repoAt: url)
                }
                self?.mutateFactory(id) { $0.ledger = .loaded(rows) }
            } catch is CancellationError {
            } catch {
                self?.mutateFactory(id) { $0.ledger = .failed(WorkspaceStore.describe(error)) }
            }
        }
    }

    func refreshConverge(_ id: UUID) {
        guard let url = repoURL(id) else { return }
        let provider = factory
        mutateFactory(id) { $0.converge = .loading }
        spawn(id, .converge) { [weak self] in
            do {
                let pipeline = try await RepoAccess.withAccess(to: url) { url in
                    try await provider.convergePipeline(repoAt: url)
                }
                self?.mutateFactory(id) { $0.converge = .loaded(pipeline) }
            } catch is CancellationError {
            } catch {
                self?.mutateFactory(id) { $0.converge = .failed(WorkspaceStore.describe(error)) }
            }
        }
    }

    func refreshDocs(_ id: UUID) {
        guard let url = repoURL(id) else { return }
        let provider = docs
        mutateFactory(id) { $0.docs = .loading }
        spawn(id, .docs) { [weak self] in
            do {
                let tree = try await RepoAccess.withAccess(to: url) { url in
                    try await provider.tree(repoAt: url)
                }
                self?.mutateFactory(id) { $0.docs = .loaded(tree) }
            } catch is CancellationError {
            } catch {
                self?.mutateFactory(id) { $0.docs = .failed(WorkspaceStore.describe(error)) }
            }
        }
    }

    // MARK: - Issue detail + Docs editing

    /// Fetch a single issue with comments and merge it into the list.
    public func loadIssueDetail(_ number: Int, for id: UUID) {
        guard let remote = factoryState(for: id).caps.remote else { return }
        let provider = factory
        Task { @MainActor [weak self] in
            guard let full = try? await provider.viewIssue(remote: remote, number: number) else { return }
            self?.mutateFactory(id) { state in
                if case .loaded(var issues) = state.issues,
                   let idx = issues.firstIndex(where: { $0.number == number }) {
                    issues[idx] = full
                    state.issues = .loaded(issues)
                }
            }
        }
    }

    /// Read one doc for the editor.
    public func readDoc(_ path: String, for id: UUID) async -> DocFile? {
        guard let url = repoURL(id) else { return nil }
        let provider = docs
        return try? await RepoAccess.withAccess(to: url) { try await provider.read(repoAt: $0, path: path) }
    }

    /// Save a doc (atomic), optionally committing. Refreshes the tree
    /// and re-throws so the view can surface guard failures.
    public func saveDoc(_ path: String, content: String,
                        commit: DocCommit?, for id: UUID) async throws -> DocWriteResult {
        guard let url = repoURL(id) else { throw DocsError.notFound(path) }
        let provider = docs
        let result = try await RepoAccess.withAccess(to: url) {
            try await provider.write(repoAt: $0, path: path, content: content, commit: commit)
        }
        refreshDocs(id)
        if commit != nil { refreshCommits(id) }
        return result
    }
}
