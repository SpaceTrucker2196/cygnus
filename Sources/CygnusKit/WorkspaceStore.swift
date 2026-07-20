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
        case analyzing(phase: String, progress: Double?)
        case ready(GraphSnapshot)
        case failed(String)
    }

    public private(set) var repos: [RegisteredRepo]
    public private(set) var states: [UUID: AnalysisState] = [:]
    /// Snapshot indexes, built once per finished analysis — views
    /// never rebuild them.
    public private(set) var indices: [UUID: SnapshotIndex] = [:]
    public enum ViewMode: String, CaseIterable, Sendable {
        case outline = "Outline"
        case flat = "Flat"
        case space = "3D"
    }

    public var selectedRepo: UUID?
    public var selectedNode: String?
    public var searchText: String = ""
    public var viewMode: ViewMode = .outline

    private let engine: any GraphEngine
    private let persistence: WorkspacePersistence
    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init(engine: any GraphEngine = WorkspaceGraphEngine(),
                persistence: WorkspacePersistence = WorkspacePersistence()) {
        self.engine = engine
        self.persistence = persistence
        self.repos = persistence.load()
        for repo in repos { states[repo.id] = .idle }
    }

    // MARK: - Registry

    /// Add a folder the user picked in NSOpenPanel (already security-
    /// scoped) and start analysis.
    public func addRepository(at url: URL) {
        do {
            let repo = RegisteredRepo(
                displayName: url.lastPathComponent,
                pathHint: url.path,
                bookmark: try RepoAccess.bookmark(for: url))
            repos.append(repo)
            states[repo.id] = .idle
            try persistence.save(repos)
            selectedRepo = repo.id
            analyze(repo.id)
        } catch {
            // Registration failed before any state existed; nothing to roll back.
        }
    }

    /// Remove the registration only — never touches the folder.
    public func removeRepository(_ id: UUID) {
        cancel(id)
        repos.removeAll { $0.id == id }
        states[id] = nil
        if selectedRepo == id { selectedRepo = nil }
        try? persistence.save(repos)
    }

    // MARK: - Analysis

    public func analyze(_ id: UUID) {
        guard let repo = repos.first(where: { $0.id == id }) else { return }
        cancel(id)
        states[id] = .analyzing(phase: "starting", progress: nil)

        let engine = self.engine
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let (url, _) = try RepoAccess.resolve(repo.bookmark)
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

    private func apply(_ event: AnalysisEvent, to id: UUID) {
        switch event {
        case .phase(let phase):
            let progress: Double? = if case .analyzing(_, let p) = states[id] { p } else { nil }
            states[id] = .analyzing(phase: phase, progress: progress)
        case .progress(let value):
            let phase: String = if case .analyzing(let p, _) = states[id] { p } else { "working" }
            states[id] = .analyzing(phase: phase, progress: value)
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
}
