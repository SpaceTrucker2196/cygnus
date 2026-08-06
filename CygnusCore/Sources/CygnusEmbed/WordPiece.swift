import Foundation

// BERT WordPiece tokenization, by hand.
//
// About 120 lines against a dependency on swift-transformers, in a
// package that pins tree-sitter grammars by exact revision because of
// ABI churn. The same trade as the MCP protocol: the surface actually
// needed is small and stable, and a transitive dependency tree is not.
//
// It must agree with the tokenizer the model was converted with. If it
// does not, embeddings are subtly wrong rather than obviously broken —
// vectors still come out, they just mean something else — which is why
// the vocabulary ships beside the weights and the descriptor records
// the converter version.

public struct WordPiece: Sendable {
    public struct Encoded: Sendable {
        public let ids: [Int32]
        public let mask: [Int32]
    }

    private let vocabulary: [String: Int32]
    private let maxTokens: Int
    private let unknown: Int32
    private let classification: Int32
    private let separator: Int32
    private let padding: Int32

    public init(vocabularyFile: URL, maxTokens: Int) throws {
        guard let text = try? String(contentsOf: vocabularyFile, encoding: .utf8) else {
            throw EmbedderError.vocabularyNotFound(vocabularyFile.path)
        }
        var table: [String: Int32] = [:]
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let token = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { table[token] = Int32(index) }
        }
        guard let unknown = table["[UNK]"], let cls = table["[CLS]"],
              let sep = table["[SEP]"], let pad = table["[PAD]"] else {
            throw EmbedderError.malformedDescriptor(
                "vocabulary is missing [UNK]/[CLS]/[SEP]/[PAD]")
        }
        self.vocabulary = table
        self.maxTokens = maxTokens
        self.unknown = unknown
        self.classification = cls
        self.separator = sep
        self.padding = pad
    }

    /// For tests, which should not need a vocabulary file on disk.
    public init(vocabulary: [String: Int32], maxTokens: Int) throws {
        guard let unknown = vocabulary["[UNK]"], let cls = vocabulary["[CLS]"],
              let sep = vocabulary["[SEP]"], let pad = vocabulary["[PAD]"] else {
            throw EmbedderError.malformedDescriptor(
                "vocabulary is missing [UNK]/[CLS]/[SEP]/[PAD]")
        }
        self.vocabulary = vocabulary
        self.maxTokens = maxTokens
        self.unknown = unknown
        self.classification = cls
        self.separator = sep
        self.padding = pad
    }

    public func encode(_ text: String) -> Encoded {
        var ids: [Int32] = [classification]
        // Room for [CLS] and [SEP].
        let budget = max(maxTokens - 2, 0)

        for word in Self.basicTokenize(text) {
            guard ids.count - 1 < budget else { break }
            ids.append(contentsOf: wordPieces(word))
        }
        if ids.count - 1 > budget { ids = Array(ids.prefix(budget + 1)) }
        ids.append(separator)

        var mask = [Int32](repeating: 1, count: ids.count)
        while ids.count < maxTokens {
            ids.append(padding)
            mask.append(0)
        }
        return Encoded(ids: ids, mask: mask)
    }

    /// Greedy longest-match-first over subwords, the standard WordPiece
    /// rule. A word no prefix matches becomes [UNK] rather than being
    /// dropped, so positions stay aligned with the mask.
    func wordPieces(_ word: String) -> [Int32] {
        if let exact = vocabulary[word] { return [exact] }
        var pieces: [Int32] = []
        let characters = Array(word)
        var start = 0

        while start < characters.count {
            var end = characters.count
            var matched: Int32?
            while start < end {
                let candidate = String(characters[start..<end])
                let token = start == 0 ? candidate : "##" + candidate
                if let id = vocabulary[token] { matched = id; break }
                end -= 1
            }
            guard let id = matched else { return [unknown] }
            pieces.append(id)
            start = end
        }
        return pieces
    }

    /// Lowercase, strip accents, split on whitespace, and separate
    /// punctuation — which matters for code, where `foo.bar(baz)` must
    /// not become one token.
    static func basicTokenize(_ text: String) -> [String] {
        let folded = text.folding(options: [.diacriticInsensitive], locale: nil).lowercased()
        var tokens: [String] = []
        var current = ""
        for character in folded {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else {
                if !current.isEmpty { tokens.append(current); current = "" }
                if !character.isWhitespace { tokens.append(String(character)) }
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
