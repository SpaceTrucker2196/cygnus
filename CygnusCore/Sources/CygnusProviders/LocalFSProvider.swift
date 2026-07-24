import Foundation
import CygnusGraph

// Walks a repository working tree, hashes file contents into the CAS,
// and produces an immutable snapshot manifest. Facts only: the walk
// decides what is *observable*, never what is architectural.
//
// Ignore handling is deliberately simple for now: hidden entries and
// a default exclude set (build products, VCS internals, vendored
// deps). Full .gitignore semantics arrive with the git provider's
// `ls-files` fast path.

public struct LocalFSProvider: Sendable {
    public let root: URL
    public let contentStore: ContentStore

    /// Directory names never descended into. `build` and
    /// `SourcePackages` matter at machine-survival scale: an Xcode
    /// DerivedData-style `build/…/SourcePackages/checkouts` tree
    /// carries entire vendored dependencies (SQLite amalgamation
    /// sources included) and once drove extraction to 43 GB.
    public static let excludedDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", "DerivedData", "node_modules",
        ".venv", "venv", "__pycache__", ".mypy_cache", ".pytest_cache",
        "Pods", "Carthage", "dist", "target", "build", "SourcePackages",
    ]

    /// File names never captured.
    public static let excludedFiles: Set<String> = [".DS_Store"]

    /// Files larger than this are recorded in the manifest but their
    /// contents are not ingested (no extractor reads megabyte blobs).
    public static let maxIngestedSize: Int64 = 4 * 1024 * 1024

    public init(root: URL, contentStore: ContentStore) {
        self.root = root
        self.contentStore = contentStore
    }

    /// Walk the tree, ingest contents, return the manifest.
    ///
    /// `budget` is checked once per captured file; throwing from it
    /// aborts the walk. The caller owns the policy (the engine passes
    /// its hard memory limit) — a 5 GB working tree is ingested here,
    /// and a walk that can't be stopped is a walk that can OOM the
    /// machine before extraction even starts.
    public func snapshot(budget: (@Sendable () throws -> Void)? = nil) throws -> SnapshotManifest {
        let fm = FileManager.default
        var files: [SnapshotFile] = []

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
        else { return SnapshotManifest(files: []) }

        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])

            if values.isDirectory == true {
                if Self.excludedDirectories.contains(url.lastPathComponent)
                    || ["xcodeproj", "xcworkspace"].contains(url.pathExtension) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  !Self.excludedFiles.contains(url.lastPathComponent)
            else { continue }

            let size = Int64(values.fileSize ?? 0)
            let path = relativePath(of: url)
            if size > Self.maxIngestedSize {
                // Present in the manifest (existence is a fact), contents skipped.
                let data = Data()      // hash of empty marks "not ingested"
                files.append(SnapshotFile(path: path, blob: ContentStore.hash(data),
                                          size: size, languageHint: nil))
                continue
            }
            try budget?()
            // Autorelease per file: Data(contentsOf:) on a large tree
            // otherwise accumulates transient buffers for the whole
            // walk before anything is released.
            let blob = try autoreleasepool {
                try contentStore.store(Data(contentsOf: url))
            }
            files.append(SnapshotFile(path: path, blob: blob, size: size,
                                      languageHint: Self.languageHint(forPath: path)))
        }
        return SnapshotManifest(files: files)
    }

    private func relativePath(of url: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return path }
        return String(path.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
    }

    public static func languageHint(forPath path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": "swift"
        case "py": "python"
        case "c", "h": "c"
        case "md", "markdown": "markdown"
        case "json": "json"
        case "yml", "yaml": "yaml"
        default: nil
        }
    }
}
