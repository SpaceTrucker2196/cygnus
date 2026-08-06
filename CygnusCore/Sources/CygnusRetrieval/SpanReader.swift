import Foundation
import CygnusGraph
import CygnusStore
import CygnusProviders

// Reads a line range from the snapshot, not from disk.
//
// This is the whole reason it exists beside an agent's own file-read
// tool. Every line number cygnus produces refers to a blob in the CAS;
// reading the working tree instead would hand back text that may no
// longer correspond to those numbers, silently, with no way for the
// agent to notice. Here the blob is the source of truth and drift is
// reported rather than papered over.

public struct SpanReader: Sendable {
    private let store: SQLiteGraphStore
    private let contentStore: ContentStore

    public init(store: SQLiteGraphStore, contentStore: ContentStore) {
        self.store = store
        self.contentStore = contentStore
    }

    /// A read tool must not be a way to spend a whole context window.
    public static let maxLines = 400

    public struct Span: Sendable {
        public let path: String
        public let repositoryName: String
        public let startLine: Int
        public let endLine: Int
        public let text: String
        public let blob: BlobHash
        /// The file on disk no longer hashes to the blob these line
        /// numbers refer to. The text returned is the snapshot's.
        public let stale: Bool
        /// Set when the request was clamped to `maxLines`.
        public let truncatedTo: Int?
    }

    public enum SpanError: Error, Equatable {
        case unknownRepository(String)
        case pathNotInSnapshot(String)
        case notIngested(String)
        case notText(String)
        case emptyRange
    }

    public func read(path: String, startLine: Int, endLine: Int,
                     repository: RepositoryID? = nil,
                     workingTreeRoot: URL? = nil) throws -> Span {
        guard endLine >= startLine, startLine >= 1 else { throw SpanError.emptyRange }

        let repositories = try store.repositories()
        let resolved: SQLiteGraphStore.RegisteredRepository
        if let repository {
            guard let match = repositories.first(where: { $0.id == repository }) else {
                throw SpanError.unknownRepository(repository.raw)
            }
            resolved = match
        } else {
            // No repository given: the path must be unambiguous across
            // the workspace, or the answer would be a coin flip.
            let candidates = try repositories.filter {
                try store.currentBlob(forPath: path, repository: $0.id) != nil
            }
            guard let only = candidates.first, candidates.count == 1 else {
                throw SpanError.pathNotInSnapshot(path)
            }
            resolved = only
        }

        guard let blob = try store.currentBlob(forPath: path, repository: resolved.id) else {
            throw SpanError.pathNotInSnapshot(path)
        }
        guard blob != RetrievalIndexer.notIngested else {
            throw SpanError.notIngested(path)
        }
        guard let text = String(data: try contentStore.read(blob), encoding: .utf8) else {
            throw SpanError.notText(path)
        }

        let lines = SourceWindows.splitLines(text)
        let from = min(startLine, max(lines.count, 1))
        let requestedTo = min(endLine, lines.count)
        // Clamp rather than refuse: a too-large request still gets its
        // beginning, plus an honest note that it was cut.
        let cappedTo = min(requestedTo, from + Self.maxLines - 1)
        guard from <= cappedTo else { throw SpanError.emptyRange }

        let slice = lines[(from - 1)..<cappedTo]
        return Span(
            path: path,
            repositoryName: resolved.displayName,
            startLine: from,
            endLine: cappedTo,
            text: slice.joined(separator: "\n"),
            blob: blob,
            stale: isStale(path: path, blob: blob,
                           root: workingTreeRoot ?? resolved.rootPath.map(URL.init(fileURLWithPath:))),
            truncatedTo: cappedTo < requestedTo ? cappedTo : nil)
    }

    /// Cheap drift check: hash the file on disk and compare. Absent or
    /// unreadable counts as drifted — the snapshot is still returned,
    /// the caller is still told.
    private func isStale(path: String, blob: BlobHash, root: URL?) -> Bool {
        guard let root else { return false }
        let url = root.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else { return true }
        return ContentStore.hash(data) != blob
    }
}
