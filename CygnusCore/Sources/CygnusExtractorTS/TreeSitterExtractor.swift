// tree-sitter host for Python and C extractors. The SwiftTreeSitter
// runtime and pinned grammar packages land in the E0 spike; per-
// language extraction is declarative .scm queries plus a small
// normalization map to the core vocabulary (E4).

public enum TreeSitterExtractors {
    public static let plannedLanguages = ["python", "c"]
}
