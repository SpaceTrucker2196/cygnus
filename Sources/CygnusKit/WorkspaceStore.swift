import Foundation
import Observation

// Single source of truth for the shell. Views observe; views don't
// own data. All engine work funnels through here so cancellation and
// state transitions live in one place.

@MainActor
@Observable
public final class WorkspaceStore {
    public enum AnalysisState: Equatable {
        case idle
        /// `partial` is the growing snapshot rendered live while the
        /// engine works.
        case analyzing(phase: String, progress: Double?, partial: GraphSnapshot? = nil)
        case ready(GraphSnapshot)
        case failed(String)
        /// Bookmark no longer resolves (folder moved or deleted) —
        /// the user must re-pick it.
        case needsRelink
    }

    public private(set) var repos: [RegisteredRepo]
    public private(set) var states: [UUID: AnalysisState] = [:]
    /// Snapshot indexes, built once per finished analysis — views
    /// never rebuild them.
    public private(set) var indices: [UUID: SnapshotIndex] = [:]
    public enum ViewMode: String, CaseIterable, Sendable {
        case outline = "Outline"
        case flat = "Flat"
    }

    public var selectedRepo: UUID?
    public var selectedNode: String?
    public var searchText: String = ""
    public var viewMode: ViewMode = .outline
    /// Chart third-party (non-system) external modules. System
    /// modules are never charted.
    public var showExternalModules = false

    // MARK: Ops-dashboard state
    /// Which section the detail pane shows, remembered per repo.
    public var sectionByRepo: [UUID: RepoSection] = [:]
    /// Selection within the Issues and Docs sections.
    public var selectedOrder: Int?
    public var selectedDoc: String?
    /// Per-repo factory data, loaded on demand.
    public private(set) var factoryStates: [UUID: FactoryState] = [:]

    /// Hard 5 GB memory ceiling. Views read it for the usage meter;
    /// analysis honours it.
    public let memory: MemoryGovernor

    private let engine: any GraphEngine
    private let persistence: WorkspacePersistence
    let factory: any FactoryProvider
    let docs: any FactoryDocsProvider
    private var tasks: [UUID: Task<Void, Never>] = [:]
    var factoryTasks: [FactoryTaskKey: Task<Void, Never>] = [:]

    public init(engine: any GraphEngine = WorkspaceGraphEngine(),
                persistence: WorkspacePersistence = WorkspacePersistence(),
                factory: any FactoryProvider = GitHubFactoryProvider(),
                docs: any FactoryDocsProvider = FileDocsProvider(),
                memory: MemoryGovernor = MemoryGovernor()) {
        self.engine = engine
        self.persistence = persistence
        self.factory = factory
        self.docs = docs
        self.memory = memory
        self.repos = persistence.load()
        for repo in repos { states[repo.id] = .idle }
        // An ops dashboard shouldn't open blank: land on the first
        // registered repo.
        selectedRepo = repos.first?.id
        memory.startSampling()
    }

    // MARK: - Registry

    /// Add a folder the user picked in NSOpenPanel (already security-
    /// scoped) and start analysis. Failures are never silent: the
    /// repo row appears with a failed state describing what happened.
    public func addRepository(at url: URL) {
        var repo = RegisteredRepo(
            displayName: url.lastPathComponent,
            pathHint: url.path,
            bookmark: Data())
        // Bookmark creation can fail in odd launch contexts; if the
        // folder is still directly readable, proceed without one —
        // access lasts this session and relink covers the rest.
        repo.bookmark = (try? RepoAccess.bookmark(for: url)) ?? Data()
        guard !repo.bookmark.isEmpty
                || FileManager.default.isReadableFile(atPath: url.path) else {
            repos.append(repo)
            selectedRepo = repo.id
            states[repo.id] = .failed("Couldn't get access to \(url.path)")
            return
        }
        repos.append(repo)
        states[repo.id] = .idle
        try? persistence.save(repos)
        selectedRepo = repo.id
        analyze(repo.id)
    }

    /// Remove the registration only — never touches the folder.
    public func removeRepository(_ id: UUID) {
        cancel(id)
        repos.removeAll { $0.id == id }
        states[id] = nil
        if selectedRepo == id { selectedRepo = nil }
        try? persistence.save(repos)
    }

    /// Point an existing registration at a re-picked folder (already
    /// security-scoped from NSOpenPanel) and re-analyze.
    public func relink(_ id: UUID, to url: URL) {
        guard let index = repos.firstIndex(where: { $0.id == id }) else { return }
        do {
            repos[index].bookmark = try RepoAccess.bookmark(for: url)
            repos[index].pathHint = url.path
            try persistence.save(repos)
            analyze(id)
        } catch {
            states[id] = .failed("\(error)")
        }
    }

    // MARK: - Analysis

