import Foundation
import CygnusGraph

// Deciding what a unit of meaning is.
//
// The declarations are already in the graph with source ranges, so the
// AST chunking everyone hand-rolls is mostly a matter of using them.
// Two facts about those ranges change the shape, and both are invisible
// unless you read the extractors:
//
// 1. **Anchors nest.** A type's range fully contains every method
//    inside it. Naive "one chunk per declaration" embeds a 300-line
//    class once whole *and* once per member — double the vectors, and
//    the long generic whole-class chunk systematically outranks the
//    specific member chunks it duplicates. That is a silent quality
//    regression, not merely waste.
//
// 2. **Doc comments fall outside.** SwiftSyntax anchors start at
//    `positionAfterSkippingLeadingTrivia`, and leading trivia is
//    exactly where `///` lives. Doc comments are the richest natural
//    language in a codebase and would be dropped entirely.

public struct ChunkPlanner: Sendable {
    /// A declaration as the planner needs it — no store, so this is
    /// testable against literals.
    public struct Declaration: Sendable, Hashable {
        public let key: StableKey
        public let name: String
        public let kind: EntityKind
        public let startLine: Int
        public let endLine: Int

        public init(key: StableKey, name: String, kind: EntityKind,
                    startLine: Int, endLine: Int) {
            self.key = key
            self.name = name
            self.kind = kind
            self.startLine = startLine
            self.endLine = endLine
        }
    }

    public struct Chunk: Sendable, Hashable {
        public let ordinal: Int
        public let startLine: Int
        public let endLine: Int
        /// The declaration this chunk is, when it is one.
        public let declaration: StableKey?
        public let declarationName: String?
    }

    /// Chunks longer than this are split; declarations shorter than
    /// `minLines` don't earn one of their own.
    public static let maxLines = 120
    public static let minLines = 3
    public static let overlapLines = 15
    /// A container's header: enough to say what the type is, not its
    /// whole body, which its members already cover.
    public static let headerLines = 20

    public init() {}

    /// Non-overlapping chunks covering every line of the file.
    public func plan(lineCount: Int, declarations: [Declaration],
                     isComment: (Int) -> Bool) -> [Chunk] {
        guard lineCount > 0 else { return [] }
        let sorted = declarations.sorted {
            $0.startLine == $1.startLine
                ? $0.endLine > $1.endLine      // outer before inner
                : $0.startLine < $1.startLine
        }

        // 1. Absorb the prose above each declaration.
        let extended = sorted.map { declaration -> Declaration in
            var start = declaration.startLine
            while start > 1, isComment(start - 1) { start -= 1 }
            return Declaration(key: declaration.key, name: declaration.name,
                               kind: declaration.kind,
                               startLine: start, endLine: declaration.endLine)
        }

        // 2. A declaration containing another is a container; it emits
        //    a header only, because its members chunk themselves.
        var emitted: [Chunk] = []
        var covered = Set<Int>()
        var ordinal = 0

        func emit(_ start: Int, _ end: Int, _ declaration: Declaration?) {
            guard start <= end else { return }
            emitted.append(Chunk(ordinal: ordinal, startLine: start, endLine: end,
                                 declaration: declaration?.key,
                                 declarationName: declaration?.name))
            ordinal += 1
            covered.formUnion(start...end)
        }

        for declaration in extended {
            let children = extended.filter {
                $0.key != declaration.key
                    && $0.startLine >= declaration.startLine
                    && $0.endLine <= declaration.endLine
                    && !($0.startLine == declaration.startLine && $0.endLine == declaration.endLine)
            }
            if let firstChild = children.min(by: { $0.startLine < $1.startLine }) {
                let headerEnd = min(firstChild.startLine - 1,
                                    declaration.startLine + Self.headerLines - 1)
                emit(declaration.startLine, headerEnd, declaration)
                continue
            }
            let length = declaration.endLine - declaration.startLine + 1
            guard length >= Self.minLines else { continue }
            if length <= Self.maxLines {
                emit(declaration.startLine, declaration.endLine, declaration)
            } else {
                var start = declaration.startLine
                while start <= declaration.endLine {
                    let end = min(start + Self.maxLines - 1, declaration.endLine)
                    emit(start, end, declaration)
                    if end == declaration.endLine { break }
                    start = end + 1 - Self.overlapLines
                }
            }
        }

        // 3. Whatever no declaration claimed — imports, top-of-file
        //    comments, free-floating code — falls back to the same
        //    windows the lexical index uses, so a hit in one snaps
        //    exactly onto the other.
        var gapStart: Int?
        for line in 1...lineCount {
            if covered.contains(line) {
                if let start = gapStart { emitGap(start, line - 1) }
                gapStart = nil
            } else if gapStart == nil {
                gapStart = line
            }
        }
        if let start = gapStart { emitGap(start, lineCount) }

        func emitGap(_ start: Int, _ end: Int) {
            var cursor = start
            while cursor <= end {
                let stop = min(cursor + SourceWindows.windowLines - 1, end)
                emit(cursor, stop, nil)
                cursor = stop + 1
            }
        }

        return emitted.sorted { $0.startLine < $1.startLine }
            .enumerated()
            .map { Chunk(ordinal: $0.offset, startLine: $0.element.startLine,
                         endLine: $0.element.endLine,
                         declaration: $0.element.declaration,
                         declarationName: $0.element.declarationName) }
    }

    /// Whether a line is comment or attribute — the prose a declaration
    /// absorbs upward.
    public static func isProse(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("//") || trimmed.hasPrefix("/*")
            || trimmed.hasPrefix("*") || trimmed.hasPrefix("@")
            || trimmed.hasPrefix("#")
    }
}
