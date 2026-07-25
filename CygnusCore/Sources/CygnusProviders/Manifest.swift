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
    /// A removed→added pairing that is evidently the same file moved.
    /// `exact` renames are blob-identical; fuzzy ones share the
    /// filename but were edited in the same change. Detection is
    /// one-to-one and unambiguous only — when several candidates
    /// could pair, no claim is made (facts, not guesses).
    public struct Rename: Hashable, Sendable {
        public let from: SnapshotFile
        public let to: SnapshotFile
        public let exact: Bool
        public init(from: SnapshotFile, to: SnapshotFile, exact: Bool) {
            self.from = from
            self.to = to
            self.exact = exact
        }
    }

    public let added: [SnapshotFile]
    public let removed: [SnapshotFile]
    public let modified: [SnapshotFile]       // new state; blob changed
    /// Detected renames. Supplementary signal: renamed files still
    /// appear in added/removed, and their facts fully regenerate —
    /// the rename only threads identity across the move.
    public let renames: [Rename]

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && modified.isEmpty }

    /// Paths whose facts must be regenerated (added + modified) and
    /// retracted (removed + modified).
    public var changedOrAdded: [SnapshotFile] { added + modified }
    public var retractedPaths: [String] { (removed + modified).map(\.path) }

    /// New path → old path for every detected rename.
    public var renamedFrom: [String: String] {
        Dictionary(uniqueKeysWithValues: renames.map { ($0.to.path, $0.from.path) })
    }

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
        return ManifestDiff(added: added, removed: removed, modified: modified,
                            renames: detectRenames(removed: removed, added: added))
    }

    /// Pass 1 — exact: unique blob on both sides pairs removed→added.
    /// Pass 2 — fuzzy: among leftovers, a unique shared filename
    /// pairs a moved-and-edited file.
    static func detectRenames(removed: [SnapshotFile],
                              added: [SnapshotFile]) -> [Rename] {
        var renames: [Rename] = []
        var unpairedRemoved = removed
        var unpairedAdded = added

        func uniquely<Key: Hashable>(_ files: [SnapshotFile],
                                     by key: (SnapshotFile) -> Key) -> [Key: SnapshotFile] {
            var counts: [Key: Int] = [:]
            for file in files { counts[key(file), default: 0] += 1 }
            return Dictionary(uniqueKeysWithValues: files.compactMap { file in
                counts[key(file)] == 1 ? (key(file), file) : nil
            })
        }

        // Exact: blob-identical, unique on both sides. Empty blobs
        // (unfetched large files) never pair — identical emptiness is
        // not identity.
        let removedByBlob = uniquely(unpairedRemoved.filter { $0.size > 0 }, by: \.blob)
        let addedByBlob = uniquely(unpairedAdded.filter { $0.size > 0 }, by: \.blob)
        for (blob, from) in removedByBlob.sorted(by: { $0.value.path < $1.value.path }) {
            guard let to = addedByBlob[blob] else { continue }
            renames.append(Rename(from: from, to: to, exact: true))
            unpairedRemoved.removeAll { $0.path == from.path }
            unpairedAdded.removeAll { $0.path == to.path }
        }

        // Fuzzy: same filename, unique on both sides.
        func name(_ file: SnapshotFile) -> String {
            file.path.split(separator: "/").last.map(String.init) ?? file.path
        }
        let removedByName = uniquely(unpairedRemoved, by: name)
        let addedByName = uniquely(unpairedAdded, by: name)
        for (filename, from) in removedByName.sorted(by: { $0.value.path < $1.value.path }) {
            guard let to = addedByName[filename], to.path != from.path else { continue }
            renames.append(Rename(from: from, to: to, exact: false))
        }
        return renames.sorted { $0.to.path < $1.to.path }
    }

    public init(added: [SnapshotFile], removed: [SnapshotFile], modified: [SnapshotFile],
                renames: [Rename] = []) {
        self.added = added
        self.removed = removed
        self.modified = modified
        self.renames = renames
    }
}
