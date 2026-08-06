import Testing
import Foundation
import CygnusGraph
import CygnusStore
import CygnusProviders
@testable import CygnusRetrieval

// read_span exists beside an agent's own file-read tool for exactly
// one reason: it reads the snapshot the line numbers refer to, and it
// says so when the working tree has moved on. Reading disk instead
// would hand back mismatched text silently.

@Suite struct SpanReaderTests {
    let repo = RepositoryID("test-repo")

    private struct Fixture {
        let store: SQLiteGraphStore
        let cas: ContentStore
        let reader: SpanReader
        let root: URL
    }

    private func makeFixture(content: String,
                             path: String = "Sources/A.swift") throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-span-\(UUID().uuidString)")
        let tree = root.appendingPathComponent("tree")
        try FileManager.default.createDirectory(
            at: tree.appendingPathComponent(path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try content.write(to: tree.appendingPathComponent(path),
                          atomically: true, encoding: .utf8)

        let store = try SQLiteGraphStore.inMemory()
        try store.registerRepository(repo, displayName: "Test Repo", rootPath: tree.path)
        let cas = try ContentStore(root: root.appendingPathComponent("cas"))
        let blob = try cas.store(Data(content.utf8))

        let snapshot = try store.recordSnapshot(
            repository: repo, sourceRef: nil,
            files: [.init(path: path, blobHash: blob.raw,
                          size: Int64(content.utf8.count), languageHint: "swift")])
        // A snapshot only counts as current once a revision references
        // it — the same rule the incremental baseline uses.
        _ = try store.commit(RevisionChanges(), note: "snapshot", snapshot: snapshot)

        return Fixture(store: store, cas: cas,
                       reader: SpanReader(store: store, contentStore: cas), root: root)
    }

    private let sample = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"

    @Test func readsTheRequestedRangeInclusively() throws {
        let fixture = try makeFixture(content: sample)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let span = try fixture.reader.read(path: "Sources/A.swift", startLine: 3, endLine: 5)
        #expect(span.text == "line 3\nline 4\nline 5")
        #expect(span.startLine == 3 && span.endLine == 5)
        #expect(!span.stale)
    }

    /// The whole point: the tree changed, the snapshot did not, and the
    /// caller is told rather than silently handed different text.
    @Test func driftFromTheWorkingTreeIsReported() throws {
        let fixture = try makeFixture(content: sample)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try "totally different\n".write(
            to: fixture.root.appendingPathComponent("tree/Sources/A.swift"),
            atomically: true, encoding: .utf8)

        let span = try fixture.reader.read(path: "Sources/A.swift", startLine: 1, endLine: 2)
        #expect(span.stale)
        // Still the snapshot's text — the numbers refer to it.
        #expect(span.text.contains("line 1"))
    }

    @Test func rangesAreClampedToTheFile() throws {
        let fixture = try makeFixture(content: sample)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let span = try fixture.reader.read(path: "Sources/A.swift", startLine: 8, endLine: 999)
        #expect(span.endLine == 10)
    }

    /// A read tool must not be a way to spend a whole context window.
    @Test func oversizedRequestsAreCappedAndSayThatTheyWere() throws {
        let big = (1...(SpanReader.maxLines + 50)).map { "line \($0)" }.joined(separator: "\n")
        let fixture = try makeFixture(content: big)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let span = try fixture.reader.read(path: "Sources/A.swift",
                                           startLine: 1, endLine: SpanReader.maxLines + 50)
        #expect(span.endLine == SpanReader.maxLines)
        #expect(span.truncatedTo == SpanReader.maxLines)
    }

    @Test func unknownPathsThrowRatherThanReturnNothing() throws {
        let fixture = try makeFixture(content: sample)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(throws: SpanReader.SpanError.pathNotInSnapshot("Sources/Missing.swift")) {
            try fixture.reader.read(path: "Sources/Missing.swift", startLine: 1, endLine: 2)
        }
    }

    @Test func invertedRangesAreRejected() throws {
        let fixture = try makeFixture(content: sample)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(throws: SpanReader.SpanError.emptyRange) {
            try fixture.reader.read(path: "Sources/A.swift", startLine: 5, endLine: 2)
        }
    }
}
