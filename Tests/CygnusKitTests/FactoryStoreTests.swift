import Testing
import Foundation
@testable import CygnusKit

// The store's factory loading: Loadable transitions, per-repo
// isolation, capability gating, and doc save — driven through the
// fixture providers with no network.

@MainActor
@Suite struct FactoryStoreTests {

    private func makeStore(factory: FixtureFactoryProvider = FixtureFactoryProvider(),
                           docs: FixtureDocsProvider = FixtureDocsProvider()) -> (WorkspaceStore, UUID, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = WorkspaceStore(engine: FixtureGraphEngine(),
                                   persistence: WorkspacePersistence(fileURL:
                                    dir.appendingPathComponent("ws.json")),
                                   factory: factory, docs: docs)
        let repo = RegisteredRepo(displayName: "r", pathHint: dir.path, bookmark: Data())
        store.testInject(repo: repo)
        return (store, repo.id, dir)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func capabilitiesLoad() async {
        let (store, id, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.refreshCapabilities(id)
        await waitUntil { store.factoryState(for: id).capabilities.value != nil }
        #expect(store.factoryState(for: id).caps.github)
    }

    @Test func issuesTransitionIdleLoadingLoaded() async {
        let (store, id, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Seed capabilities so the GitHub gate passes.
        store.testInjectFactory({ var s = FactoryState(); s.capabilities = .loaded(.sample); return s }(), to: id)

        #expect(store.factoryState(for: id).issues.isIdle)
        store.refreshIssues(id)
        await waitUntil { store.factoryState(for: id).issues.value != nil }
        #expect(store.factoryState(for: id).issues.value?.count == Issue.samples.count)
    }

    @Test func githubGateFailsWithoutRemote() async {
        var caps = FactoryCapabilities.sample
        caps.remote = nil
        let (store, id, dir) = makeStore(factory: FixtureFactoryProvider(capabilities: caps))
        defer { try? FileManager.default.removeItem(at: dir) }
        store.testInjectFactory({ var s = FactoryState(); s.capabilities = .loaded(caps); return s }(), to: id)

        store.refreshIssues(id)
        #expect(store.factoryState(for: id).issues.errorMessage?.contains("GitHub unavailable") == true)
    }

    @Test func localDatasetsLoadWithoutGitHub() async {
        let (store, id, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.refreshMetrics(id)
        store.refreshConverge(id)
        await waitUntil {
            store.factoryState(for: id).metrics.value != nil
            && store.factoryState(for: id).converge.value != nil
        }
        #expect(store.factoryState(for: id).metrics.value?.isEmpty == false)
        #expect(store.factoryState(for: id).converge.value??.steps.count == 9)
    }

    @Test func perRepoIsolation() async {
        let (store, id1, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo2 = RegisteredRepo(displayName: "r2", pathHint: dir.path, bookmark: Data())
        store.testInject(repo: repo2)

        store.refreshMetrics(id1)
        await waitUntil { store.factoryState(for: id1).metrics.value != nil }
        #expect(store.factoryState(for: id1).metrics.value != nil)
        #expect(store.factoryState(for: repo2.id).metrics.isIdle)   // untouched
    }

    @Test func sectionSelectionDefaultsAndRemembers() {
        let (store, id, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.selectedRepo = id
        store.testInjectFactory({ var s = FactoryState(); s.capabilities = .loaded(.sample); return s }(), to: id)
        #expect(store.selectedSection == .dashboard)         // factory detected → dashboard
        store.selectedSection = .issues
        #expect(store.selectedSection == .issues)             // remembered per repo
        #expect(store.sectionByRepo[id] == .issues)
    }

    @Test func saveDocThroughStore() async throws {
        let (store, id, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await store.saveDoc("docs/x.md", content: "hi", commit: nil, for: id)
        #expect(!result.committed)
    }

    @Test func saveReadOnlyDocThrows() async {
        let (store, id, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: DocsError.readOnly("LEDGER.md")) {
            _ = try await store.saveDoc("LEDGER.md", content: "x", commit: nil, for: id)
        }
    }
}
