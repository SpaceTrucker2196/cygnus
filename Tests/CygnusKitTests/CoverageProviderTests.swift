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
        ],"functions":[
          {"filenames":["/tmp/repo/Sources/Kit/A.swift"],
           "regions":[[10,1,20,2,3,0,0,0],[12,1,14,2,0,0,0,0]]},
          {"filenames":["/tmp/repo/.build/checkouts/Dep/D.swift"],
           "regions":[[1,1,2,2,9,0,0,0]]}
        ]}],"type":"llvm.coverage.json.export","version":"2.0.1"}
        """
        let parsed = try #require(CoverageProvider.parse(
            llvmCovJSON: Data(json.utf8), repoRoot: root))
        #expect(parsed.lines == ["Sources/Kit/A.swift": 0.85])   // dep + SDK dropped

        let report = CoverageReport(byPath: parsed.lines,
                                    functionsByPath: parsed.functions, source: "x")
        #expect(report.fraction(forPath: "Sources/Kit/A.swift") == 0.85)
        #expect(report.fraction(forPath: "Sources/Kit/B.swift") == nil)
        // Function spanning lines 10–20, one of two regions covered → 0.5.
        #expect(report.functionFraction(path: "Sources/Kit/A.swift", line: 15) == 0.5)
        #expect(report.functionFraction(path: "Sources/Kit/A.swift", line: 99) == nil)
        // Dep function dropped with .build.
        #expect(report.functionsByPath[".build/checkouts/Dep/D.swift"] == nil)
    }

    @Test func mergedUnionsFunctionSpans() {
        let a = CoverageReport(byPath: ["F.swift": 0.4],
            functionsByPath: ["F.swift": [.init(start: 1, end: 5, fraction: 0.3)]], source: "a")
        let b = CoverageReport(byPath: ["F.swift": 0.6],
            functionsByPath: ["F.swift": [.init(start: 1, end: 5, fraction: 0.8)]], source: "b")
        let m = a.merged(with: b)
        #expect(m.fraction(forPath: "F.swift") == 0.6)          // max line coverage
        #expect(m.functionFraction(path: "F.swift", line: 3) == 0.8)  // max span fraction
    }

    @Test func parsesTestOutcomeFromTranscript() {
        #expect(TestCoverageAttribution.outcome(
            fromTestOutput: "Test a passed after 0.1s\nTest b passed after 0.2s",
            exitCode: 0) == .passed)
        #expect(TestCoverageAttribution.outcome(
            fromTestOutput: "Test a passed after 0.1s\nTest b failed after 0.2s",
            exitCode: 1) == .partial)
        #expect(TestCoverageAttribution.outcome(
            fromTestOutput: "Test a failed after 0.1s",
            exitCode: 1) == .failed)
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
