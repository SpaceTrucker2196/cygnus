import Testing
import Foundation
@testable import CygnusEmbed

// If tokenization disagrees with what the model was converted against,
// embeddings are subtly wrong rather than obviously broken — vectors
// still come out, they just mean something else. These pin the rules
// that make it agree.

@Suite struct WordPieceTests {
    private func makeTokenizer(_ extra: [String: Int32] = [:],
                               maxTokens: Int = 16) throws -> WordPiece {
        var vocabulary: [String: Int32] = [
            "[PAD]": 0, "[UNK]": 1, "[CLS]": 2, "[SEP]": 3,
        ]
        for (token, id) in extra { vocabulary[token] = id }
        return try WordPiece(vocabulary: vocabulary, maxTokens: maxTokens)
    }

    @Test func encodingIsWrappedInClassificationAndSeparator() throws {
        let tokenizer = try makeTokenizer(["send": 10])
        let encoded = tokenizer.encode("send")
        #expect(encoded.ids[0] == 2)                 // [CLS]
        #expect(encoded.ids[1] == 10)
        #expect(encoded.ids[2] == 3)                 // [SEP]
    }

    /// Padding must be masked out. Mean-pooling over padding drags
    /// every vector toward whatever [PAD] encodes, which is the classic
    /// way to end up with a model that thinks everything is similar.
    @Test func paddingIsMaskedOut() throws {
        let tokenizer = try makeTokenizer(["send": 10], maxTokens: 8)
        let encoded = tokenizer.encode("send")
        #expect(encoded.ids.count == 8)
        #expect(encoded.mask.count == 8)
        #expect(encoded.mask.prefix(3).allSatisfy { $0 == 1 })
        #expect(encoded.mask.suffix(5).allSatisfy { $0 == 0 })
    }

    /// Greedy longest-match with ## continuations — the standard rule.
    @Test func unknownWordsSplitIntoSubwords() throws {
        let tokenizer = try makeTokenizer(["play": 10, "##ing": 11])
        #expect(tokenizer.wordPieces("playing") == [10, 11])
    }

    /// A word nothing matches becomes [UNK] rather than vanishing, so
    /// token positions stay aligned with the mask.
    @Test func anUnmatchableWordBecomesUnknown() throws {
        let tokenizer = try makeTokenizer(["play": 10])
        #expect(tokenizer.wordPieces("zzzz") == [1])
    }

    /// Code, not prose: `foo.bar(baz)` must not become one token.
    @Test func punctuationSeparatesTokensInCode() {
        #expect(WordPiece.basicTokenize("foo.bar(baz)") == ["foo", ".", "bar", "(", "baz", ")"])
    }

    @Test func tokenizationIsLowercasedAndAccentFolded() {
        #expect(WordPiece.basicTokenize("Café SEND") == ["cafe", "send"])
    }

    /// Overlong input is truncated rather than overflowing the model's
    /// fixed input width.
    @Test func longInputIsTruncatedToTheModelWidth() throws {
        let tokenizer = try makeTokenizer(["a": 10], maxTokens: 6)
        let encoded = tokenizer.encode(String(repeating: "a ", count: 50))
        #expect(encoded.ids.count == 6)
        #expect(encoded.ids.last == 3)               // still terminated by [SEP]
    }

    @Test func emptyInputStillProducesAValidEncoding() throws {
        let tokenizer = try makeTokenizer(maxTokens: 4)
        let encoded = tokenizer.encode("")
        #expect(encoded.ids == [2, 3, 0, 0])
        #expect(encoded.mask == [1, 1, 0, 0])
    }

    /// A vocabulary without the special tokens is unusable, and saying
    /// so at load time beats producing meaningless vectors later.
    @Test func aVocabularyMissingSpecialTokensIsRejected() {
        #expect(throws: EmbedderError.self) {
            try WordPiece(vocabulary: ["hello": 1], maxTokens: 8)
        }
    }
}
