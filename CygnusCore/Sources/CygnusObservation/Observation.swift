import Foundation
import CygnusGraph
import CygnusProviders

// The extractor seam. Observation/ObservationKind/ExtractorIdentity
// live in CygnusGraph — observations are canonical-model citizens
// (the observed layer); this target owns how they get produced.

/// The seam all language extractors plug into. Per-file, pure,
/// parallelizable. Cross-file work (import resolution, linking) is
/// not an extractor concern.
public protocol ObservationExtractor: Sendable {
    var identity: ExtractorIdentity { get }
    func claims(file: SnapshotFile) -> Bool
    func extract(file: SnapshotFile, content: Data) throws -> [Observation]
}
