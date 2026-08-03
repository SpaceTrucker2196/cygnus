import Foundation
import CygnusGraph

// Remembering what enrichment has already read, so it is not read
// again for nothing.
//
// Reference enrichment runs even when no source file changed, because
// an index store can appear between analyses — build the project and
// symbols should show up without editing anything. The cost of that
// rule went unnoticed while only SwiftPM stores were found: they are
// small. An Xcode DerivedData store is not. Measured 2026-08-03,
// nighthawk-iOS spent 30 s of a 30.3 s analysis inside the index
// store, for 113 files — and paid it again on every re-analysis.
//
// The rule was right, the trigger was wrong. What matters is not
// whether the *source* changed but whether the *store* did.

struct EnrichmentState: Codable, Sendable {
    /// Fingerprint of the index store the last enrichment read.
    var storeFingerprint: String
    /// Snapshot it enriched against — a source change still re-runs,
    /// since the file set it filters against has moved.
    var snapshotID: Int64
}

enum EnrichmentLedger {
    /// One small JSON file beside the graph. Deliberately not a store
    /// table: this is a cache key, not a fact about the software, and
    /// facts are the only thing that belongs in the graph.
    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent("enrichment-state.json")
    }

    static func load(in directory: URL) -> [String: EnrichmentState] {
        guard let data = try? Data(contentsOf: url(in: directory)),
              let decoded = try? JSONDecoder().decode([String: EnrichmentState].self,
                                                      from: data)
        else { return [:] }
        return decoded
    }

    static func save(_ state: [String: EnrichmentState], in directory: URL) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url(in: directory), options: .atomic)
    }

    /// Cheap identity for a store's contents: newest modification time
    /// and entry count of the unit and record directories, which is
    /// what a rebuild changes. Hashing every unit would cost as much
    /// as the enrichment it is meant to avoid.
    static func fingerprint(ofStoreAt path: String) -> String {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: path)
        var parts: [String] = []
        for name in ["units", "records", "v5"] {
            let directory = root.appendingPathComponent(name)
            guard let values = try? directory.resourceValues(
                forKeys: [.contentModificationDateKey]) else { continue }
            let stamp = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            let count = (try? fm.contentsOfDirectory(atPath: directory.path).count) ?? 0
            parts.append("\(name):\(Int(stamp)):\(count)")
        }
        if parts.isEmpty {
            let stamp = (try? root.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
            parts.append("root:\(Int(stamp))")
        }
        return parts.joined(separator: "|")
    }
}
