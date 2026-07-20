import Foundation
import CygnusGraph

// A snapshot manifest maps repository-relative paths to blob hashes.
// Manifest-vs-manifest diff is the authoritative change signal:
// FSEvents and git are only hints about where to look, so missed
// events can never corrupt the graph.

public struct SnapshotManifest: Hashable, Codable, Sendable {
    public let files: [SnapshotFile]          // sorted by path
    private let byPath: [String: SnapshotFile]

    public init(files: [SnapshotFile]) {
        let sorted = files.sorted { $0.path < $1.path }
        self.files = sorted
        self.byPath = Dictionary(uniqueKeysWithValues: sorted.map { ($0.path, $0) })
    }

    public func file(at path: String) -> SnapshotFile? { byPath[path] }

    private enum CodingKeys: String, CodingKey { case files }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(files: try container.decode([SnapshotFile].self, forKey: .files))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(files, forKey: .files)
    }
}

public struct ManifestDiff: Hashable, Sendable {
    public let added: [SnapshotFile]
    public let removed: [SnapshotFile]
    public let modified: [SnapshotFile]       // new state; blob changed

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && modified.isEmpty }

    /// Paths whose facts must be regenerated (added + modified) and
    /// retracted (removed + modified).
    public var changedOrAdded: [SnapshotFile] { added + modified }
    public var retractedPaths: [String] { (removed + modified).map(\.path) }

    public static func between(_ old: SnapshotManifest?, _ new: SnapshotManifest) -> ManifestDiff {
        guard let old else {
            return ManifestDiff(added: new.files, removed: [], modified: [])
        }
        var added: [SnapshotFile] = []
        var modified: [SnapshotFile] = []
        for file in new.files {
            switch old.file(at: file.path) {
            case nil: added.append(file)
            case let prior? where prior.blob != file.blob: modified.append(file)
            default: break
            }
        }
        let removed = old.files.filter { new.file(at: $0.path) == nil }
        return ManifestDiff(added: added, removed: removed, modified: modified)
    }

    public init(added: [SnapshotFile], removed: [SnapshotFile], modified: [SnapshotFile]) {
        self.added = added
        self.removed = removed
        self.modified = modified
    }
}
