import Testing
import Foundation
@testable import CygnusKit

// The path the user means by "load a repo": pick a folder → bookmark
// → persist → analyze with the real engine → ready snapshot — plus
// relaunch, missing-folder, and relink flows. WorkspaceStore drives
// everything, exactly as the app does.

@MainActor
struct RepoLoadingHarness {
    let repoRoot: URL
    let persistenceURL: URL
    let engineDirectory: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-load-\(UUID().uuidString)")
        repoRoot = base.appendingPathComponent("repo")
        persistenceURL = base.appendingPathComponent("workspace.json")
        engineDirectory = base.appendingPathComponent("engine")
        try FileManager.default.createDirectory(
            at: repoRoot.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try """
            import CygnusKitFixture
            struct Loader { func load() -> Bool { true } }
            """.write(to: repoRoot.appendingPathComponent("Sources/Loader.swift"),
                      atomically: true, encoding: .utf8)
    }

    func makeStore() -> WorkspaceStore {
        WorkspaceStore(engine: WorkspaceGraphEngine(directory: engineDirectory),
                       persistence: WorkspacePersistence(fileURL: persistenceURL))
    }

    func cleanup() {
        try? FileManager.default.removeItem(
            at: repoRoot.deletingLastPathComponent())
    }

    /// Poll until the repo reaches a terminal state (ready/failed/
    /// needsRelink) or time runs out.
    func waitForSettle(_ store: WorkspaceStore, _ id: UUID,
                       timeout: Duration = .seconds(30)) async throws -> WorkspaceStore.AnalysisState {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            switch store.states[id] {
            case .ready, .failed, .needsRelink: return store.states[id]!
            default: try await Task.sleep(for: .milliseconds(50))
            }
        }
        Issue.record("analysis did not settle within \(timeout): \(String(describing: store.states[id]))")
        return store.states[id] ?? .idle
    }
}

@Suite @MainActor struct RepoLoadingTests {
    @Test func addRepositoryAnalyzesToReadySnapshot() async throws {
        let harness = try RepoLoadingHarness()
        defer { harness.cleanup() }
        let store = harness.makeStore()

        store.addRepository(at: harness.repoRoot)
        let repo = try #require(store.repos.first)
        #expect(store.selectedRepo == repo.id)
        #expect(!repo.bookmark.isEmpty)

        guard case .ready(let snapshot) = try await harness.waitForSettle(store, repo.id) else {
            Issue.record("expected ready, got \(String(describing: store.states[repo.id]))")
            return
        }
        #expect(snapshot.nodes.contains { $0.label == "Loader.swift" })
        #expect(snapshot.nodes.contains { $0.label == "Loader" })
        #expect(store.indices[repo.id] != nil)

        // Registration survived to disk.
        let persisted = WorkspacePersistence(fileURL: harness.persistenceURL).load()
        #expect(persisted.map(\.id) == [repo.id])
    }

    @Test func relaunchedStoreResolvesBookmarkAndAnalyzes() async throws {
        let harness = try RepoLoadingHarness()
        defer { harness.cleanup() }

        let first = harness.makeStore()
        first.addRepository(at: harness.repoRoot)
        let id = try #require(first.repos.first?.id)
        _ = try await harness.waitForSettle(first, id)

        // "Relaunch": a fresh store from the same persistence file
        // must resolve the persisted bookmark and analyze again.
        let second = harness.makeStore()
        #expect(second.repos.map(\.id) == [id])
        second.selectedRepo = id
        second.analyze(id)
        guard case .ready = try await harness.waitForSettle(second, id) else {
            Issue.record("relaunched store failed to analyze: \(String(describing: second.states[id]))")
            return
        }
    }

    @Test func bookmarkRoundTripsAndGrantsAccess() async throws {
        let harness = try RepoLoadingHarness()
        defer { harness.cleanup() }

        let bookmark = try RepoAccess.bookmark(for: harness.repoRoot)
        let (resolved, isStale) = try RepoAccess.resolve(bookmark)
        #expect(resolved.standardizedFileURL.path == harness.repoRoot.standardizedFileURL.path)
        #expect(!isStale)

        let listed = try await RepoAccess.withAccess(to: resolved) { url in
            try FileManager.default.contentsOfDirectory(atPath: url.path)
        }
        #expect(listed.contains("Sources"))
    }

    @Test func movedFolderIsFollowedByItsBookmark() async throws {
        let harness = try RepoLoadingHarness()
        defer { harness.cleanup() }
        let store = harness.makeStore()

        store.addRepository(at: harness.repoRoot)
        let id = try #require(store.repos.first?.id)
        _ = try await harness.waitForSettle(store, id)

        // Bookmarks track the folder, not the path: a move still
        // analyzes, and the snapshot contains only ONE repo — never
        // a mix of workspace repos.
        let moved = harness.repoRoot.deletingLastPathComponent()
            .appendingPathComponent("repo-moved")
        try FileManager.default.moveItem(at: harness.repoRoot, to: moved)
        store.analyze(id)
        guard case .ready(let snapshot) = try await harness.waitForSettle(store, id) else {
            Issue.record("move should re-analyze via the bookmark")
            return
        }
        let repoNodes = snapshot.nodes.filter { $0.kind == "core:repository" }
        #expect(repoNodes.count == 1)
    }

    @Test func deletedFolderLandsInNeedsRelinkThenRelinkRecovers() async throws {
        let harness = try RepoLoadingHarness()
        defer { harness.cleanup() }
        let store = harness.makeStore()

        store.addRepository(at: harness.repoRoot)
        let id = try #require(store.repos.first?.id)
        _ = try await harness.waitForSettle(store, id)

        try FileManager.default.removeItem(at: harness.repoRoot)
        store.analyze(id)
        let state = try await harness.waitForSettle(store, id)
        #expect(state == .needsRelink)

        // The user locates a replacement folder; relink rebinds and
        // analyzes it.
        let replacement = harness.repoRoot.deletingLastPathComponent()
            .appendingPathComponent("repo-replacement")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        try "struct Replacement {}".write(
            to: replacement.appendingPathComponent("R.swift"),
            atomically: true, encoding: .utf8)
        store.relink(id, to: replacement)
        guard case .ready = try await harness.waitForSettle(store, id) else {
            Issue.record("relink did not recover")
            return
        }
        #expect(store.repos.first?.pathHint == replacement.path)
    }

    @Test func unreadableFolderSurfacesVisibleFailureNotSilence() async throws {
        let harness = try RepoLoadingHarness()
        defer { harness.cleanup() }
        let store = harness.makeStore()

        // A path that does not exist: bookmark creation fails, but
        // the repo row must still appear with a failed state.
        let bogus = harness.repoRoot.deletingLastPathComponent()
            .appendingPathComponent("does-not-exist")
        store.addRepository(at: bogus)
        #expect(store.repos.count == 1)
        let id = try #require(store.repos.first?.id)
        guard case .failed(let message)? = store.states[id] else {
            Issue.record("expected visible failure, got \(String(describing: store.states[id]))")
            return
        }
        #expect(!message.isEmpty)
    }
}
