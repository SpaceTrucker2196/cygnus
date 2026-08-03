import Testing
import Foundation
import CygnusGraph
import CygnusStore
import CygnusQuery
import CygnusObservation
@testable import CygnusEngine

// Build files reaching the graph end to end: a Makefile and a
// Fastfile in a real fixture repo, indexed, with targets resolved
// against what the repository actually contains.

@Suite struct BuildGraphTests {
    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-build-\(UUID().uuidString)")
        let src = root.appendingPathComponent("src")
        let fastlane = root.appendingPathComponent("fastlane")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fastlane, withIntermediateDirectories: true)

        try "int main(void) { return 0; }\n".write(
            to: src.appendingPathComponent("main.c"), atomically: true, encoding: .utf8)
        try """
            .PHONY: all test

            all: app

            app: src/main.c
            \tclang -o app src/main.c

            test: app missing.c
            \t./app --test
            """.write(to: root.appendingPathComponent("Makefile"),
                      atomically: true, encoding: .utf8)
        try """
            platform :ios do
              private_lane :setup do
                cocoapods
              end

              lane :beta do
                setup
                build_app
              end
            end
            """.write(to: fastlane.appendingPathComponent("Fastfile"),
                      atomically: true, encoding: .utf8)
        let workflows = root.appendingPathComponent(".github/workflows")
        try FileManager.default.createDirectory(at: workflows,
                                                withIntermediateDirectories: true)
        try """
            name: Deploy
            jobs:
              beta:
                steps:
                  - run: bundle exec fastlane ios beta
            """.write(to: workflows.appendingPathComponent("deploy.yml"),
                      atomically: true, encoding: .utf8)
        return root
    }

    private func makeWorkspace() throws -> CygnusWorkspace {
        try CygnusWorkspace(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-build-ws-\(UUID().uuidString)"))
    }

    @Test func buildTargetsAndTheirCouplingReachTheGraph() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try makeWorkspace()
        let repo = try await workspace.register(path: root)
        _ = try await workspace.index(repo)
        let store = await workspace.store

        func target(_ path: String, _ name: String) throws -> ResolvedEntity? {
            try store.entity(stableKey: StableKeys.buildTarget(repo, path: path, name: name),
                             at: .current)
        }

        // Make targets and fastlane lanes are both build targets.
        #expect(try target("Makefile", "app")?.entity.kind == .buildTarget)
        #expect(try target("Makefile", "all") != nil)
        #expect(try target("fastlane/Fastfile", "beta")?.entity.kind == .buildTarget)
        #expect(try target("fastlane/Fastfile", "setup") != nil)

        let builds = try store.relationships(kind: .builds, at: .current)
        let entityIDs = Set(builds.flatMap { [$0.source, $0.target] })
        let byID = Dictionary(uniqueKeysWithValues: try store
            .entities(ids: Array(entityIDs), at: .current)
            .map { ($0.entity.id, $0) })
        let pairs = Set(builds.compactMap { edge -> String? in
            guard let from = byID[edge.source], let to = byID[edge.target] else { return nil }
            return "\(from.version.name)→\(to.version.name)"
        })

        // A prerequisite that names a real file couples the target to
        // it — the overgrowth link that did not exist before.
        #expect(pairs.contains("app→main.c"), "expected app→main.c in \(pairs)")
        // A prerequisite naming a sibling target links target→target.
        #expect(pairs.contains("all→app"))
        #expect(pairs.contains("test→app"))
        // A lane calling another lane is the same shape.
        #expect(pairs.contains("beta→setup"))
        // A prerequisite that names nothing in the repository invents
        // no edge — missing.c is not there, and a fastlane action is
        // not a lane.
        #expect(!pairs.contains { $0.hasSuffix("→missing.c") })
        #expect(!pairs.contains { $0.hasSuffix("→build_app") })
    }

    /// The recipe reaches the graph in order, as a property rather
    /// than a child entity per command. This is what a flowchart
    /// needs to be a projection of the graph instead of a second
    /// parse of the same file.
    @Test func recipesReachTheGraphInOrder() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try makeWorkspace()
        let repo = try await workspace.register(path: root)
        _ = try await workspace.index(repo)
        let store = await workspace.store

        let app = try #require(try store.entity(
            stableKey: StableKeys.buildTarget(repo, path: "Makefile", name: "app"),
            at: .current))
        guard case .array(let steps)? = app.version.properties["core:buildSteps"] else {
            Issue.record("no recipe on the target")
            return
        }
        #expect(steps.count == 1)
        if case .string(let command) = steps[0] {
            #expect(command == "clang -o app src/main.c")
        }
        // Which build system said so travels with it, so a renderer
        // can word itself for lanes or targets without re-reading the
        // file to find out.
        #expect(app.version.properties["core:buildSystem"] == .string("make"))

        let beta = try #require(try store.entity(
            stableKey: StableKeys.buildTarget(repo, path: "fastlane/Fastfile", name: "beta"),
            at: .current))
        #expect(beta.version.properties["core:buildSystem"] == .string("fastlane"))
    }

    /// A CI workflow whose command line names a lane invokes it —
    /// the fact that puts trigger columns on a fastlane pipeline
    /// chart without a second scan of .github/workflows.
    @Test func workflowInvocationsLinkToTheLaneTheyName() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try makeWorkspace()
        let repo = try await workspace.register(path: root)
        _ = try await workspace.index(repo)
        let store = await workspace.store

        let invokes = try store.relationships(kind: .invokes, at: .current)
        let entityIDs = Set(invokes.flatMap { [$0.source, $0.target] })
        let byID = Dictionary(uniqueKeysWithValues: try store
            .entities(ids: Array(entityIDs), at: .current)
            .map { ($0.entity.id, $0) })
        let pairs = Set(invokes.compactMap { edge -> String? in
            guard let from = byID[edge.source], let to = byID[edge.target] else { return nil }
            return "\(from.version.name)→\(to.version.name)"
        })
        #expect(pairs.contains("deploy.yml→beta"), "expected deploy.yml→beta in \(pairs)")
        // The command names beta, not setup — no edge is invented for
        // lanes the workflow does not run.
        #expect(!pairs.contains { $0.hasSuffix("→setup") })
    }

    /// Build facts carry provenance like every other derived or
    /// observed fact, so they die with the file that stated them.
    @Test func buildFactsVanishWhenTheBuildFileDoes() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try makeWorkspace()
        let repo = try await workspace.register(path: root)
        _ = try await workspace.index(repo)
        let store = await workspace.store
        #expect(try !store.relationships(kind: .builds, at: .current).isEmpty)

        try FileManager.default.removeItem(at: root.appendingPathComponent("Makefile"))
        _ = try await workspace.index(repo)

        #expect(try store.entity(
            stableKey: StableKeys.buildTarget(repo, path: "Makefile", name: "app"),
            at: .current) == nil, "the Makefile's targets should be retracted with it")
        // The Fastfile is untouched, so its lanes remain.
        #expect(try store.entity(
            stableKey: StableKeys.buildTarget(repo, path: "fastlane/Fastfile", name: "beta"),
            at: .current) != nil)
    }
}
