import Foundation
import CygnusEngine
import CygnusProviders
@testable import CygnusMCP

// A real workspace over a tiny fixture repository. Hermetic: temp
// directory, no network, no Xcode, and indexed in-process so the tools
// are exercised against genuine graph facts rather than a fake.

enum Fixtures {
    static func handlers() async throws -> ToolHandlers {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-mcp-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo/Sources")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        try """
            public struct Engine {
                public func start() {}
                public func stop() {}
            }
            """.write(to: repo.appendingPathComponent("Engine.swift"),
                      atomically: true, encoding: .utf8)
        try """
            struct Runner {
                let engine = Engine()
                func go() { engine.start() }
            }
            """.write(to: repo.appendingPathComponent("Runner.swift"),
                      atomically: true, encoding: .utf8)

        let workspace = try CygnusWorkspace(
            directory: root.appendingPathComponent("workspace"))
        let id = try await workspace.register(path: root.appendingPathComponent("repo"))
        _ = try await workspace.index(id)

        let contentStore = try ContentStore(
            root: root.appendingPathComponent("workspace/cas"))
        return ToolHandlers(workspace: workspace, contentStore: contentStore)
    }
}
