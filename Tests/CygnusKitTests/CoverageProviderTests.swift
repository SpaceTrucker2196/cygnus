import Testing
import Foundation
@testable import CygnusKit

struct CoverageProviderTests {
    /// End-to-end attribution against a real repo: runs one test
    /// class with coverage and harvests the artifact. Gated — it
    /// executes a repo's test suite.
    ///   CYGNUS_ATTR_REPO=/path CYGNUS_ATTR_CLASS=SomeTests
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CYGNUS_ATTR_REPO"] != nil))
    func attributesOneTestClassEndToEnd() async throws {
        let env = ProcessInfo.processInfo.environment
        let repo = URL(fileURLWithPath: env["CYGNUS_ATTR_REPO"]!)
        let testClass = env["CYGNUS_ATTR_CLASS"] ?? "GroupingTests"
        let attributed = try await TestCoverageAttribution.run(
            repoAt: repo, testClass: testClass, tooling: ProcessTooling())
        #expect(attributed.testClass == testClass)
        #expect(!attributed.report.byPath.isEmpty)
        print("ATTR: \(testClass) covers \(attributed.report.byPath.count) files, e.g. " +
              attributed.report.byPath.sorted { $0.value > $1.value }
                .prefix(3).map { "\($0.key)=\(Int($0.value * 100))%" }
                .joined(separator: ", "))
    }

    @Test func parsesLLVMCovExportRelativizedToRepo() throws {
        let root = URL(fileURLWithPath: "/tmp/repo")
        let json = """
        {"data":[{"files":[
          {"filename":"/tmp/repo/Sources/Kit/A.swift",
           "summary":{"lines":{"count":100,"covered":85,"percent":85.0}}},
          {"filename":"/tmp/repo/.build/checkouts/Dep/D.swift",
           "summary":{"lines":{"count":10,"covered":10,"percent":100.0}}},
          {"filename":"/usr/lib/other.swift",
           "summary":{"lines":{"count":5,"covered":0,"percent":0.0}}}
        ]}],"type":"llvm.coverage.json.export","version":"2.0.1"}
        """
        let parsed = try #require(CoverageProvider.parse(
            llvmCovJSON: Data(json.utf8), repoRoot: root))
        #expect(parsed == ["Sources/Kit/A.swift": 0.85])   // dep + SDK dropped

        let report = CoverageReport(byPath: parsed, source: "x")
        #expect(report.fraction(forPath: "Sources/Kit/A.swift") == 0.85)
        #expect(report.fraction(forPath: "Sources/Kit/B.swift") == nil)
        #expect(report.fraction(forPath: nil) == nil)
    }

    @Test func findsNewestCodecovArtifact() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-cov-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let codecov = root.appendingPathComponent(".build/arm64/debug/codecov")
        try FileManager.default.createDirectory(at: codecov, withIntermediateDirectories: true)
        try "{}".write(to: codecov.appendingPathComponent("old.json"),
                       atomically: true, encoding: .utf8)
        Thread.sleep(forTimeInterval: 0.02)
        try "{}".write(to: codecov.appendingPathComponent("default.json"),
                       atomically: true, encoding: .utf8)

        let found = try #require(CoverageProvider.newestArtifact(under: root))
        #expect(found.lastPathComponent == "default.json")
        #expect(CoverageProvider.newestArtifact(
            under: root.appendingPathComponent("missing")) == nil)
    }
}
