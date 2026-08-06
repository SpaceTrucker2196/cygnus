import Testing
import Foundation
import CygnusGraph
import CygnusStore
import CygnusProviders
@testable import CygnusRetrieval

// The incrementality claims, asserted rather than asserted-about:
// unchanged content costs nothing, renames cost nothing, reverts cost
// nothing. Plus the two blobs that would otherwise take the indexer
// down on a real repository.

@Suite struct RetrievalIndexerTests {
    private func makeFixture() throws -> (SQLiteGraphStore, ContentStore, RetrievalIndexer, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-retrieval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SQLiteGraphStore.inMemory()
        let cas = try ContentStore(root: root.appendingPathComponent("cas"))
        return (store, cas, RetrievalIndexer(store: store, contentStore: cas), root)
    }

    @Test func indexingIsIdempotent() throws {
        let (store, cas, indexer, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let blob = try cas.store(Data("func send() {}\n".utf8))

        let first = try indexer.index(blobs: [blob])
        #expect(first.indexed == 1)

        let second = try indexer.index(blobs: [blob])
        #expect(second.indexed == 0)
        #expect(try RetrievalIndexStore(store: store).indexedBlobCount() == 1)
    }

    /// A rename changes the path, never the content — so it must cost
    /// exactly nothing. Windows are keyed by blob alone; the path
    /// arrives from the snapshot join at query time.
    @Test func renameCostsNothing() throws {
        let (_, cas, indexer, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let blob = try cas.store(Data("struct Client {}\n".utf8))

        #expect(try indexer.index(blobs: [blob]).indexed == 1)
        // Same blob, imagined at a new path: still nothing to do.
        #expect(try indexer.index(blobs: [blob]).indexed == 0)
    }

    /// Reverting a file re-presents a blob already indexed, so a revert
    /// is free too.
    @Test func revertToAPreviouslySeenBlobCostsNothing() throws {
        let (_, cas, indexer, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try cas.store(Data("let version = 1\n".utf8))
        let edited = try cas.store(Data("let version = 2\n".utf8))

        #expect(try indexer.index(blobs: [original]).indexed == 1)
        #expect(try indexer.index(blobs: [edited]).indexed == 1)
        #expect(try indexer.index(blobs: [original, edited]).indexed == 0)
    }

    /// `LocalFSProvider` records files over its ingest cap with the
    /// hash of empty content and never stores the bytes. Reading it
    /// throws, so an indexer that discovers this by trying dies on the
    /// first repository containing a >4 MB file.
    @Test func theNotIngestedSentinelIsSkippedNotRead() throws {
        let (_, cas, indexer, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(RetrievalIndexer.notIngested == ContentStore.hash(Data()))
        #expect(!cas.contains(RetrievalIndexer.notIngested))

        let report = try indexer.index(blobs: [RetrievalIndexer.notIngested])
        #expect(report.skippedNotIngested == 1)
        #expect(report.indexed == 0)
        #expect(report.failed == 0)
    }

    /// Text-ness is decodability, not a language hint — the hint is nil
    /// for plenty of real text, and a PNG must not reach the index.
    @Test func undecodableBlobsAreSkipped() throws {
        let (_, cas, indexer, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try cas.store(Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0xFE, 0xFD]))

        let report = try indexer.index(blobs: [png])
        #expect(report.skippedBinary == 1)
        #expect(report.indexed == 0)
    }

    /// A blob missing from the CAS is counted, never fatal: one broken
    /// file must not abort indexing the rest of the repository.
    @Test func aMissingBlobIsReportedNotThrown() throws {
        let (_, _, indexer, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try indexer.index(blobs: [BlobHash(String(repeating: "a", count: 64))])
        #expect(report.failed == 1)
    }

    /// An empty file has no windows but still earns a ledger row, or it
    /// is rescanned on every run forever.
    @Test func emptyFilesAreRecordedAsIndexed() throws {
        let (store, cas, indexer, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // Not the sentinel: a real, stored, empty file.
        let blob = try cas.store(Data("\n".utf8))

        #expect(try indexer.index(blobs: [blob]).indexed == 1)
        #expect(try indexer.index(blobs: [blob]).indexed == 0)
        #expect(try RetrievalIndexStore(store: store).indexedBlobCount() == 1)
    }
}
