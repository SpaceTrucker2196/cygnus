import Testing
import Foundation
import CygnusGraph
import CygnusStore
import CygnusEngine
import CygnusProviders
@testable import CygnusRetrieval

// sloth is the first dark factory and the reference instance of the
// pattern. That makes it the audit's ground truth rather than just
// another repository: **when the audit and sloth disagree, the audit is
// wrong.**
//
// This is not hypothetical. The first version of FactoryAudit reported
// sloth as not running a dark factory, because sloth keeps its charter
// under `agents/` and the audit only knew the template's layout. An
// agent trusting that would have "fixed" the reference implementation
// into the wrong shape. These tests exist so that regression cannot
// happen twice.
//
// Gated like EndToEndSlothTests — the default `swift test` stays
// hermetic. Run with:
//   CYGNUS_E2E_SLOTH=1 swift test --filter SlothPatternTests

private let slothPath = ("~/projects/sloth" as NSString).expandingTildeInPath
private var e2eEnabled: Bool {
    ProcessInfo.processInfo.environment["CYGNUS_E2E_SLOTH"] == "1"
        && FileManager.default.fileExists(atPath: slothPath)
}

@Suite struct SlothPatternTests {
    /// Index sloth into a throwaway workspace and audit it.
    private func auditSloth() async throws -> FactoryAudit.Report {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-sloth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let workspace = try CygnusWorkspace(directory: directory)
        let id = try await workspace.register(path: URL(fileURLWithPath: slothPath))
        _ = try await workspace.index(id)
        let contentStore = try ContentStore(root: directory.appendingPathComponent("cas"))

        return try await workspace.withStore { store in
            try #require(try FactoryAudit(store: store, contentStore: contentStore)
                .audit(repository: id).first)
        }
    }

    /// The reference instance must read as a factory. If this fails,
    /// suspect the audit before suspecting sloth.
    @Test(.enabled(if: e2eEnabled))
    func theReferenceFactoryReadsAsOperational() async throws {
        let report = try await auditSloth()
        #expect(report.isOperational,
                "the audit no longer recognises the reference dark factory")
        print("sloth: \(report.real.count) real, \(report.stubs.count) unfilled, "
            + "\(report.missing.count) missing")
    }

    /// Specifically the `agents/` layout, which is what the first
    /// version got wrong.
    @Test(.enabled(if: e2eEnabled))
    func theAgentsLayoutIsRecognised() async throws {
        let report = try await auditSloth()
        let realPaths = Set(report.real.map(\.path))
        #expect(realPaths.contains("agents/MISSION.md") || realPaths.contains("MISSION.md"))
        #expect(realPaths.contains("agents/FACTORY.md") || realPaths.contains("FACTORY.md"))
    }

    /// Nothing in the reference factory should read as an unfilled
    /// template — it predates the template entirely.
    @Test(.enabled(if: e2eEnabled))
    func theReferenceFactoryHasNoPlaceholders() async throws {
        let report = try await auditSloth()
        #expect(report.stubs.isEmpty,
                "unexpected stubs: \(report.stubs.map(\.path))")
    }
}
