import Foundation
import CygnusGraph
import CygnusStore
import CygnusProviders

// BM25 search over windowed blob text, resolved to exact citations.
//
// The index stores 60-line windows, which would be a coarse citation
// on its own. Precision comes back at query time: re-read the window
// from the CAS, find the line that actually matched, and cite that.
// Cheap — one blob read per returned hit, capped by `limit` — and it
// means a result points at a line rather than at a neighbourhood.

public struct LexicalSearch: Sendable {
    private let store: SQLiteGraphStore
    private let index: RetrievalIndexStore
    private let contentStore: ContentStore

    public init(store: SQLiteGraphStore, contentStore: ContentStore) {
        self.store = store
        self.index = RetrievalIndexStore(store: store)
        self.contentStore = contentStore
    }

    /// Lines of context returned on either side of the matched line.
    public static let contextLines = 2

    public func search(_ query: String,
                       repository: RepositoryID? = nil,
                       pathPrefix: String? = nil,
                       limit: Int = 10) throws -> [RetrievalResult] {
        let terms = IdentifierSplitter.queryTerms(query)
        guard !terms.isEmpty else { return [] }
        let hits = try index.searchSource(
            matching: Self.ftsQuery(terms),
            repository: repository, pathPrefix: pathPrefix,
            // Over-fetch: several windows can collapse onto one file
            // once matched lines are resolved.
            limit: limit * 3)

        let names = try repositoryNames()
        var results: [RetrievalResult] = []
        var seen = Set<String>()

        for hit in hits {
            guard let text = try? blobText(hit.blob) else { continue }
            let lines = SourceWindows.splitLines(text)
            let windowStart = hit.startLine - 1
            let windowEnd = min(windowStart + SourceWindows.windowLines, lines.count)
            guard windowStart < windowEnd else { continue }

            guard let matched = Self.matchingLine(
                in: lines[windowStart..<windowEnd], terms: terms) else { continue }

            let line = windowStart + matched + 1
            let key = "\(hit.repository.raw):\(hit.path):\(line)"
            guard seen.insert(key).inserted else { continue }

            let from = max(windowStart, matched + windowStart - Self.contextLines)
            let to = min(windowEnd, matched + windowStart + Self.contextLines + 1)
            results.append(RetrievalResult(
                repository: hit.repository,
                repositoryName: names[hit.repository] ?? hit.repository.raw,
                path: hit.path,
                startLine: from + 1,
                endLine: to,
                layer: .observed,
                resolution: .lexical,
                // bm25 is negative and lower-is-better; flip it so a
                // bigger number reads as a better result everywhere.
                score: -hit.rank,
                snippet: lines[from..<to].joined(separator: "\n")))
            if results.count == limit { break }
        }
        return results
    }

    // MARK: - Internals

    /// The first line in the window containing any query term. Falls
    /// back to nil rather than guessing — a window that matched only
    /// through its split copy may have no literal hit, and citing an
    /// arbitrary line would be worse than dropping it.
    static func matchingLine(in lines: ArraySlice<String>, terms: [String]) -> Int? {
        let needles = terms.map { $0.lowercased() }
        for (offset, line) in lines.enumerated() {
            let haystack = line.lowercased()
            if needles.contains(where: haystack.contains) { return offset }
        }
        // No literal hit: the match came from the split column, so try
        // the split form of each line.
        for (offset, line) in lines.enumerated() {
            let haystack = IdentifierSplitter.split(line).lowercased()
            if needles.contains(where: haystack.contains) { return offset }
        }
        return nil
    }

    /// Quote every term and OR them. Quoting is what keeps a term
    /// containing FTS5 syntax (`AND`, `*`, `"`) from being read as an
    /// operator — the same defence `searchNames` already uses, minus
    /// its unconditional prefix wildcard, because source search wants
    /// exact terms by default.
    static func ftsQuery(_ terms: [String]) -> String {
        terms
            .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
            .filter { $0 != "\"\"" }
            .joined(separator: " OR ")
    }

    private func blobText(_ blob: BlobHash) throws -> String? {
        String(data: try contentStore.read(blob), encoding: .utf8)
    }

    private func repositoryNames() throws -> [RepositoryID: String] {
        Dictionary(uniqueKeysWithValues:
            try store.repositories().map { ($0.id, $0.displayName) })
    }
}
