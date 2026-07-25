import Testing
import Foundation
@testable import CygnusExtractorIndex

// Smoke over a real index store. Gated: needs an actual
// -index-store-path artifact, e.g. cygnus's own —
//   CYGNUS_ISDB_STORE=CygnusCore/.build/arm64-apple-macosx/debug/index/store \
//   CYGNUS_ISDB_SYMBOL=ImportRollupDeriver swift test --filter IndexStoreReader

struct IndexStoreReaderTests {
    @Test func toolchainShipsLibIndexStore() {
        // The dylib resolution itself must work on any dev machine.
        #expect(IndexStoreReader.libIndexStorePath() != nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CYGNUS_ISDB_STORE"] != nil))
    func opensStoreAndResolvesReferences() async throws {
        let env = ProcessInfo.processInfo.environment
        let store = env["CYGNUS_ISDB_STORE"]!
        let symbol = env["CYGNUS_ISDB_SYMBOL"] ?? "ImportRollupDeriver"
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-isdb-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let reader = try IndexStoreReader(storePath: store, databasePath: scratch)
        let occurrences = await reader.occurrences(ofName: symbol)
        #expect(!occurrences.isEmpty, "no occurrences of \(symbol)")
        #expect(occurrences.contains { $0.isDefinition })
        #expect(occurrences.contains { $0.isReference || $0.isCall },
                "definition found but no references — enrichment would be empty")
        let refs = occurrences.filter { $0.isReference }.count
        let calls = occurrences.filter { $0.isCall }.count
        print("ISDB: \(symbol): \(occurrences.count) occurrences, \(refs) refs, \(calls) calls")
    }
}
