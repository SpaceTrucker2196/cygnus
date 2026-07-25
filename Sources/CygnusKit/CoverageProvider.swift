import Foundation

// Test-coverage evidence for the graph views. Coverage is observed
// data from a real test run's artifacts — we only ever *read* what a
// build produced (SPM's llvm-cov JSON export), never run builds.

public struct CoverageReport: Sendable, Equatable {
    /// One function's region coverage, with the source span it covers.
    public struct FunctionCoverage: Sendable, Equatable {
        public let start: Int
        public let end: Int
        public let fraction: Double     // covered regions / total (0...1)
        public init(start: Int, end: Int, fraction: Double) {
            self.start = start; self.end = end; self.fraction = fraction
        }
    }

    /// Repo-relative path → line coverage fraction (0...1).
    public let byPath: [String: Double]
    /// Repo-relative path → its functions' region coverage. Powers the
    /// per-function ring on class nodes.
    public let functionsByPath: [String: [FunctionCoverage]]
    /// Artifact the report came from (repo-relative), for the UI.
    public let source: String

    public init(byPath: [String: Double],
                functionsByPath: [String: [FunctionCoverage]] = [:],
                source: String) {
        self.byPath = byPath
        self.functionsByPath = functionsByPath
        self.source = source
    }

    /// Coverage for a node path, falling back to nil when unknown.
    public func fraction(forPath path: String?) -> Double? {
        path.flatMap { byPath[$0] }
    }

    /// Coverage of the function enclosing a declaration at (path,
    /// line) — the smallest covered span containing the line. Nil when
    /// no function there is instrumented.
    public func functionFraction(path: String?, line: Int?) -> Double? {
        guard let path, let line, let functions = functionsByPath[path] else { return nil }
        return functions
            .filter { $0.start <= line && line <= $0.end }
            .min { ($0.end - $0.start) < ($1.end - $1.start) }?
            .fraction
    }

    /// Union with another report: per file, the higher line coverage
    /// and the union of function spans (max fraction per span). A
    /// monotonic lower bound — accumulating across test classes only
    /// grows, which is what a live run wants to show.
    public func merged(with other: CoverageReport) -> CoverageReport {
        var byPath = byPath
        for (path, fraction) in other.byPath {
            byPath[path] = max(byPath[path] ?? 0, fraction)
        }
        var functionsByPath = functionsByPath
        for (path, funcs) in other.functionsByPath {
            var merged = Dictionary(
                (functionsByPath[path] ?? []).map { ("\($0.start)-\($0.end)", $0) },
                uniquingKeysWith: { a, _ in a })
            for f in funcs {
                let key = "\(f.start)-\(f.end)"
                merged[key] = FunctionCoverage(
                    start: f.start, end: f.end,
                    fraction: max(merged[key]?.fraction ?? 0, f.fraction))
            }
            functionsByPath[path] = Array(merged.values)
        }
        return CoverageReport(byPath: byPath, functionsByPath: functionsByPath,
                              source: other.source)
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
        return CoverageReport(byPath: report.lines, functionsByPath: report.functions,
                              source: relative)
    }

    /// llvm-cov export: `data[0].files[]` gives per-file line percent;
    /// `data[0].functions[]` gives per-function regions (a region is
    /// `[startLine, startCol, endLine, endCol, execCount, …]`, covered
    /// when execCount > 0). Filenames are absolute — relativized to
    /// the repo; SDK/checkout files dropped.
    static func parse(llvmCovJSON data: Data,
                      repoRoot: URL) -> (lines: [String: Double],
                                         functions: [String: [CoverageReport.FunctionCoverage]])? {
        struct Export: Decodable {
            struct Entry: Decodable { let files: [File]; let functions: [Function] }
            struct File: Decodable { let filename: String; let summary: Summary }
            struct Summary: Decodable { let lines: Lines }
            struct Lines: Decodable { let percent: Double }
            struct Function: Decodable {
                let filenames: [String]
                let regions: [[Int]]
            }
            let data: [Entry]
        }
        guard let export = try? JSONDecoder().decode(Export.self, from: data),
              let entry = export.data.first
        else { return nil }
        let rootPath = repoRoot.standardizedFileURL.path + "/"
        func relativize(_ absolute: String) -> String? {
            let standardized = URL(fileURLWithPath: absolute).standardizedFileURL.path
            guard standardized.hasPrefix(rootPath) else { return nil }
            let relative = String(standardized.dropFirst(rootPath.count))
            return relative.hasPrefix(".build/") ? nil : relative
        }

        var lines: [String: Double] = [:]
        for file in entry.files {
            guard let relative = relativize(file.filename) else { continue }
            lines[relative] = file.summary.lines.percent / 100
        }

        var functions: [String: [CoverageReport.FunctionCoverage]] = [:]
        for function in entry.functions {
            guard let first = function.filenames.first,
                  let relative = relativize(first),
                  !function.regions.isEmpty else { continue }
            var start = Int.max, end = 0, covered = 0
            for region in function.regions where region.count >= 5 {
                start = min(start, region[0]); end = max(end, region[2])
                if region[4] > 0 { covered += 1 }
            }
            guard start != .max else { continue }
            functions[relative, default: []].append(CoverageReport.FunctionCoverage(
                start: start, end: end,
                fraction: Double(covered) / Double(function.regions.count)))
        }
        return lines.isEmpty ? nil : (lines, functions)
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

/// The pass/fail verdict of a test class's run — the link phosphor.
public enum TestOutcome: String, Sendable, Equatable {
    case passed, failed, partial
}

/// Coverage attributed to one test class: what THAT test exercises,
/// and whether it passed.
public struct AttributedCoverage: Sendable, Equatable {
    public let testClass: String
    public let report: CoverageReport
    public let outcome: TestOutcome
    public init(testClass: String, report: CoverageReport, outcome: TestOutcome) {
        self.testClass = testClass
        self.report = report
        self.outcome = outcome
    }
}

public enum TestCoverageAttribution {
    /// Run exactly one test class with coverage and harvest the
    /// artifact — the coverage it shows is what this test alone
    /// exercises. Uses `run` (not `runChecked`) so a failing test
    /// still yields its coverage and a `.failed`/`.partial` outcome
    /// rather than throwing. SPM repos only.
    public static func run(repoAt root: URL, testClass: String,
                           tooling: any FactoryTooling,
                           timeout: Duration = .seconds(600)) async throws -> AttributedCoverage {
        let result = try await tooling.run(.swift, [
            "test", "--enable-code-coverage", "--filter", testClass,
        ], workingDirectory: root, timeout: timeout)
        guard let report = CoverageProvider.load(repoAt: root) else {
            throw ToolingError.nonZeroExit(.swift, code: result.exitCode,
                stderr: "test run produced no coverage artifact")
        }
        return AttributedCoverage(testClass: testClass, report: report,
                                  outcome: outcome(fromTestOutput: result.stdoutString + result.stderr,
                                                   exitCode: result.exitCode))
    }

    /// Read pass/fail from a `swift test` transcript. Per-test lines
    /// carry "passed after" / "failed after"; mixed → partial. Falls
    /// back to the exit code when the transcript is unhelpful.
    static func outcome(fromTestOutput output: String, exitCode: Int32) -> TestOutcome {
        let passed = output.components(separatedBy: "passed after").count - 1
        let failed = output.components(separatedBy: "failed after").count - 1
        if failed == 0 { return exitCode == 0 ? .passed : (passed > 0 ? .partial : .failed) }
        return passed > 0 ? .partial : .failed
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
