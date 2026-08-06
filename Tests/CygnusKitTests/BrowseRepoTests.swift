import Testing
import Foundation
@testable import CygnusKit

// "Can it load a repo and can you browse it" — the question the
// XCUITest suite existed to answer, asked headlessly.
//
// The UI tests were removed because they never passed: XCUITest
// launches a SwiftUI WindowGroup app without it ever presenting a
// window on this OS, verified independently of XCUITest's own
// accessibility tree (DECISIONS.md D9). What they *asserted* is still
// worth asserting, and none of it actually needed a window — the
// sidebar row is `store.repos`, the outline is the containment tree,
// the flat view is a `GraphScene`, the search field is
// `SnapshotIndex.search`, and the inspector is a node's own fields.
//
// This trades UI-layer coverage for coverage that runs. That trade is
// recorded rather than implied: nothing here proves a button is
// clickable, and if the shell breaks, these tests stay green.

@Suite @MainActor struct BrowseRepoTests {
    /// A fixture with two files and a cross-file reference, so the
    /// dependency scene has an edge to draw rather than two islands.
    private func makeHarness() throws -> RepoLoadingHarness {
        let harness = try RepoLoadingHarness()
        let sources = harness.repoRoot.appendingPathComponent("Sources")
        try """
            public struct Core {
                public func tick() {}
            }
            """.write(to: sources.appendingPathComponent("Core.swift"),
                      atomically: true, encoding: .utf8)
        try """
            import CygnusKitFixture

            struct AppMain {
                let core = Core()
                func run() { core.tick() }
            }
            """.write(to: sources.appendingPathComponent("AppMain.swift"),
                      atomically: true, encoding: .utf8)
        return harness
    }

    private func readySnapshot(_ harness: RepoLoadingHarness) async throws
        -> (store: WorkspaceStore, id: UUID, snapshot: GraphSnapshot) {
        let store = harness.makeStore()
        store.addRepository(at: harness.repoRoot)
        let id = try #require(store.repos.first?.id)
        let state = try await harness.waitForSettle(store, id)
        guard case .ready(let snapshot) = state else {
            Issue.record("analysis did not reach ready: \(state)")
            throw CancellationError()
        }
        return (store, id, snapshot)
    }

    /// The sidebar row the UI test looked for is a registered repo.
    @Test func aLoadedRepositoryIsRegisteredAndReachesReady() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let (store, id, snapshot) = try await readySnapshot(harness)

        #expect(store.repos.contains { $0.id == id })
        #expect(store.repos.first?.displayName == harness.repoRoot.lastPathComponent)
        #expect(!snapshot.nodes.isEmpty)
    }

    /// The outline: the containment tree the sidebar renders.
    @Test func theContainmentTreeCoversTheFixturesSources() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let (_, _, snapshot) = try await readySnapshot(harness)

        let index = SnapshotIndex(snapshot)
        let names = Set(snapshot.nodes.map(\.label))
        #expect(names.contains("Core.swift"))
        #expect(names.contains("AppMain.swift"))
        // The outline renders `trees`; a ready repo has at least one root.
        #expect(!index.trees.isEmpty)
    }

    /// The Flat view's Code scene: what the "N nodes" overlay counted.
    /// `dependencies`, not `build` — the latter charts build targets
    /// and is legitimately empty for a fixture with no Makefile.
    @Test func theCodeSceneHasNodesToRender() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let (_, _, snapshot) = try await readySnapshot(harness)

        let scene = GraphScene.dependencies(from: snapshot)
        #expect(!scene.nodes.isEmpty)
        #expect(scene.nodes.contains { $0.label == "AppMain.swift" })
    }

    /// And the Build scene is empty here — asserted rather than left
    /// implicit, so the distinction between the two survives someone
    /// later "fixing" whichever one they reach for first.
    @Test func theBuildSceneIsEmptyWithoutBuildFiles() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let (_, _, snapshot) = try await readySnapshot(harness)

        #expect(GraphScene.build(from: snapshot).nodes.isEmpty)
    }

    /// The search field, and the inspector that fills from a selection:
    /// a hit carries the kind the inspector shows.
    @Test func searchFindsADeclarationAndItCarriesInspectorDetail() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let (_, _, snapshot) = try await readySnapshot(harness)

        let index = SnapshotIndex(snapshot)
        let hits = index.search("AppMain")
        let hit = try #require(hits.first { $0.label.contains("AppMain") },
                               "search found no AppMain declaration")
        // "Kind" is the first row the inspector populates.
        #expect(!hit.kind.isEmpty)
    }

    /// Re-analysis of an unchanged tree stays ready rather than
    /// thrashing — the app re-analyzes on focus, so this is the common
    /// case, not an edge one.
    @Test func reanalyzingAnUnchangedRepositoryStaysReady() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let (store, id, _) = try await readySnapshot(harness)

        store.analyze(id)
        let state = try await harness.waitForSettle(store, id)
        guard case .ready = state else {
            Issue.record("re-analysis left the repo in \(state)")
            return
        }
    }
}
