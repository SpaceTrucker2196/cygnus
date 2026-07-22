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
        case space = "3D"
    }

    public var selectedRepo: UUID?
    public var selectedNode: String?
    public var searchText: String = ""
    public var viewMode: ViewMode = .outline
    /// Chart third-party (non-system) external modules. System
    /// modules are never charted.
    public var showExternalModules = false

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
        cancel(id)
        states[id] = .analyzing(phase: "starting", progress: nil)

        let engine = self.engine
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                // Prefer the bookmark; fall back to the raw path when
                // the folder is still directly readable (bookmark
                // failed to create, or non-sandboxed contexts).
                let resolved = (try? RepoAccess.resolve(repo.bookmark))?.url
                    ?? URL(fileURLWithPath: repo.pathHint)
                guard FileManager.default.isReadableFile(atPath: resolved.path) else {
                    self.states[id] = .needsRelink
                    return
                }
                let url = resolved
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
            indices[id] = SnapshotIndex(snapshot)
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
}
