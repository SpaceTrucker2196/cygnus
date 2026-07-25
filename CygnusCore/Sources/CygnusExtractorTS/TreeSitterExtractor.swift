import Foundation
import SwiftTreeSitter
import TreeSitterPython
import TreeSitterC
import TreeSitterRust
import CygnusGraph
import CygnusObservation
import CygnusProviders

// tree-sitter host for the Python, C, and Rust extractors. Grammars
// are pinned exact in Package.swift. Extraction is query-driven; a
// new language is a grammar dependency, a query, and a normalization
// map to the core vocabulary.

public enum TreeSitterLanguageID: String, Sendable, CaseIterable {
    case python, c, rust
}

public enum TreeSitterHost {
    /// The tree-sitter Language for a supported grammar.
    public static func language(_ id: TreeSitterLanguageID) -> Language {
        switch id {
        case .python: Language(tree_sitter_python())
        case .c: Language(tree_sitter_c())
        case .rust: Language(tree_sitter_rust())
        }
    }

    /// Parse source text; returns the root node's s-expression, or nil
    /// if parsing produced no tree.
    public static func parseRootSExpression(_ id: TreeSitterLanguageID,
                                            source: String) throws -> String? {
        let parser = Parser()
        try parser.setLanguage(language(id))
        guard let tree = parser.parse(source) else { return nil }
        return tree.rootNode?.sExpressionString
    }

    /// One query capture with its resolved text and location.
    public struct Capture {
        public let name: String
        public let text: String
        public let range: SourceRange
        public let node: Node
    }

    /// Run a query over source, yielding named captures in document
    /// order. Parser and query are created per call: neither is
    /// Sendable, and extractors run concurrently.
    public static func captures(_ id: TreeSitterLanguageID, query queryText: String,
                                source: String) throws -> [Capture] {
        let language = language(id)
        let parser = Parser()
        try parser.setLanguage(language)
        guard let tree = parser.parse(source) else { return [] }
        let query = try Query(language: language, data: Data(queryText.utf8))
        let cursor = query.execute(in: tree)
        let text = source as NSString

        var result: [Capture] = []
        while let match = cursor.next() {
            for capture in match.captures {
                let node = capture.node
                let start = node.pointRange.lowerBound
                let end = node.pointRange.upperBound
                result.append(Capture(
                    name: capture.name ?? "",
                    text: text.substring(with: node.range),
                    range: SourceRange(
                        startLine: Int(start.row) + 1, startColumn: Int(start.column / 2) + 1,
                        endLine: Int(end.row) + 1, endColumn: Int(end.column / 2) + 1),
                    node: node))
            }
        }
        return result
    }

    /// Dot-joined nesting path for a declaration node: names of
    /// enclosing definition nodes (of the given syntax kinds),
    /// outermost first, ending with the node's own captured name.
    public static func declPath(for node: Node, name: String,
                                nestingKinds: Set<String>, in source: String) -> String {
        let text = source as NSString
        var components: [String] = []
        var ancestor = node.parent
        // The captured node is a declaration's `name` field, so its
        // immediate parent is that declaration's own item — skip it,
        // or a top-level `struct Foo` would path as "Foo.Foo".
        if let parent = ancestor, nestingKinds.contains(parent.nodeType ?? ""),
           parent.child(byFieldName: "name")?.range == node.range {
            ancestor = parent.parent
        }
        while let current = ancestor {
            if nestingKinds.contains(current.nodeType ?? ""),
               let nameNode = current.child(byFieldName: "name") {
                components.append(text.substring(with: nameNode.range))
            }
            ancestor = current.parent
        }
        return (components.reversed() + [name]).joined(separator: ".")
    }
}
