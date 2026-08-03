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
    /// What the Flat graph charts. Symbols appears once a repo has
    /// reference enrichment (built with an index store).
    public enum GraphContent: String, CaseIterable, Sendable {
        case code = "Code"        // file/module dependency graph
        case callers = "Callers"  // class → class caller graph
        case symbols = "Symbols"  // decl → decl reference graph
        case build = "Build"      // build targets → the files they need
    }
    public var graphContent: GraphContent = .code

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

    /// Live CI-flow build state, keyed by repo. The renderer animates
    /// the flow from this while a build runs. Mutated only via the
    /// build-control methods in WorkspaceStore+Build.
    public internal(set) var builds: [UUID: BuildProgress] = [:]
    @ObservationIgnored var buildRunners: [UUID: BuildStreamRunner] = [:]
    @ObservationIgnored var buildTrackers: [UUID: CIFlowBuildTracker] = [:]

    // MARK: History state
    /// Revision history per repo, loaded on demand. Workspace-wide
    /// revisions; deltas below are filtered to the repo.
    public internal(set) var history: [UUID: [GraphRevision]] = [:]
    /// The revision interval currently drawn on the graph. One slot —
    /// comparing two revisions at a time is the whole interaction.
    public internal(set) var deltaRange: RevisionRange?
    public internal(set) var activeDelta: RevisionDelta?
    public internal(set) var trendPoints: [TrendPoint] = []
    public var trendMetric: GraphMetric = .cycles

    // MARK: Migration state
    /// The two ends of a migration, named by the user. Nil until
    /// chosen — cygnus never guesses which module replaces which.
    public var migrationFrom: String?
    public var migrationTo: String?

    /// Where the named migration stands, or nil when both ends have
    /// not been picked.
    public func migrationFront(in snapshot: GraphSnapshot) -> GraphScene.MigrationFront? {
        guard let migrationFrom, let migrationTo, migrationFrom != migrationTo else { return nil }
        return GraphScene.migrationFront(from: migrationFrom, to: migrationTo, in: snapshot)
    }
    @ObservationIgnored var historyTask: Task<Void, Never>?

    public struct RevisionRange: Sendable, Equatable {
        public let from: Int64
        public let to: Int64
        public init(from: Int64, to: Int64) {
            self.from = from
            self.to = to
        }
    }

    /// Hard 5 GB memory ceiling. Views read it for the usage meter;
    /// analysis honours it.
    public let memory: MemoryGovernor

    /// Coverage attributed to a single test class (per-test halos in
    /// the graph). One slot: attributing a new test replaces it.
    public var attributedCoverage: AttributedCoverage?
    public private(set) var attributingTest: String?

    /// Coverage accumulated live while the suite runs — halos grow as
    /// each test class completes. Takes precedence over the loaded
    /// artifact while a run is active.
    public private(set) var liveCoverage: CoverageReport?
    public private(set) var coverageRun: CoverageRunProgress?
    /// Test class → its last run outcome. Colors the test→code links
    /// (green pass, red fail, yellow partial).
    public private(set) var testResults: [String: TestOutcome] = [:]
    /// Test method (by name) → its last verdict — finer than the class
    /// result, so a single failing method reddens only its own links.
    public private(set) var testMethodResults: [String: TestOutcome] = [:]
    private var coverageRunTask: Task<Void, Never>?

    public struct CoverageRunProgress: Equatable, Sendable {
        public let done: Int
        public let total: Int
        public let current: String
        public var isFinished: Bool { done >= total }
    }

    /// Run the repo's test classes one at a time with coverage,
    /// unioning results into `liveCoverage` after each so the 2D
    /// halos fill in as the suite runs. Test classes are read from the
    /// analyzed graph. Cancellable; a second call is ignored while one
    /// runs.
    public func runCoverageSuite(for id: UUID) {
        guard coverageRunTask == nil, let index = indices[id] else { return }
        let classes = index.snapshot.nodes
            .filter { $0.kind.hasSuffix(":type")
                && GraphScene.isTest($0)
                && ($0.label.hasSuffix("Tests") || $0.label.hasSuffix("Test")) }
            .map(\.label)
        let ordered = Array(Set(classes)).sorted()
        guard !ordered.isEmpty else { return }

        liveCoverage = nil
        coverageRun = CoverageRunProgress(done: 0, total: ordered.count, current: ordered[0])
        coverageRunTask = Task { @MainActor [weak self] in
            defer {
                self?.coverageRunTask = nil
                self?.coverageRun = nil
            }
            var accumulated = CoverageReport(byPath: [:], source: "live")
            for (i, testClass) in ordered.enumerated() {
                if Task.isCancelled { return }
                self?.coverageRun = CoverageRunProgress(
                    done: i, total: ordered.count, current: testClass)
                guard let self,
                      let attributed = try? await self.attributeCoverage(
                        testClass: testClass, for: id)
                else { continue }
                accumulated = accumulated.merged(with: attributed.report)
                self.liveCoverage = accumulated
                self.testResults[testClass] = attributed.outcome
                self.testMethodResults.merge(attributed.methodOutcomes) { _, new in new }
            }
            self?.coverageRun = CoverageRunProgress(
                done: ordered.count, total: ordered.count, current: "done")
        }
    }

    public func cancelCoverageSuite() {
        coverageRunTask?.cancel()
        coverageRunTask = nil
        coverageRun = nil
    }

    /// True while a `swift build` runs to produce the index store the
    /// symbol reference graph needs.
    public private(set) var indexBuilding = false

    /// Build the repo so the compiler emits an index store, then
    /// re-analyze so enrichment picks up the reference edges. SwiftPM
    /// repos (`swift build` writes `.build/…/index/store`); best-effort
    /// otherwise.
    public func buildIndex(for id: UUID, tooling: any FactoryTooling = ProcessTooling()) {
        guard !indexBuilding, let root = repoURL(id) else { return }
        indexBuilding = true
        Task { @MainActor [weak self] in
            _ = try? await RepoAccess.withAccess(to: root) { root in
                try await tooling.run(.swift, ["build"],
                                      workingDirectory: root, timeout: .seconds(1800))
            }
            self?.indexBuilding = false
            self?.analyze(id)   // re-index → enrichment reads the new store
        }
    }

    public func clearLiveCoverage() {
        cancelCoverageSuite()
        liveCoverage = nil
    }

    /// Run one test class in isolation and switch halos to its
    /// coverage. User-initiated from the inspector.
    public func attributeCoverage(testClass: String) {
        guard let repo = selectedRepo, attributingTest == nil else { return }
        attributingTest = testClass
        Task { [weak self] in
            defer { self?.attributingTest = nil }
            guard let self else { return }
            do {
                let attributed = try await self.attributeCoverage(
                    testClass: testClass, for: repo)
                self.attributedCoverage = attributed
                self.testResults[testClass] = attributed.outcome
                self.testMethodResults.merge(attributed.methodOutcomes) { _, new in new }
            } catch {
                self.attributedCoverage = nil
            }
        }
    }

    /// internal, not private: the history and build extensions live in
    /// their own files and drive the same engine.
    let engine: any GraphEngine
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
        // No side effects here beyond loading: WorkspaceStore is built
        // during App.init, and spawning tasks that early suppresses
        // window creation on this OS (see PROGRESS.md 2026-07-20).
        // Sampling starts from the meter view, post-launch.
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
        // The event pump runs DETACHED: a plain Task here inherits the
        // main actor, which puts the whole for-await loop — thousands
        // of per-file events through an unbounded stream — on the UI
        // thread and beachballs it. Off main, events are coalesced to
        // UI rate and indexes are prebuilt; only the ≤10 Hz state
        // writes hop to the main actor.
        tasks[id] = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                guard let url = Self.resolveReadableURL(repo) else {
                    await self?.markNeedsRelink(id)
                    return
                }
                try await RepoAccess.withAccess(to: url) { [weak self] url in
                    var lastForward = ContinuousClock.now - .seconds(1)
                    for try await event in engine.analyze(repoAt: url) {
                        // Coalesce the firehose: progress/partial
                        // events beyond 10 Hz carry no information a
                        // human can see — drop them here, off main.
                        // Phase changes and completion always land.
                        switch event {
                        case .progress, .partial, .partialCounts:
                            let now = ContinuousClock.now
                            guard now - lastForward >= .milliseconds(100) else { continue }
                            lastForward = now
                        case .phase, .finished:
                            break
                        }
                        // Index construction is O(n log n) — do it
                        // here, not on the main actor.
                        let prepared: SnapshotIndex? = switch event {
                        case .partial(let snapshot) where snapshot.nodes.count <= 5000:
                            SnapshotIndex(snapshot)
                        case .finished(let snapshot):
                            SnapshotIndex(snapshot)
                        default: nil
                        }
                        await self?.apply(event, prepared: prepared, to: id)
                    }
                }
                await self?.finishAnalysis(id)
            } catch is CancellationError {
                await self?.markIdle(id)
            } catch {
                await self?.markFailed(id, message: "\(error)")
            }
        }
    }

    // MARK: Main-actor state writes for the detached pump

    private func markNeedsRelink(_ id: UUID) { states[id] = .needsRelink }
    private func markIdle(_ id: UUID) { states[id] = .idle }
    private func markFailed(_ id: UUID, message: String) { states[id] = .failed(message) }
    private func finishAnalysis(_ id: UUID) { tasks[id] = nil }

    public func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
    }

    /// Resolve a repo's folder to a readable URL. Post-sandbox the raw
    /// `pathHint` is authoritative and deterministic; the security-
    /// scoped bookmark is only a fallback for a folder that has moved
    /// out from under its path. Returns nil when neither is readable
    /// (→ needsRelink). Pure filesystem work — callable off main.
    nonisolated static func resolveReadableURL(_ repo: RegisteredRepo) -> URL? {
        let byPath = URL(fileURLWithPath: repo.pathHint)
        if FileManager.default.isReadableFile(atPath: byPath.path) { return byPath }
        if let viaBookmark = (try? RepoAccess.resolve(repo.bookmark))?.url,
           FileManager.default.isReadableFile(atPath: viaBookmark.path) {
            return viaBookmark
        }
        return nil
    }

    /// `prepared` is the SnapshotIndex the pump built off-main for
    /// partial/finished snapshots — apply never constructs one.
    private func apply(_ event: AnalysisEvent, prepared: SnapshotIndex? = nil,
                       to id: UUID) {
        // The hard cap must stop work that's already running, not just
        // refuse new work — analysis events stream constantly, so this
        // is a reliable choke point. The engine has its own in-process
        // abort; this is the app-side backstop that also frees the
        // retained partial state.
        memory.refresh()
        if memory.isCritical, case .analyzing = states[id] {
            cancel(id)
            states[id] = .failed(
                "Stopped: memory reached the \(memory.summary) limit during analysis. Free memory or exclude large directories, then retry.")
            return
        }
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
            // Index prebuilt off-main by the pump; oversized partials
            // arrive without one — the outline waits for the final.
            if let prepared { indices[id] = prepared }
            states[id] = .analyzing(phase: current.phase, progress: current.progress,
                                    partial: snapshot)
        case .partialCounts:
            break
        case .finished(let snapshot):
            indices[id] = prepared ?? SnapshotIndex(snapshot)
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
