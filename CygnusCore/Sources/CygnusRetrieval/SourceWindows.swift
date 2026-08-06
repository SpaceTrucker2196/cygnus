import Foundation
import CygnusGraph
import CygnusStore

// The one canonical windowing function. Phase 1 indexes these for
// full-text search; the chunker will reuse it to cover lines no
// declaration claims, so the two indexes agree on boundaries and a
// hit in one can be snapped to the other exactly.
//
// A window is a pure function of blob content — no path, no repository,
// no revision. That is deliberate and it is the whole incrementality
// story: identical content windows identically no matter where it
// appears or how it got there.

public enum SourceWindows {
    /// Lines per window. No overlap: overlap inflates the index and
    /// double-counts BM25 across duplicated lines. The cost is that a
    /// phrase straddling a boundary won't match as a phrase, which is
    /// acceptable when the alternative distorts every score.
    public static let windowLines = 60

    /// Split blob text into indexable windows.
    ///
    /// Line numbers are 1-based to match `SourceRange` everywhere else
    /// in the codebase. A trailing `\r` is stripped per line so CRLF
    /// checkouts index the same as LF ones.
    public static func split(_ text: String) -> [SourceWindow] {
        let lines = splitLines(text)
        guard !lines.isEmpty else { return [] }

        return stride(from: 0, to: lines.count, by: windowLines).map { offset in
            let slice = lines[offset..<min(offset + windowLines, lines.count)]
            let body = slice.joined(separator: "\n")
            return SourceWindow(
                ordinal: offset / windowLines,
                startLine: offset + 1,
                body: body,
                bodySplit: IdentifierSplitter.split(body))
        }
    }

    /// Line count of a blob, for the index ledger.
    public static func lineCount(_ text: String) -> Int {
        splitLines(text).count
    }

    static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n").map { line -> String in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
        // A trailing newline ends the last line; it does not begin an
        // empty one. Without this every file gains a phantom final line
        // and the line count disagrees with every editor.
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        return lines
    }
}
