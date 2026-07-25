import SwiftUI

// A small, fast, single-line syntax highlighter for the code preview.
// Not a parser — a character scanner that colors comments, strings,
// numbers, keywords, and type-like (Capitalized) identifiers. Good
// enough to read code by; cheap enough to run per visible line.

enum SyntaxHighlighter {
    private static let swiftKeywords: Set<String> = [
        "func", "let", "var", "if", "else", "guard", "return", "for", "while",
        "switch", "case", "default", "struct", "class", "enum", "protocol",
        "extension", "import", "public", "private", "internal", "fileprivate",
        "static", "self", "init", "deinit", "throws", "try", "await", "async",
        "in", "where", "as", "is", "nil", "true", "false", "some", "any",
        "actor", "nonisolated", "lazy", "weak", "unowned", "override", "final",
        "mutating", "typealias", "associatedtype", "defer", "repeat", "do", "catch",
    ]
    private static let pythonKeywords: Set<String> = [
        "def", "class", "return", "if", "elif", "else", "for", "while", "import",
        "from", "as", "try", "except", "finally", "with", "lambda", "yield",
        "pass", "break", "continue", "in", "is", "not", "and", "or", "None",
        "True", "False", "self", "raise", "global", "nonlocal", "async", "await",
    ]
    private static let cKeywords: Set<String> = [
        "int", "char", "void", "float", "double", "long", "short", "unsigned",
        "signed", "struct", "enum", "union", "typedef", "static", "const",
        "return", "if", "else", "for", "while", "switch", "case", "default",
        "break", "continue", "sizeof", "include", "define", "extern", "goto",
    ]

    private static func keywords(for language: String?) -> Set<String> {
        switch language {
        case "python": pythonKeywords
        case "c": cKeywords
        default: swiftKeywords
        }
    }

    private static let commentColor = Color.secondary
    private static let stringColor = Color(red: 0.80, green: 0.36, blue: 0.34)
    private static let keywordColor = Color(red: 0.75, green: 0.35, blue: 0.75)
    private static let numberColor = Color(red: 0.85, green: 0.55, blue: 0.20)
    private static let typeColor = Color(red: 0.30, green: 0.62, blue: 0.62)

    static func highlight(_ line: String, language: String?) -> AttributedString {
        let keywords = keywords(for: language)
        let commentMarker: Character = language == "python" ? "#" : "/"
        var result = AttributedString()
        let chars = Array(line)
        var i = 0

        func append(_ text: String, _ color: Color) {
            var piece = AttributedString(text)
            piece.foregroundColor = color
            result += piece
        }

        while i < chars.count {
            let c = chars[i]
            // Line comment: // (swift/c) or # (python).
            if c == commentMarker,
               (commentMarker == "#" || (i + 1 < chars.count && chars[i + 1] == "/")) {
                append(String(chars[i...]), commentColor); break
            }
            // String literal.
            if c == "\"" || c == "'" {
                var j = i + 1
                while j < chars.count, chars[j] != c { if chars[j] == "\\" { j += 1 }; j += 1 }
                let end = min(j, chars.count - 1)
                append(String(chars[i...end]), stringColor)
                i = end + 1; continue
            }
            // Number.
            if c.isNumber {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                append(String(chars[i..<j]), numberColor); i = j; continue
            }
            // Identifier / keyword / type.
            if c.isLetter || c == "_" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                let word = String(chars[i..<j])
                if keywords.contains(word) {
                    append(word, keywordColor)
                } else if let first = word.first, first.isUppercase {
                    append(word, typeColor)
                } else {
                    append(word, .primary)
                }
                i = j; continue
            }
            append(String(c), .primary); i += 1
        }
        if result.characters.isEmpty { result = AttributedString(" ") }
        return result
    }
}
