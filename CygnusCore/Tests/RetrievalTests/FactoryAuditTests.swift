import Testing
import Foundation
import CygnusGraph
import CygnusStore
import CygnusProviders
@testable import CygnusRetrieval

// Two ways this audit can be actively harmful, both pinned here.
//
// Scoring an unadapted template as complete would present placeholders
// as documentation. And insisting on the template's file layout would
// report the canonical factory — which keeps its charter under
// `agents/` — as not running the pattern it is named after, teaching an
// agent to "fix" a working repository into the wrong shape.

@Suite struct FactoryAuditTests {
    private struct Fixture {
        let store: SQLiteGraphStore
        let audit: FactoryAudit
        let root: URL
        let repo: RepositoryID
    }

    /// Registers a repository whose snapshot contains exactly `files`.
    private func makeFixture(_ files: [String: String]) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SQLiteGraphStore.inMemory()
        let cas = try ContentStore(root: root.appendingPathComponent("cas"))
        let repo = RepositoryID("audit-repo")
        try store.registerRepository(repo, displayName: "Audited")

        var records: [SQLiteGraphStore.SnapshotFileRecord] = []
        for (path, contents) in files.sorted(by: { $0.key < $1.key }) {
            let blob = try cas.store(Data(contents.utf8))
            records.append(.init(path: path, blobHash: blob.raw,
                                 size: Int64(contents.utf8.count), languageHint: "markdown"))
        }
        let snapshot = try store.recordSnapshot(repository: repo, sourceRef: nil, files: records)
        _ = try store.commit(RevisionChanges(), note: "snapshot", snapshot: snapshot)

        return Fixture(store: store,
                       audit: FactoryAudit(store: store, contentStore: cas),
                       root: root, repo: repo)
    }

    private let realCharter = [
        "MISSION.md": "# thing\n\nWhat it is. Invariants: never ship red.",
        "AGENTS.md": "# thing\n\nRules: tests must pass.",
        "FACTORY.md": "# thing\n\nmake test is the oracle.",
    ]

    @Test func aFilledInFactoryReadsAsOperational() throws {
        let fixture = try makeFixture(realCharter)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let report = try #require(try fixture.audit.audit(repository: fixture.repo).first)
        #expect(report.isOperational)
        #expect(report.stubs.isEmpty)
    }

    /// An installed-but-unadapted template has every file and no
    /// factory. Counting files would score it complete, which is worse
    /// than scoring it absent — placeholders would read as docs.
    @Test func anUnadaptedTemplateIsNotOperational() throws {
        let fixture = try makeFixture([
            "MISSION.md": "# {{REPO_NAME}} — mission\n\n[One paragraph: the product]",
            "AGENTS.md": "# {{REPO_NAME}} — agent instructions",
            "FACTORY.md": "> FIRST RUN: rewrite every section below.",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let report = try #require(try fixture.audit.audit(repository: fixture.repo).first)
        #expect(!report.isOperational)
        #expect(report.stubs.count == 3)
        #expect(report.real.isEmpty)
        #expect(report.stubs.contains { $0.marker == "{{REPO_NAME}}" })
    }

    /// sloth keeps its charter under agents/. Reporting the canonical
    /// factory as not running the pattern would be worse than silence.
    @Test func theAgentsDirectoryLayoutCounts() throws {
        let fixture = try makeFixture([
            "agents/MISSION.md": "# sloth\n\nA passive network monitor.",
            "agents/AGENTS.md": "# sloth\n\nC99, no injection.",
            "agents/FACTORY.md": "# sloth\n\nmake check is the oracle.",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let report = try #require(try fixture.audit.audit(repository: fixture.repo).first)
        #expect(report.isOperational)
    }

    /// FIRST_RUN.md is the inversion: absent is the success condition,
    /// so it must never be listed as a gap.
    @Test func anAbsentFirstRunIsNotAGap() throws {
        let fixture = try makeFixture(realCharter)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let report = try #require(try fixture.audit.audit(repository: fixture.repo).first)
        #expect(!report.components.contains { $0.path == "FIRST_RUN.md" })
    }

    /// …and present means the adaptation never finished, whatever else
    /// looks complete.
    @Test func aPresentFirstRunBlocksOperational() throws {
        var files = realCharter
        files["FIRST_RUN.md"] = "# FIRST RUN\n\nAdapt the factory to this repository."
        let fixture = try makeFixture(files)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let report = try #require(try fixture.audit.audit(repository: fixture.repo).first)
        #expect(!report.isOperational)
        #expect(report.stubs.contains { $0.path == "FIRST_RUN.md" })
    }

    @Test func missingComponentsCarryWhyTheyMatter() throws {
        let fixture = try makeFixture(realCharter)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let report = try #require(try fixture.audit.audit(repository: fixture.repo).first)
        let decisions = try #require(report.missing.first { $0.path == "DECISIONS.md" })
        #expect(decisions.purpose.contains("refused"))
    }
}
