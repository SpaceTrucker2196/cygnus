import Foundation

// A light structural view of a markdown document — enough to render
// block-by-block (headings, lists, checklists, code, quotes, rules)
// without a full CommonMark dependency, and to round-trip checklist
// toggles by rewriting the exact source line. `AttributedString`
// handles inline spans within a paragraph; this handles block layout.

public enum ChecklistMark: Sendable, Equatable, CaseIterable {
    case todo   // [ ]
    case wip    // [~]
    case done   // [x]

    /// The single character that sits between the brackets.
    public var markerCharacter: Character {
        switch self {
        case .todo: " "
        case .wip: "~"
        case .done: "x"
        }
    }

    /// Cycle order for the toggle UI: todo → wip → done → todo.
    public var next: ChecklistMark {
        switch self {
        case .todo: .wip
        case .wip: .done
        case .done: .todo
        }
    }

    init?(bracketContent: Character) {
        switch bracketContent {
        case " ": self = .todo
        case "~", "-": self = .wip
        case "x", "X": self = .done
        default: return nil
        }
    }
}

public struct ChecklistItem: Sendable, Equatable, Identifiable {
    public let mark: ChecklistMark
    public let text: String
    public let lineIndex: Int         // 0-based index into the source lines
    public init(mark: ChecklistMark, text: String, lineIndex: Int) {
        self.mark = mark; self.text = text; self.lineIndex = lineIndex
    }
    public var id: Int { lineIndex }
}

public enum MarkdownBlock: Sendable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(text: String, indent: Int)
    case checklist(ChecklistItem)
    case codeBlock(language: String?, lines: [String])
    case blockquote(String)
    case rule
    case blank
}

public struct MarkdownDocument: Sendable, Equatable {
    public let source: String
    public let lines: [String]
    public let blocks: [MarkdownBlock]

    public init(source: String) {
        self.source = source
        let lines = source.components(separatedBy: "\n")
        self.lines = lines
        self.blocks = MarkdownDocument.parse(lines)
    }

    public var checklist: [ChecklistItem] {
        blocks.compactMap { if case .checklist(let item) = $0 { item } else { nil } }
    }

    // MARK: - Parsing

    private static let checkboxRegex = try! NSRegularExpression(
        pattern: #"^(\s*)[-*]\s+\[([ xX~-])\]\s+(.*)$"#)
    private static let listRegex = try! NSRegularExpression(
        pattern: #"^(\s*)[-*]\s+(.*)$"#)

    static func parse(_ lines: [String]) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[index]); index += 1
                }
                blocks.append(.codeBlock(language: language.isEmpty ? nil : language, lines: body))
                index += 1
                continue
            }
            if trimmed.isEmpty {
                blocks.append(.blank)
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.rule)
            } else if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }
                let text = trimmed.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: min(hashes.count, 6), text: text))
            } else if let item = checklistItem(line: line, lineIndex: index) {
                blocks.append(.checklist(item))
            } else if let (indent, text) = listItem(line: line) {
                blocks.append(.listItem(text: text, indent: indent))
            } else if trimmed.hasPrefix(">") {
                blocks.append(.blockquote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                blocks.append(.paragraph(trimmed))
            }
            index += 1
        }
        return blocks
    }

    private static func checklistItem(line: String, lineIndex: Int) -> ChecklistItem? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = checkboxRegex.firstMatch(in: line, range: range),
              let markRange = Range(match.range(at: 2), in: line),
              let textRange = Range(match.range(at: 3), in: line),
              let mark = ChecklistMark(bracketContent: line[markRange.lowerBound]) else { return nil }
        return ChecklistItem(mark: mark, text: String(line[textRange]), lineIndex: lineIndex)
    }

    private static func listItem(line: String) -> (indent: Int, text: String)? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = listRegex.firstMatch(in: line, range: range),
              let indentRange = Range(match.range(at: 1), in: line),
              let textRange = Range(match.range(at: 2), in: line) else { return nil }
        return (line[indentRange].count, String(line[textRange]))
    }

    // MARK: - Checklist round-trip

    /// Return `source` with the checkbox on `lineIndex` set to `mark`,
    /// changing ONLY the single character between the brackets so the
    /// diff (and any git commit) stays minimal. No-op if the line has
    /// no checkbox.
    public func settingMark(_ mark: ChecklistMark, atLine lineIndex: Int) -> String {
        guard lines.indices.contains(lineIndex) else { return source }
        var newLines = lines
        newLines[lineIndex] = MarkdownDocument.rewriteMarker(newLines[lineIndex], to: mark)
        return newLines.joined(separator: "\n")
    }

    static func rewriteMarker(_ line: String, to mark: ChecklistMark) -> String {
        guard let open = line.firstIndex(of: "["),
              line.index(after: open) < line.endIndex,
              let close = line[line.index(after: open)...].firstIndex(of: "]"),
              line.distance(from: open, to: close) == 2  // exactly one char between brackets
        else { return line }
        let inner = line.index(after: open)
        var chars = line
        chars.replaceSubrange(inner...inner, with: String(mark.markerCharacter))
        return chars
    }
}
