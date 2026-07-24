import Testing
import Foundation
import CygnusGraph
import CygnusStore
import CygnusQuery
import CygnusObservation
@testable import CygnusEngine

// End-to-end: fixture repo → register → index → query → edit →
// incremental re-index. This is the engine's acceptance suite.

@Suite struct WorkspaceTests {
    @Test func indexAbortsAtHardMemoryLimitWithoutCommitting() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-hardlimit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = try CygnusWorkspace(directory: dir)
        let repo = try await workspace.register(path: root)

        // A 1-byte hard limit is always exceeded by the live process —
        // the abort must fire and the store must stay uncommitted.
        let strangled = IndexLimits(maxConcurrentExtractions: 2,
                                    softMemoryLimitBytes: nil,
                                    hardMemoryLimitBytes: 1)
        await #expect(throws: WorkspaceError.self) {
            try await workspace.index(repo, limits: strangled)
        }
        #expect(try await workspace.store.currentRevision() == nil)

        // Same workspace recovers with a sane limit.
        let result = try await workspace.index(repo)
        #expect(result.entityCount > 0)
    }

    func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-e2e-\(UUID().uuidString)")
        let sources = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
            import Foundation

            struct Graph {
                func build() -> Int { 42 }
            }
            """.write(to: sources.appendingPathComponent("Graph.swift"),
                      atomically: true, encoding: .utf8)
        try """
            import os

            def ingest(path):
                return path

            class Pipeline:
                def run(self):
                    pass
            """.write(to: root.appendingPathComponent("ingest.py"),
                      atomically: true, encoding: .utf8)
        try """
            #include <stdio.h>

            struct buffer { int size; };

            int flush(void) { return 0; }
            """.write(to: root.appendingPathComponent("io.c"),
                      atomically: true, encoding: .utf8)
        return root
    }

    func makeWorkspace() throws -> CygnusWorkspace {
        try CygnusWorkspace(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-ws-\(UUID().uuidString)"))
    }

    @Test func indexBuildsCrossLanguageGraph() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try makeWorkspace()
        let repo = try await workspace.register(path: root)
        let result = try await workspace.index(repo)

        #expect(result.revision.raw == 1)
        #expect(result.filesAnalyzed == 3)

        let store = await workspace.store

        // Swift declaration, nested.
        let graphType = try store.entity(
            stableKey: StableKeys.declaration(repo, language: "swift",
                                              path: "Sources/Graph.swift", declPath: "Graph"),
            at: .current)
        #expect(graphType?.entity.kind == .type)

        // Python class + function.
        #expect(try store.entity(
            stableKey: StableKeys.declaration(repo, language: "python",
                                              path: "ingest.py", declPath: "Pipeline.run"),
            at: .current)?.entity.kind == .function)

        // C struct + include-as-module.
        #expect(try store.entity(
            stableKey: StableKeys.declaration(repo, language: "c",
                                              path: "io.c", declPath: "buffer"),
            at: .current)?.entity.kind == .type)
        #expect(try store.entity(
            stableKey: StableKeys.module(language: "c", name: "stdio.h"),
            at: .current) != nil)

        // Imports edges from all three languages.
        let deps = try Projections.dependencyGraph(store: store)
        let moduleNames = Set(deps.entities.filter { $0.entity.kind == .module }
            .map(\.version.name))
        #expect(moduleNames == ["Foundation", "os", "stdio.h"])

        // Containment tree: repo root → Sources → Graph.swift → Graph → build().
        let trees = try Projections.containsTrees(store: store)
        #expect(trees.count == 1)
        let sources = trees[0].children.first { $0.entity.version.name == "Sources" }
        let graphFile = sources?.children.first { $0.entity.version.name == "Graph.swift" }
        let graphDecl = graphFile?.children.first { $0.entity.version.name == "Graph" }
        #expect(graphDecl?.children.map(\.entity.version.name) == ["build()"])
    }

    @Test func reindexUnchangedIsIdempotent() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try makeWorkspace()
        let repo = try await workspace.register(path: root)
        let first = try await workspace.index(repo)
        let store = await workspace.store
        let before = try Projections.dependencyGraph(store: store)

        let second = try await workspace.index(repo)
        #expect(second.filesChanged == 0)
        // No empty revision minted for a no-op re-index.
        #expect(second.revision == first.revision)
        #expect(try store.revisions().count == 1)
        let after = try Projections.dependencyGraph(store: store)
        #expect(after.relationships.count == before.relationships.count)
    }

    @Test func verifyIsCleanAfterIncrementalEdits() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try makeWorkspace()
        let repo = try await workspace.register(path: root)
        _ = try await workspace.index(repo)

        // Edit, add, delete — then compare incremental against a
        // cold rebuild.
        try """
            import CoreGraphics
            struct Graph { func render() -> Int { 1 } }
            enum Palette { case mono }
            """.write(to: root.appendingPathComponent("Sources/Graph.swift"),
                      atomically: true, encoding: .utf8)
        try "def added(): pass\n".write(to: root.appendingPathComponent("added.py"),
                                        atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appendingPathComponent("io.c"))
        _ = try await workspace.index(repo)

        let report = try await workspace.verify(repo)
        #expect(report.staleFacts.isEmpty)
        #expect(report.missingFacts.isEmpty)
    }

    @Test func diffReportsRevisionDelta() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try makeWorkspace()
        let repo = try await workspace.register(path: root)
        let first = try await workspace.index(repo)

        try "def added(): pass\n".write(to: root.appendingPathComponent("added.py"),
                                        atomically: true, encoding: .utf8)
        let second = try await workspace.index(repo)

        let delta = try await workspace.store.diff(from: first.revision, to: second.revision)
        let addedNames = delta.assertedEntityVersions.map(\.version.name)
        #expect(addedNames.contains("added.py"))
        #expect(addedNames.contains("added()") || addedNames.contains("added"))
        #expect(delta.retractedEntityVersions.isEmpty)
    }

    @Test func incrementalReindexRetractsVanishedFacts() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try makeWorkspace()
        let repo = try await workspace.register(path: root)
        _ = try await workspace.index(repo)
        let store = await workspace.store

        let buildKey = StableKeys.declaration(repo, language: "swift",
                                              path: "Sources/Graph.swift",
                                              declPath: "Graph.build()")
        #expect(try store.entity(stableKey: buildKey, at: .current) != nil)

        // Rename build() → render() and drop the Foundation import.
        try """
            struct Graph {
                func render() -> Int { 42 }
            }
            """.write(to: root.appendingPathComponent("Sources/Graph.swift"),
                      atomically: true, encoding: .utf8)
        let second = try await workspace.index(repo)
        #expect(second.filesChanged == 1)

        // Old fact gone from current, new fact present, history intact.
        #expect(try store.entity(stableKey: buildKey, at: .current) == nil)
        #expect(try store.entity(stableKey: buildKey, at: .asOf(RevisionID(1))) != nil)
        let renderKey = StableKeys.declaration(repo, language: "swift",
                                               path: "Sources/Graph.swift",
                                               declPath: "Graph.render()")
        #expect(try store.entity(stableKey: renderKey, at: .current) != nil)

        // The file's Foundation import edge was retracted with the change.
        let fileKey = StableKeys.file(repo, "Sources/Graph.swift")
        let imports = try store.relationships(from: fileKey, kind: .imports, at: .current)
        #expect(imports.isEmpty)

        // Deleting a file retracts its whole subtree.
        try FileManager.default.removeItem(at: root.appendingPathComponent("io.c"))
        _ = try await workspace.index(repo)
        #expect(try store.entity(stableKey: StableKeys.file(repo, "io.c"), at: .current) == nil)
        #expect(try store.entity(
            stableKey: StableKeys.declaration(repo, language: "c", path: "io.c", declPath: "flush"),
            at: .current) == nil)
    }

    @Test func provenanceLinksFactsToObservations() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try makeWorkspace()
        let repo = try await workspace.register(path: root)
        _ = try await workspace.index(repo)
        let store = await workspace.store

        let graphType = try #require(try store.entity(
            stableKey: StableKeys.declaration(repo, language: "swift",
                                              path: "Sources/Graph.swift", declPath: "Graph"),
            at: .current))
        let supporting = try store.provenance(ofEntityVersion: graphType.version.id)
        #expect(!supporting.isEmpty)
    }

    @Test func searchFindsDeclarationsAcrossLanguages() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try makeWorkspace()
        let repo = try await workspace.register(path: root)
        _ = try await workspace.index(repo)
        let hits = try await workspace.store.searchNames("Pipe", limit: 5)
        #expect(hits.map(\.version.name) == ["Pipeline"])
    }
}
