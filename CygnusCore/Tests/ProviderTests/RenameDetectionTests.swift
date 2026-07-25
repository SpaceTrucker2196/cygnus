import Testing
import Foundation
import CygnusGraph
@testable import CygnusProviders

// Rename detection over manifest diffs: exact (blob-identical) and
// fuzzy (same filename, edited in the move). One-to-one and
// unambiguous only — ambiguity makes no claim.

@Suite struct RenameDetectionTests {
    private func file(_ path: String, blob: String, size: Int64 = 10) -> SnapshotFile {
        SnapshotFile(path: path, blob: BlobHash(blob), size: size, languageHint: nil)
    }

    @Test func exactRenameByIdenticalBlob() {
        let old = SnapshotManifest(files: [file("Sources/Old.swift", blob: "aaa")])
        let new = SnapshotManifest(files: [file("Sources/Nested/New.swift", blob: "aaa")])
        let diff = ManifestDiff.between(old, new)
        #expect(diff.renames.count == 1)
        #expect(diff.renames[0].exact)
        #expect(diff.renamedFrom["Sources/Nested/New.swift"] == "Sources/Old.swift")
        // Renamed files still regenerate facts.
        #expect(diff.added.map(\.path) == ["Sources/Nested/New.swift"])
        #expect(diff.removed.map(\.path) == ["Sources/Old.swift"])
    }

    @Test func fuzzyRenameBySharedFilename() {
        let old = SnapshotManifest(files: [file("A/Tool.swift", blob: "v1")])
        let new = SnapshotManifest(files: [file("B/Tool.swift", blob: "v2")])
        let diff = ManifestDiff.between(old, new)
        #expect(diff.renames.count == 1)
        #expect(!diff.renames[0].exact)
        #expect(diff.renamedFrom["B/Tool.swift"] == "A/Tool.swift")
    }

    @Test func ambiguityMakesNoClaim() {
        // Two removed files with the same blob → no exact pairing;
        // two added files named Tool.swift → no fuzzy pairing.
        let old = SnapshotManifest(files: [
            file("A/One.swift", blob: "dup"), file("B/Two.swift", blob: "dup"),
            file("C/Tool.swift", blob: "x"),
        ])
        let new = SnapshotManifest(files: [
            file("Z/Moved.swift", blob: "dup"),
            file("D/Tool.swift", blob: "y1"), file("E/Tool.swift", blob: "y2"),
        ])
        let diff = ManifestDiff.between(old, new)
        #expect(diff.renames.isEmpty)
    }

    @Test func emptyBlobsNeverPair() {
        // Two >4MB files are recorded with empty-content hashes;
        // identical emptiness is not identity.
        let empty = ContentStore.hash(Data()).raw
        let old = SnapshotManifest(files: [file("big/OldHuge.bin", blob: empty, size: 0)])
        let new = SnapshotManifest(files: [file("big/NewHuge.bin", blob: empty, size: 0)])
        let diff = ManifestDiff.between(old, new)
        #expect(diff.renames.filter(\.exact).isEmpty)
    }
}
