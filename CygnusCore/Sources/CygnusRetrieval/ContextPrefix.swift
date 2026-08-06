import Foundation
import CygnusGraph

// The situating text prepended to a chunk before embedding.
//
// Anthropic's contextual-retrieval result comes from an LLM writing a
// blurb that situates each chunk in its document. For code, the graph
// already knows that context — path, imports, enclosing type, siblings
// — so it can be assembled deterministically, for free, with no model
// pass over the corpus and none of its cost.
//
// **The trap, and the rule that avoids it.** It is tempting to enrich
// this with cross-file facts: "referenced by RequestQueue.enqueue".
// Doing so makes a chunk's embedding depend on *other files*, so
// editing B silently staleifies A's vector and the blob-keyed
// incrementality this whole layer rests on collapses into a transitive
// invalidation problem. So the prefix uses **only file-local facts**,
// and cross-file signal enters at rank time as a graph boost instead.
// With that rule the chunk row and its vector stay pure functions of
// blob content, which is why `cygnus watch` needs no special handling.

public struct ContextPrefix: Sendable, Hashable {
    public let text: String

    public init(repository: String,
                path: String,
                imports: [String],
                enclosing: [String],
                siblings: [String]) {
        var lines = ["repo: \(repository) | file: \(path)"]
        if !imports.isEmpty {
            lines.append("imports: \(imports.sorted().joined(separator: ", "))")
        }
        if !enclosing.isEmpty {
            lines.append("enclosing: \(enclosing.joined(separator: " › "))")
        }
        if !siblings.isEmpty {
            // Bounded: a 200-member type would otherwise bury the chunk
            // it is supposed to be situating.
            let shown = siblings.prefix(8).joined(separator: ", ")
            lines.append("siblings: \(shown)")
        }
        text = lines.joined(separator: "\n") + "\n---\n"
    }

    /// Prepend to the chunk body for embedding. Never stored as source
    /// — the CAS remains the only copy of the text.
    public func applied(to body: String) -> String { text + body }
}
