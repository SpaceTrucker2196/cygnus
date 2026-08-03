import Testing
import Foundation
import CygnusGraph
import CygnusStore
import CygnusObservation
@testable import CygnusEngine

// Ownership end to end, against a real git repository built in a temp
// directory: observed touches, derived counts, inferred ownership.

@Suite struct OwnershipTests {
    private func git(_ arguments: [String], in root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root.path] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
    }

    /// A repo where one file is clearly one author's and another is
    /// genuinely shared.
    private func makeRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-own-\(UUID().uuidString)")
        let sources = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try git(["init", "-q"], in: root)
        try git(["config", "user.name", "Ada"], in: root)
        try git(["config", "user.email", "ada@example.com"], in: root)

        func commit(_ file: String, _ body: String, as author: (String, String)) throws {
            try body.write(to: sources.appendingPathComponent(file),
                           atomically: true, encoding: .utf8)
            try git(["add", "Sources/\(file)"], in: root)
            try git(["-c", "user.name=\(author.0)", "-c", "user.email=\(author.1)",
                     "commit", "-q", "-m", "touch \(file)",
                     "--author=\(author.0) <\(author.1)>"], in: root)
        }

        let ada = ("Ada", "ada@example.com")
        let grace = ("Grace", "grace@example.com")
        // Ada owns hers outright.
        for i in 1...3 {
            try commit("Ada.swift", "struct Ada { let v\(i) = \(i) }\n", as: ada)
        }
        // Shared.swift is split evenly — nobody dominates.
        try commit("Shared.swift", "struct Shared { let a = 1 }\n", as: ada)
        try commit("Shared.swift", "struct Shared { let a = 2 }\n", as: grace)
        return root
    }

    private func makeWorkspace() throws -> CygnusWorkspace {
        try CygnusWorkspace(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-own-ws-\(UUID().uuidString)"))
    }

    @Test func authorshipBecomesCountsAndOwnership() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try makeWorkspace()
        let repo = try await workspace.register(path: root)
        _ = try await workspace.index(repo)
        let store = await workspace.store

        // People are entities, and not scoped to one repository.
        let ada = try #require(try store.entity(
            stableKey: StableKeys.person("ada@example.com"), at: .current))
        #expect(ada.entity.kind == .person)
        #expect(ada.entity.repository == nil)

        let authored = try store.relationships(kind: .authoredBy, at: .current)
        let owned = try store.relationships(kind: .ownedBy, at: .current)
        let entityIDs = Set((authored + owned).flatMap { [$0.source, $0.target] })
        let byID = Dictionary(uniqueKeysWithValues: try store
            .entities(ids: Array(entityIDs), at: .current).map { ($0.entity.id, $0) })
        func pairs(_ edges: [Relationship]) -> Set<String> {
            Set(edges.compactMap { edge in
                guard let from = byID[edge.source], let to = byID[edge.target] else { return nil }
                return "\(from.version.name)→\(to.version.name)"
            })
        }

        // Derived: who touched what, with counts.
        #expect(pairs(authored).contains("Ada.swift→Ada"))
        #expect(pairs(authored).contains("Shared.swift→Ada"))
        #expect(pairs(authored).contains("Shared.swift→Grace"))
        let adaCount = authored.first {
            byID[$0.source]?.version.name == "Ada.swift"
        }.flatMap { edge -> Int64? in
            if case .int(let n)? = edge.properties["core:commitCount"] { n } else { nil }
        }
        #expect(adaCount == 3, "three commits to Ada.swift")

        // Inferred: a clear owner where one author dominates, and no
        // owner at all where two split it evenly. "Nobody owns this"
        // is the finding, not a missing answer.
        #expect(pairs(owned).contains("Ada.swift→Ada"))
        #expect(!pairs(owned).contains { $0.hasPrefix("Shared.swift→") },
                "an evenly split file must not be assigned an owner")

        // Layers are not decorative: counting is derived, judgement is
        // inferred.
        #expect(authored.allSatisfy { $0.layer == .derived })
        #expect(owned.allSatisfy { $0.layer == .inferred })
    }

    /// A person carries when they last committed, which is what makes
    /// "everyone who worked on this has gone" answerable at all.
    @Test func peopleCarryTheirLastCommitDate() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try makeWorkspace()
        let repo = try await workspace.register(path: root)
        _ = try await workspace.index(repo)
        let store = await workspace.store

        let ada = try #require(try store.entity(
            stableKey: StableKeys.person("ada@example.com"), at: .current))
        guard case .string(let raw)? = ada.version.properties["core:lastCommit"] else {
            Issue.record("no last-commit date on the person")
            return
        }
        let date = try #require(ISO8601DateFormatter().date(from: raw))
        // The fixture commits now, so "last commit" must be recent —
        // a date that fails to parse or lands in 1970 is the bug this
        // catches.
        #expect(Date().timeIntervalSince(date) < 3600)
    }

    /// Ownership facts carry provenance to the authorship
    /// observations, so they are invalidated like everything else.
    @Test func ownershipFactsCarryProvenance() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try makeWorkspace()
        let repo = try await workspace.register(path: root)
        _ = try await workspace.index(repo)
        let store = await workspace.store

        let owned = try store.relationships(kind: .ownedBy, at: .current)
        let edge = try #require(owned.first)
        #expect(try !store.provenance(ofRelationship: edge.id).isEmpty,
                "an inferred fact with no evidence behind it should not exist")
    }

    /// A repository without git is not an error — it simply has no
    /// ownership facts.
    @Test func aRepoWithoutGitHasNoOwnership() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "struct A {}\n".write(to: root.appendingPathComponent("Sources/A.swift"),
                                  atomically: true, encoding: .utf8)
        let workspace = try makeWorkspace()
        let repo = try await workspace.register(path: root)
        _ = try await workspace.index(repo)
        let store = await workspace.store
        #expect(try store.relationships(kind: .authoredBy, at: .current).isEmpty)
    }
}
