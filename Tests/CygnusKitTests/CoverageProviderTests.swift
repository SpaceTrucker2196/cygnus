import Testing
import Foundation
@testable import CygnusKit

struct CoverageProviderTests {
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
