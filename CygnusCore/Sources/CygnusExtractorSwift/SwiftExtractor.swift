import Foundation
import SwiftParser
import SwiftSyntax
import CygnusGraph
import CygnusObservation
import CygnusProviders

// SwiftSyntax-based extractor: source-level, no build required, works
// on checkouts that don't compile. Full declaration/import/extension
// extraction lands in E3; this currently proves the SwiftSyntax seam.

public struct SwiftExtractor: ObservationExtractor {
    public let identity = ExtractorIdentity(name: "swift-syntax", version: "0.1.0")

    public init() {}

    public func claims(file: SnapshotFile) -> Bool {
        file.path.hasSuffix(".swift")
    }

    public func extract(file: SnapshotFile, content: Data) throws -> [Observation] {
        let source = String(decoding: content, as: UTF8.self)
        let tree = Parser.parse(source: source)
        // E3: walk the tree emitting declaration/import observations.
        _ = tree
        return []
    }
}
