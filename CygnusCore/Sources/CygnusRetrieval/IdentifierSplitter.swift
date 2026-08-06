import Foundation

// Breaks identifiers into their words.
//
// This is not a nicety. FTS5's unicode61 tokenizer treats
// `withThrowingTaskGroup` as one indivisible token, so a search for
// "task group" — the way a person actually asks — matches nothing at
// all. Indexing a split copy of every window alongside the verbatim
// text is what makes the lexical tier usable for anything other than
// an exact identifier the searcher already knows.
//
// The same function expands queries, so "TaskGroup" typed as one word
// still matches text written as two.

public enum IdentifierSplitter {
    /// `"withThrowingTaskGroup"` → `"with Throwing Task Group"`,
    /// `"HTTPClient"` → `"HTTP Client"`,
    /// `"parse_json_2_string"` → `"parse json 2 string"`.
    ///
    /// Runs of capitals stay together (`HTTP`, `URL`, `SQL`) except for
    /// the last one when a lowercase letter follows it — that capital
    /// starts the next word, which is what makes `HTTPClient` split
    /// after `HTTP` rather than after `HTTPC`.
    public static func splitIdentifier(_ identifier: String) -> [String] {
        var words: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty { words.append(current); current = "" }
        }

        let characters = Array(identifier)
        for (index, character) in characters.enumerated() {
            guard character.isLetter || character.isNumber else {
                // _, -, ., $ and friends are word boundaries.
                flush()
                continue
            }
            if current.isEmpty {
                current.append(character)
                continue
            }

            let previous = characters[index - 1]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let startsWord: Bool

            if character.isUppercase && previous.isLowercase {
                // camel → Case
                startsWord = true
            } else if character.isUppercase, previous.isUppercase,
                      let next, next.isLowercase {
                // HTTPClient: C begins the next word because a
                // lowercase letter follows it.
                startsWord = true
            } else if character.isNumber != previous.isNumber {
                // json2string → json 2 string
                startsWord = true
            } else {
                startsWord = false
            }

            if startsWord { flush() }
            current.append(character)
        }
        flush()
        return words
    }

    /// Split every identifier in a body of text, preserving the
    /// original tokens alongside their parts. Line structure is kept so
    /// a window's split copy still resembles its source.
    public static func split(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                line.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .flatMap { token -> [String] in
                        let parts = splitIdentifier(String(token))
                        // A token that doesn't split adds nothing beyond
                        // what `body` already indexes verbatim.
                        return parts.count > 1 ? parts : []
                    }
                    .joined(separator: " ")
            }
            .joined(separator: "\n")
    }

    /// Expand a user query so a single-word spelling matches split text
    /// and vice versa. Returns the distinct terms to search for.
    public static func queryTerms(_ query: String) -> [String] {
        var terms: [String] = []
        var seen = Set<String>()
        for token in query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let raw = String(token)
            if seen.insert(raw.lowercased()).inserted { terms.append(raw) }
            for part in splitIdentifier(raw) where seen.insert(part.lowercased()).inserted {
                terms.append(part)
            }
        }
        return terms
    }
}
