import Testing
import Foundation
@testable import CygnusKit

@Suite struct PersistenceTests {
    @Test func registryRoundTripsThroughJSON() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-kit-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let persistence = WorkspacePersistence(fileURL: file)
        #expect(persistence.load().isEmpty)

        let repo = RegisteredRepo(displayName: "demo", pathHint: "/tmp/demo",
                                  bookmark: Data([1, 2, 3]))
        try persistence.save([repo])
        #expect(persistence.load() == [repo])
    }
}

@Suite struct SnapshotIndexTests {
    @Test func buildsTreeAdjacencyAndSearch() {
        let index = SnapshotIndex(.sample)
        #expect(index.trees.count == 1)
        #expect(index.trees[0].node.kind == "core:repository")
        #expect(index.trees[0].children?.map(\.node.label) == ["A.swift", "B.swift"])

        // A.swift has the imports edge to B.swift.
        let aID = "phys:file:fixture/A.swift"
        #expect(index.outgoing[aID]?.contains { $0.kind == "core:imports" } == true)
        #expect(index.incoming["phys:file:fixture/B.swift"]?.count == 2)

        #expect(index.search("a.SW").map(\.id) == [aID])
        #expect(index.search("  ").isEmpty)
    }
}

@Suite @MainActor struct WorkspaceStoreTests {
    func makeStore() -> WorkspaceStore {
        WorkspaceStore(
            engine: FixtureGraphEngine(),
            persistence: WorkspacePersistence(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("cygnus-store-\(UUID().uuidString).json")))
    }

    @Test func analyzeRunsToReadyWithIndex() async throws {
        let store = makeStore()
        // Bookmarks can't be created for arbitrary paths in tests;
        // exercise the state machine via the engine stream directly.
        let repo = RegisteredRepo(displayName: "fixture", pathHint: "/tmp/fixture",
                                  bookmark: Data())
        store.testInject(repo: repo)
        store.selectedRepo = repo.id

        for try await event in FixtureGraphEngine().analyze(repoAt: URL(fileURLWithPath: "/tmp")) {
            store.testApply(event, to: repo.id)
        }
        guard case .ready(let snapshot)? = store.currentState else {
            Issue.record("expected ready state")
            return
        }
        #expect(snapshot == .sample)
        #expect(store.currentIndex != nil)
        store.selectedNode = "phys:file:fixture/A.swift"
        #expect(store.selectedNodeValue?.label == "A.swift")
    }
}
