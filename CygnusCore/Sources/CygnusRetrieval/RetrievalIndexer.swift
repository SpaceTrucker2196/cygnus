import Foundation
import CygnusGraph
import CygnusStore
import CygnusProviders

// Brings the lexical index up to date with a snapshot.
//
// The entire diff is a set difference on blob hashes: manifest blobs
// minus already-indexed blobs. Not `ManifestDiff.changedOrAdded` —
// the blob-set difference is both simpler and stricter, because it
// also picks up blobs a previous run failed on or was interrupted
// before finishing.

public struct RetrievalIndexer: Sendable {
    private let index: RetrievalIndexStore
    private let contentStore: ContentStore

    public init(store: SQLiteGraphStore, contentStore: ContentStore) {
        self.index = RetrievalIndexStore(store: store)
        self.contentStore = contentStore
    }

    /// The hash of empty content, which `LocalFSProvider` writes into
    /// the manifest for any file over its ingest cap **without storing
    /// the bytes**. It is a marker meaning "this file exists and was
    /// not read", so it is present in manifests and absent from the
    /// CAS: reading it throws. Skip it by identity rather than
    /// discovering it by crashing on the first repo with a big file.
    public static let notIngested = BlobHash(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

    public struct Report: Sendable, Equatable {
        public var indexed = 0
        public var skippedNotIngested = 0
        public var skippedBinary = 0
        public var failed = 0
    }

    /// Index every blob in `blobs` that isn't already indexed.
    @discardableResult
    public func index(blobs: [BlobHash]) throws -> Report {
        let already = try index.indexedBlobs()
        var report = Report()

        for blob in Set(blobs).subtracting(already).sorted(by: { $0.raw < $1.raw }) {
            if blob == Self.notIngested {
                report.skippedNotIngested += 1
                continue
            }
            guard let data = try? contentStore.read(blob) else {
                report.failed += 1
                continue
            }
            // Text-ness is decodability, not the language hint: the
            // hint is nil for plenty of real text (.toml, .sh, an
            // extensionless Makefile), and decoding catches a PNG
            // without anyone maintaining an allow-list.
            guard let text = String(data: data, encoding: .utf8) else {
                report.skippedBinary += 1
                continue
            }
            // An empty file yields no windows but still gets a ledger
            // row, so it is not rescanned on every run forever.
            let windows = SourceWindows.split(text)
            try index.insertWindows(windows, blob: blob,
                                    lines: SourceWindows.lineCount(text))
            report.indexed += 1
        }
        return report
    }
}
