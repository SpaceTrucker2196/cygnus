import Testing
import Foundation
@testable import CygnusRetrieval

// Windowing is a pure function of blob content, and every downstream
// claim about incrementality rests on that. These are the golden
// cases: get line numbering or CRLF wrong here and every citation in
// the system is off by one.

@Suite struct SourceWindowsTests {
    @Test func emptyTextYieldsNoWindows() {
        #expect(SourceWindows.split("").isEmpty)
        #expect(SourceWindows.lineCount("") == 0)
    }

    @Test func singleLineIsOneWindowStartingAtLineOne() {
        let windows = SourceWindows.split("let x = 1\n")
        #expect(windows.count == 1)
        #expect(windows[0].ordinal == 0)
        #expect(windows[0].startLine == 1)
        #expect(windows[0].body == "let x = 1")
    }

    /// A trailing newline terminates the last line; it does not begin
    /// an empty one. Otherwise every file gains a phantom final line
    /// and the count disagrees with every editor.
    @Test func trailingNewlineDoesNotAddALine() {
        #expect(SourceWindows.lineCount("a\nb\n") == 2)
        #expect(SourceWindows.lineCount("a\nb") == 2)
    }

    @Test func exactlyOneWindowAtTheBoundary() {
        let text = (1...SourceWindows.windowLines).map { "line \($0)" }.joined(separator: "\n")
        let windows = SourceWindows.split(text)
        #expect(windows.count == 1)
        #expect(windows[0].startLine == 1)
    }

    @Test func oneLinePastTheBoundarySpillsIntoASecondWindow() {
        let text = (1...(SourceWindows.windowLines + 1))
            .map { "line \($0)" }.joined(separator: "\n")
        let windows = SourceWindows.split(text)
        #expect(windows.count == 2)
        #expect(windows[1].ordinal == 1)
        #expect(windows[1].startLine == SourceWindows.windowLines + 1)
        #expect(windows[1].body == "line \(SourceWindows.windowLines + 1)")
    }

    /// A CRLF checkout must index identically to an LF one, or the same
    /// content hashes to two different indexes.
    @Test func carriageReturnsAreStripped() {
        let crlf = SourceWindows.split("alpha\r\nbeta\r\n")
        let lf = SourceWindows.split("alpha\nbeta\n")
        #expect(crlf.map(\.body) == lf.map(\.body))
    }

    @Test func windowingIsDeterministic() {
        let text = (1...150).map { "func f\($0)() {}" }.joined(separator: "\n")
        let runs = (0..<3).map { _ in SourceWindows.split(text).map(\.body) }
        #expect(runs[0] == runs[1])
        #expect(runs[1] == runs[2])
    }

    @Test func startLinesAreContiguousAndCoverEveryLine() {
        let text = (1...200).map { "line \($0)" }.joined(separator: "\n")
        let windows = SourceWindows.split(text)
        #expect(windows.count == 4)
        for (index, window) in windows.enumerated() {
            #expect(window.startLine == index * SourceWindows.windowLines + 1)
        }
        let totalLines = windows.reduce(0) { $0 + $1.body.components(separatedBy: "\n").count }
        #expect(totalLines == 200)
    }
}
