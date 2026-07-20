import Foundation
import CryptoKit
import CygnusGraph

// Content-addressed blob store. Snapshot file contents live here,
// keyed by SHA-256, beside the workspace database (never as SQLite
// blobs). Analysis reads only from the CAS, never the live tree —
// that is what makes snapshots immutable — and identical blobs are
// stored once across all revisions and repositories.

public struct ContentStore: Sendable {
    public let root: URL

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public static func hash(_ data: Data) -> BlobHash {
        BlobHash(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    public func url(for blob: BlobHash) -> URL {
        root.appendingPathComponent(String(blob.raw.prefix(2)))
            .appendingPathComponent(String(blob.raw.dropFirst(2)))
    }

    public func contains(_ blob: BlobHash) -> Bool {
        FileManager.default.fileExists(atPath: url(for: blob).path)
    }

    /// Store data, returning its hash. Idempotent; existing blobs are
    /// not rewritten.
    @discardableResult
    public func store(_ data: Data) throws -> BlobHash {
        let blob = Self.hash(data)
        let destination = url(for: blob)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        }
        return blob
    }

    public func read(_ blob: BlobHash) throws -> Data {
        try Data(contentsOf: url(for: blob))
    }
}
