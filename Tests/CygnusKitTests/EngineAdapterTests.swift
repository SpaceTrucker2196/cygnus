import Testing
import Foundation
@testable import CygnusKit

// The exact code path the app runs: real engine behind the seam,
// fixture repo on disk, snapshot projection at the end.

@Suite struct EngineAdapterTests {
    @Test func realEngineAnalyzesARepoIntoASnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
            import Foundation
            struct Rocket { func launch() {} }
            """.write(to: root.appendingPathComponent("Sources/Rocket.swift"),
                      atomically: true, encoding: .utf8)

        let engine = WorkspaceGraphEngine(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-adapter-ws-\(UUID().uuidString)"))

        var phases: [String] = []
        var partials: [GraphSnapshot] = []
        var snapshot: GraphSnapshot?
        for try await event in engine.analyze(repoAt: root) {
            switch event {
            case .phase(let phase): phases.append(phase)
            case .partial(let partial):
                #expect(snapshot == nil, "partials must precede finished")
                partials.append(partial)
            case .finished(let result): snapshot = result
            default: break
            }
        }

        let result = try #require(snapshot)
        #expect(phases.first == "scanning")
        #expect(phases.contains("projecting"))

        // Realtime rendering: at least the physical-tree partial
        // arrived before the final snapshot, and partials only grow.
        #expect(!partials.isEmpty)
        #expect(partials.first!.nodes.contains { $0.kind == "core:file" })
        let counts = partials.map(\.nodes.count)
        #expect(counts == counts.sorted())

        let index = SnapshotIndex(result)
        #expect(index.trees.count == 1)
        let rocket = result.nodes.first { $0.label == "Rocket" }
        #expect(rocket?.kind == "core:type")
        #expect(rocket?.path == "Sources/Rocket.swift")
        // Import edge reached the module node.
        #expect(result.nodes.contains { $0.kind == "core:module" && $0.label == "Foundation" })
        #expect(result.edges.contains { $0.kind == "core:imports" })
        // Declares chain: file → Rocket → launch().
        let launch = result.nodes.first { $0.label == "launch()" }
        #expect(launch != nil)
    }
}
