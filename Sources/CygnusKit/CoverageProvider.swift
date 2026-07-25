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
}
