import Foundation

// Test-coverage evidence for the graph views. Coverage is observed
// data from a real test run's artifacts — we only ever *read* what a
// build produced (SPM's llvm-cov JSON export), never run builds.

public struct CoverageReport: Sendable, Equatable {
    /// Repo-relative path → line coverage fraction (0...1).
    public let byPath: [String: Double]
    /// Artifact the report came from (repo-relative), for the UI.
    public let source: String

    public init(byPath: [String: Double], source: String) {
        self.byPath = byPath
        self.source = source
    }

    /// Coverage for a node path, falling back to nil when unknown.
    public func fraction(forPath path: String?) -> Double? {
        path.flatMap { byPath[$0] }
    }

    /// Union with another report: per file, the higher coverage. A
    /// lower bound on true cumulative coverage (line-level union would
    /// be exact), and monotonic — so accumulating across test classes
    /// only ever grows, which is what a live run wants to show.
    public func merged(with other: CoverageReport) -> CoverageReport {
        var byPath = byPath
        for (path, fraction) in other.byPath {
            byPath[path] = max(byPath[path] ?? 0, fraction)
        }
        return CoverageReport(byPath: byPath, source: other.source)
    }
}

public enum CoverageProvider {
    /// Locate and parse the newest SPM llvm-cov JSON export under the
    /// repo (`swift test --enable-code-coverage` writes
    /// `.build/<triple>/debug/codecov/*.json`). Returns nil when no
    /// artifact exists.
    public static func load(repoAt root: URL) -> CoverageReport? {
        guard let artifact = newestArtifact(under: root) else { return nil }
        guard let data = try? Data(contentsOf: artifact),
              let report = parse(llvmCovJSON: data, repoRoot: root)
        else { return nil }
        let relative = artifact.path.replacingOccurrences(
            of: root.standardizedFileURL.path + "/", with: "")
        return CoverageReport(byPath: report, source: relative)
    }

    /// llvm-cov export format: data[0].files[] with filename +
    /// summary.lines.percent. Filenames are absolute — relativize to
    /// the repo root; files outside it (SDK, checkouts) are dropped.
    static func parse(llvmCovJSON data: Data, repoRoot: URL) -> [String: Double]? {
        struct Export: Decodable {
            struct Entry: Decodable { let files: [File] }
            struct File: Decodable {
                let filename: String
                let summary: Summary
            }
            struct Summary: Decodable { let lines: Lines }
            struct Lines: Decodable { let percent: Double }
            let data: [Entry]
        }
        guard let export = try? JSONDecoder().decode(Export.self, from: data),
              let files = export.data.first?.files
        else { return nil }
        let rootPath = repoRoot.standardizedFileURL.path + "/"
        var byPath: [String: Double] = [:]
        for file in files {
            let standardized = URL(fileURLWithPath: file.filename).standardizedFileURL.path
            guard standardized.hasPrefix(rootPath) else { continue }
            let relative = String(standardized.dropFirst(rootPath.count))
            guard !relative.hasPrefix(".build/") else { continue }
            byPath[relative] = file.summary.lines.percent / 100
        }
        return byPath.isEmpty ? nil : byPath
    }

    /// Newest codecov JSON in any `.build` tree under the repo root
    /// (root package and nested packages like CygnusCore).
    static func newestArtifact(under root: URL) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        // Bounded probe: root and first-level subdirectories only —
        // .build lives at a package root, not deep in the tree.
        var packageDirs = [root]
        if let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) {
            packageDirs += entries.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
        }
        for package in packageDirs {
            let build = package.appendingPathComponent(".build")
            guard let enumerator = fm.enumerator(
                at: build, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            for case let url as URL in enumerator
            where url.pathExtension == "json"
                && url.deletingLastPathComponent().lastPathComponent == "codecov" {
                candidates.append(url)
            }
        }
        return candidates.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return da < db
        }
    }
}

// MARK: - Per-test attribution

/// Coverage attributed to one test class: what THAT test exercises.
public struct AttributedCoverage: Sendable, Equatable {
    public let testClass: String
    public let report: CoverageReport
    public init(testClass: String, report: CoverageReport) {
        self.testClass = testClass
        self.report = report
    }
}

public enum TestCoverageAttribution {
    /// Run exactly one test class with coverage and harvest the
    /// resulting artifact — the coverage it shows is what this test
    /// (alone) exercises. SPM repos only; the run happens in the
    /// repo's own package (nested packages: the one whose Tests/
    /// contains the class is found by the filter run itself).
    public static func run(repoAt root: URL, testClass: String,
                           tooling: any FactoryTooling,
                           timeout: Duration = .seconds(600)) async throws -> AttributedCoverage {
        _ = try await tooling.runChecked(.swift, [
            "test", "--enable-code-coverage", "--filter", testClass,
        ], workingDirectory: root, timeout: timeout)
        guard let report = CoverageProvider.load(repoAt: root) else {
            throw ToolingError.nonZeroExit(.swift, code: 0,
                stderr: "test run produced no coverage artifact")
        }
        return AttributedCoverage(testClass: testClass, report: report)
    }
}

// MARK: - Store wiring

extension WorkspaceStore {
    /// Load (or reload) coverage evidence for a repo. Cheap file read;
    /// nil result means "no artifact — run tests with coverage".
    public func loadCoverage(for id: UUID) async -> CoverageReport? {
        guard let root = repoURL(id) else { return nil }
        return try? await RepoAccess.withAccess(to: root) { root in
            CoverageProvider.load(repoAt: root)
        }
    }

    /// Attribute coverage to one test class by running it in
    /// isolation. Runs the repo's own test suite — user-initiated
    /// only, never automatic.
    public func attributeCoverage(testClass: String, for id: UUID,
                                  tooling: any FactoryTooling = ProcessTooling()) async throws -> AttributedCoverage {
        guard let root = repoURL(id) else {
            throw ToolingError.toolNotFound(.swift)
        }
        return try await RepoAccess.withAccess(to: root) { root in
            try await TestCoverageAttribution.run(
                repoAt: root, testClass: testClass, tooling: tooling)
        }
    }
}
