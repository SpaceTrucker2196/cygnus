import Testing
import Foundation
@testable import CygnusEngine

// The cache key that stops a large index store being re-read for
// nothing. Its whole job is to change when the store is rebuilt and
// not otherwise, so that is what these test.

@Suite struct EnrichmentStateTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-enrich-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A store directory shaped like the real thing.
    private func makeStore(units: Int) throws -> URL {
        let store = try scratch()
        let unitsDir = store.appendingPathComponent("units")
        try FileManager.default.createDirectory(at: unitsDir, withIntermediateDirectories: true)
        for i in 0..<units {
            try "unit\(i)".write(to: unitsDir.appendingPathComponent("u\(i)"),
                                 atomically: true, encoding: .utf8)
        }
        return store
    }

    @Test func theSameStoreFingerprintsTheSame() throws {
        let store = try makeStore(units: 3)
        defer { try? FileManager.default.removeItem(at: store) }
        let first = EnrichmentLedger.fingerprint(ofStoreAt: store.path)
        #expect(first == EnrichmentLedger.fingerprint(ofStoreAt: store.path))
        #expect(!first.isEmpty)
    }

    /// A rebuild adds units. If this did not change, building the
    /// project would stop producing new symbols — the exact promise
    /// the skip must not break.
    @Test func aRebuiltStoreFingerprintsDifferently() throws {
        let store = try makeStore(units: 3)
        defer { try? FileManager.default.removeItem(at: store) }
        let before = EnrichmentLedger.fingerprint(ofStoreAt: store.path)
        try "new".write(to: store.appendingPathComponent("units/u99"),
                        atomically: true, encoding: .utf8)
        #expect(EnrichmentLedger.fingerprint(ofStoreAt: store.path) != before)
    }

    /// A path with none of the expected subdirectories still yields
    /// something rather than an empty key that would collide with
    /// every other store.
    @Test func anUnfamiliarLayoutStillFingerprints() throws {
        let bare = try scratch()
        defer { try? FileManager.default.removeItem(at: bare) }
        #expect(!EnrichmentLedger.fingerprint(ofStoreAt: bare.path).isEmpty)
    }

    @Test func theLedgerRoundTrips() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(EnrichmentLedger.load(in: directory).isEmpty)

        let state = EnrichmentState(storeFingerprint: "abc", snapshotID: 7)
        EnrichmentLedger.save(["repo-1": state], in: directory)
        let loaded = EnrichmentLedger.load(in: directory)
        #expect(loaded["repo-1"]?.storeFingerprint == "abc")
        #expect(loaded["repo-1"]?.snapshotID == 7)
    }

    /// A corrupt or hand-edited file must degrade to "nothing cached"
    /// rather than throwing — the worst case is re-reading a store,
    /// which is slow, not wrong.
    @Test func unreadableLedgerIsTreatedAsEmpty() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "not json".write(to: EnrichmentLedger.url(in: directory),
                             atomically: true, encoding: .utf8)
        #expect(EnrichmentLedger.load(in: directory).isEmpty)
    }
}