    public func analyze(_ id: UUID) {
        guard let repo = repos.first(where: { $0.id == id }) else { return }
        // Refuse to start new analysis while already at the hard cap —
        // starting another index is exactly how the process would tip
        // over. Sample fresh so the gate isn't decided on a stale read.
        memory.refresh()
        if memory.isCritical {
            states[id] = .failed(
                "Paused: memory is at the \(memory.summary) limit. Close a repository or free memory, then retry.")
            return
        }
        cancel(id)
        states[id] = .analyzing(phase: "starting", progress: nil)

        let engine = self.engine
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                guard let url = self.resolveReadableURL(repo) else {
                    self.states[id] = .needsRelink
                    return
                }
                try await RepoAccess.withAccess(to: url) { url in
                    for try await event in engine.analyze(repoAt: url) {
                        await self.apply(event, to: id)
                    }
                }
                self.tasks[id] = nil
            } catch is CancellationError {
                self.states[id] = .idle
            } catch {
                self.states[id] = .failed("\(error)")
            }
        }
    }

    public func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
    }

    /// Resolve a repo's folder to a readable URL. Post-sandbox the raw
    /// `pathHint` is authoritative and deterministic; the security-
    /// scoped bookmark is only a fallback for a folder that has moved
    /// out from under its path. Returns nil when neither is readable
    /// (→ needsRelink).
    func resolveReadableURL(_ repo: RegisteredRepo) -> URL? {
        let byPath = URL(fileURLWithPath: repo.pathHint)
        if FileManager.default.isReadableFile(atPath: byPath.path) { return byPath }
        if let viaBookmark = (try? RepoAccess.resolve(repo.bookmark))?.url,
           FileManager.default.isReadableFile(atPath: viaBookmark.path) {
            return viaBookmark
        }
        return nil
    }

    private func apply(_ event: AnalysisEvent, to id: UUID) {
        var current: (phase: String, progress: Double?, partial: GraphSnapshot?) {
            if case .analyzing(let phase, let progress, let partial) = states[id] {
                (phase, progress, partial)
            } else {
                ("working", nil, nil)
            }
        }
        switch event {
        case .phase(let phase):
            states[id] = .analyzing(phase: phase, progress: current.progress,
                                    partial: current.partial)
        case .progress(let value):
            states[id] = .analyzing(phase: current.phase, progress: value,
                                    partial: current.partial)
        case .partial(let snapshot):
            // The live preview is a courtesy. Under memory pressure,
            // drop it: don't retain the snapshot or rebuild its index,
            // so headroom goes to the committed result, not the render.
            if memory.isHigh {
                states[id] = .analyzing(phase: current.phase, progress: current.progress,
                                        partial: nil)
                break
            }
            // Index rebuilds are O(n) per partial; above this size the
            // outline waits for the final snapshot.
            if snapshot.nodes.count <= 5000 {
                indices[id] = SnapshotIndex(snapshot)
            }
            states[id] = .analyzing(phase: current.phase, progress: current.progress,
                                    partial: snapshot)
        case .partialCounts:
            break
        case .finished(let snapshot):
            indices[id] = SnapshotIndex(snapshot)
            states[id] = .ready(snapshot)
        }
    }

    // MARK: - Test seams

    /// Register a repo without bookmark creation (tests only).
    public func testInject(repo: RegisteredRepo) {
        repos.append(repo)
        states[repo.id] = .idle
    }

    /// Drive the state machine directly (tests only).
    public func testApply(_ event: AnalysisEvent, to id: UUID) {
        apply(event, to: id)
    }

    // MARK: - Selection helpers

    public var currentState: AnalysisState? {
        selectedRepo.flatMap { states[$0] }
    }

    public var currentSnapshot: GraphSnapshot? {
        if case .ready(let snapshot)? = currentState { return snapshot }
        return nil
    }

    public var currentIndex: SnapshotIndex? {
        selectedRepo.flatMap { indices[$0] }
    }

    public var selectedNodeValue: GraphSnapshot.Node? {
        guard let id = selectedNode else { return nil }
        return currentIndex?.byID[id]
    }

    // MARK: - Ops selection helpers

    /// The section shown for the selected repo. Defaults to Dashboard
    /// once a factory is detected, else Code Graph.
    public var selectedSection: RepoSection {
        get {
            guard let id = selectedRepo else { return .dashboard }
            return sectionByRepo[id] ?? .dashboard
        }
        set { if let id = selectedRepo { sectionByRepo[id] = newValue } }
    }

    public var currentFactory: FactoryState? {
        selectedRepo.flatMap { factoryStates[$0] }
    }

    public func factoryState(for id: UUID) -> FactoryState {
        factoryStates[id] ?? FactoryState()
    }

    /// Mutate a repo's factory state in place (creating it if absent).
    func mutateFactory(_ id: UUID, _ change: (inout FactoryState) -> Void) {
        var state = factoryStates[id] ?? FactoryState()
        change(&state)
        factoryStates[id] = state
    }

    /// Inject a fully-formed factory state (tests only).
    public func testInjectFactory(_ state: FactoryState, to id: UUID) {
        factoryStates[id] = state
    }
}

/// Keys a factory-refresh task per (repo, dataset) so refreshes cancel
/// and replace cleanly.
public struct FactoryTaskKey: Hashable, Sendable {
    public let repo: UUID
    public let dataset: FactoryDataset
    public init(repo: UUID, dataset: FactoryDataset) {
        self.repo = repo; self.dataset = dataset
    }
}
