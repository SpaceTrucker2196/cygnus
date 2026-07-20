import Foundation
import SwiftTreeSitter
import TreeSitterPython
import TreeSitterC

// tree-sitter host for the Python and C extractors. Grammars are
// pinned exact in Package.swift. Per-language extraction is
// declarative .scm queries plus a normalization map to the core
// vocabulary (E4); this file currently owns language setup.

public enum TreeSitterLanguageID: String, Sendable, CaseIterable {
    case python, c
}

public enum TreeSitterHost {
    /// The tree-sitter Language for a supported grammar.
    public static func language(_ id: TreeSitterLanguageID) -> Language {
        switch id {
        case .python: Language(tree_sitter_python())
        case .c: Language(tree_sitter_c())
        }
    }

    /// Parse source text; returns the root node's s-expression, or nil
    /// if parsing produced no tree. Spike-level API — E4 replaces this
    /// with query-driven observation extraction.
    public static func parseRootSExpression(_ id: TreeSitterLanguageID,
                                            source: String) throws -> String? {
        let parser = Parser()
        try parser.setLanguage(language(id))
        guard let tree = parser.parse(source) else { return nil }
        return tree.rootNode?.sExpressionString
    }
}
