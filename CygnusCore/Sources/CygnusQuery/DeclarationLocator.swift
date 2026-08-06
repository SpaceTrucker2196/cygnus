import Foundation
import CygnusGraph
import CygnusStore

// Maps a (path, line) back to the declaration entity that encloses it.
//
// Reference enrichment needs this to attribute a compiler-resolved
// occurrence to the symbol it sits inside. Retrieval needs exactly the
// same thing to attribute a lexical or semantic hit to a graph entity,
// which is what lets a search result carry a stable key, a provenance
// chain, and an honest layer label rather than a bare file offset.
//
// Built once per repository from the committed declaration entities and
// their source ranges — a projection of the graph, not a second model.
public struct DeclarationLocator: Sendable {
    public struct Span: Sendable {
        public let start: Int
        public let end: Int
        public let key: StableKey

        public init(start: Int, end: Int, key: StableKey) {
            self.start = start
            self.end = end
            self.key = key
        }
    }

    public let byPath: [String: [Span]]

    public init(byPath: [String: [Span]]) {
        self.byPath = byPath
    }

    /// The declaration kinds that can enclose a source line.
    public static let declarationKinds: [EntityKind] =
        [.type, .interface, .enumeration, .function, .variable]

    /// Build a locator over one repository's current declarations.
    public static func build(store: SQLiteGraphStore,
                             repository: RepositoryID,
                             at query: RevisionQuery = .current) throws -> DeclarationLocator {
        var byPath: [String: [Span]] = [:]
        for kind in declarationKinds {
            for resolved in try store.entities(kind: kind, at: query)
            where resolved.entity.repository == repository {
                guard let anchor = resolved.version.anchors.first,
                      let range = anchor.range else { continue }
                byPath[anchor.path, default: []].append(Span(
                    start: range.startLine,
                    end: range.endLine,
                    key: resolved.entity.stableKey))
            }
        }
        return DeclarationLocator(byPath: byPath)
    }

    /// The innermost declaration containing `line`, if any.
    public func enclosing(path: String, line: Int) -> StableKey? {
        guard let spans = byPath[path] else { return nil }
        // Smallest span containing the line wins (innermost decl).
        return spans
            .filter { $0.start <= line && line <= $0.end }
            .min { ($0.end - $0.start) < ($1.end - $1.start) }?
            .key
    }
}
