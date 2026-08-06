import Testing
@testable import CygnusRetrieval

// The difference between "code search" and "search that only finds
// what you could already spell exactly". FTS5 sees
// `withThrowingTaskGroup` as one token; without splitting, "task
// group" matches nothing.

@Suite struct IdentifierSplitterTests {
    @Test func camelCaseSplitsAtTheBoundary() {
        #expect(IdentifierSplitter.splitIdentifier("withThrowingTaskGroup")
            == ["with", "Throwing", "Task", "Group"])
    }

    /// Acronyms stay whole, but the capital that begins the next word
    /// leaves them: `HTTPClient` is HTTP + Client, not HTTPC + lient.
    @Test func acronymsStayWholeUntilTheNextWordBegins() {
        #expect(IdentifierSplitter.splitIdentifier("HTTPClient") == ["HTTP", "Client"])
        #expect(IdentifierSplitter.splitIdentifier("URLSession") == ["URL", "Session"])
        #expect(IdentifierSplitter.splitIdentifier("HTTP") == ["HTTP"])
    }

    @Test func underscoresAndDigitsAreBoundaries() {
        #expect(IdentifierSplitter.splitIdentifier("parse_json_2_string")
            == ["parse", "json", "2", "string"])
        #expect(IdentifierSplitter.splitIdentifier("SCREAMING_CASE") == ["SCREAMING", "CASE"])
    }

    @Test func shortAndUnsplittableIdentifiersSurviveIntact() {
        #expect(IdentifierSplitter.splitIdentifier("id") == ["id"])
        #expect(IdentifierSplitter.splitIdentifier("x") == ["x"])
        #expect(IdentifierSplitter.splitIdentifier("") == [])
    }

    /// Only identifiers that actually split contribute to the split
    /// column — a token indexed identically in `body` would just
    /// double its own term frequency.
    @Test func splitTextOmitsTokensThatDoNotSplit() {
        let split = IdentifierSplitter.split("let value = try await taskGroup.next()")
        #expect(split.contains("task Group"))
        #expect(!split.contains("value"))
    }

    @Test func splitPreservesLineStructure() {
        let split = IdentifierSplitter.split("fooBar\nbazQux")
        #expect(split == "foo Bar\nbaz Qux")
    }

    /// A query typed as one word must reach text written as two, and
    /// the original spelling must survive for exact matches.
    @Test func queryTermsCarryBothSpellings() {
        let terms = IdentifierSplitter.queryTerms("withThrowingTaskGroup")
        #expect(terms.contains("withThrowingTaskGroup"))
        #expect(terms.contains("Task"))
        #expect(terms.contains("Group"))
    }

    @Test func queryTermsDeduplicateCaseInsensitively() {
        let terms = IdentifierSplitter.queryTerms("task Task TASK")
        #expect(terms.count == 1)
    }
}
