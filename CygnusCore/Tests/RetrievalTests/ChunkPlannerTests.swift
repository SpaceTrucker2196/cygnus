import Testing
import Foundation
import CygnusGraph
@testable import CygnusRetrieval

// The two facts about declaration anchors that would otherwise degrade
// the semantic tier silently: they nest, and they exclude doc comments.
// Both are pinned here because neither produces a visible failure —
// just quietly worse retrieval.

@Suite struct ChunkPlannerTests {
    private func decl(_ name: String, _ kind: EntityKind,
                      _ start: Int, _ end: Int) -> ChunkPlanner.Declaration {
        ChunkPlanner.Declaration(key: StableKey("swift:decl:r/F.swift#\(name)"),
                                 name: name, kind: kind, startLine: start, endLine: end)
    }

    private let noProse: (Int) -> Bool = { _ in false }

    /// A type containing methods emits a header only. Embedding the
    /// whole class as well as each member double-counts, and the long
    /// generic chunk outranks the specific ones it duplicates.
    @Test func aContainerEmitsAHeaderNotItsWholeBody() {
        let chunks = ChunkPlanner().plan(
            lineCount: 100,
            declarations: [decl("Client", .type, 1, 100),
                           decl("send", .function, 20, 40),
                           decl("cancel", .function, 45, 60)],
            isComment: noProse)

        let container = try! #require(chunks.first { $0.declarationName == "Client" })
        #expect(container.startLine == 1)
        #expect(container.endLine < 20, "the header must stop before its first member")
        #expect(chunks.contains { $0.declarationName == "send" })
        #expect(chunks.contains { $0.declarationName == "cancel" })
    }

    /// No line is embedded twice — that is what makes the container
    /// rule worth having.
    @Test func chunksDoNotOverlapForNestedDeclarations() {
        let chunks = ChunkPlanner().plan(
            lineCount: 100,
            declarations: [decl("Client", .type, 1, 100),
                           decl("send", .function, 20, 40)],
            isComment: noProse)

        var seen = Set<Int>()
        for chunk in chunks {
            for line in chunk.startLine...chunk.endLine {
                #expect(seen.insert(line).inserted == true, "line \(line) chunked twice")
            }
        }
    }

    /// Doc comments sit outside the anchor because SwiftSyntax skips
    /// leading trivia — so the chunk must reach back and take them.
    @Test func aDeclarationAbsorbsItsDocComment() {
        // Lines 1-3 are `///` prose; the declaration's anchor is 4-10.
        let chunks = ChunkPlanner().plan(
            lineCount: 10,
            declarations: [decl("send", .function, 4, 10)],
            isComment: { $0 <= 3 })

        let chunk = try! #require(chunks.first { $0.declarationName == "send" })
        #expect(chunk.startLine == 1, "the doc comment was left out of the chunk")
    }

    /// Every line belongs to exactly one chunk, so nothing in the file
    /// is unreachable by semantic search.
    @Test func everyLineIsCovered() {
        let chunks = ChunkPlanner().plan(
            lineCount: 200,
            declarations: [decl("a", .function, 10, 30), decl("b", .function, 100, 140)],
            isComment: noProse)

        let covered = Set(chunks.flatMap { $0.startLine...$0.endLine })
        #expect(covered == Set(1...200))
    }

    /// A file with no declarations still chunks — markdown, YAML and
    /// Makefiles are worth retrieving.
    @Test func aFileWithNoDeclarationsFallsBackToWindows() {
        let chunks = ChunkPlanner().plan(lineCount: 130, declarations: [], isComment: noProse)
        #expect(chunks.count == 3)          // 60 + 60 + 10
        #expect(chunks.allSatisfy { $0.declaration == nil })
    }

    /// One-liners don't earn their own chunk; they ride in the gap or
    /// their parent's header.
    @Test func trivialDeclarationsDoNotGetTheirOwnChunk() {
        let chunks = ChunkPlanner().plan(
            lineCount: 20,
            declarations: [decl("id", .variable, 5, 5)],
            isComment: noProse)
        #expect(!chunks.contains { $0.declarationName == "id" })
        #expect(Set(chunks.flatMap { $0.startLine...$0.endLine }) == Set(1...20))
    }

    @Test func anOversizedDeclarationIsSplit() {
        let chunks = ChunkPlanner().plan(
            lineCount: 400,
            declarations: [decl("huge", .function, 1, 400)],
            isComment: noProse)
        let parts = chunks.filter { $0.declarationName == "huge" }
        #expect(parts.count > 1)
        #expect(parts.allSatisfy { $0.endLine - $0.startLine + 1 <= ChunkPlanner.maxLines })
    }

    @Test func planningIsDeterministic() {
        let declarations = [decl("Client", .type, 1, 100), decl("send", .function, 20, 40)]
        let runs = (0..<3).map { _ in
            ChunkPlanner().plan(lineCount: 100, declarations: declarations, isComment: noProse)
        }
        #expect(runs[0] == runs[1])
        #expect(runs[1] == runs[2])
    }
}
