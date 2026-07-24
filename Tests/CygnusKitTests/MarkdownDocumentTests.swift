import Testing
import Foundation
@testable import CygnusKit

@Suite struct MarkdownDocumentTests {
    @Test func classifiesBlocks() {
        let source = """
        # Heading

        A paragraph.

        - plain item
        - [ ] todo item
        - [x] done item

        > a quote

        ```swift
        let x = 1
        ```
        """
        let doc = MarkdownDocument(source: source)
        #expect(doc.blocks.contains(.heading(level: 1, text: "Heading")))
        #expect(doc.blocks.contains(.paragraph("A paragraph.")))
        #expect(doc.blocks.contains(.listItem(text: "plain item", indent: 0)))
        #expect(doc.blocks.contains(.blockquote("a quote")))
        #expect(doc.blocks.contains(.codeBlock(language: "swift", lines: ["let x = 1"])))
        #expect(doc.checklist.count == 2)
        #expect(doc.checklist[0].mark == .todo)
        #expect(doc.checklist[1].mark == .done)
    }

    @Test func parsesThreeStateChecklist() {
        let source = "- [ ] a\n- [~] b\n- [x] c"
        let doc = MarkdownDocument(source: source)
        #expect(doc.checklist.map(\.mark) == [.todo, .wip, .done])
        #expect(doc.checklist.map(\.text) == ["a", "b", "c"])
        #expect(doc.checklist.map(\.lineIndex) == [0, 1, 2])
    }

    @Test func togglingRewritesOnlyTheOneMarker() {
        // Milestones-style content with a date suffix that MUST survive.
        let source = """
        ## Engine

        - [x] **E1** — Graph model. *(2026-07-19)*
        - [~] **E6** — Hardening. Done: FSEvents. Remaining: rollups.
        - [ ] **E7** — Fuzzy renames.
        """
        let doc = MarkdownDocument(source: source)
        let e6Line = doc.checklist.first { $0.text.contains("E6") }!.lineIndex
        let updated = doc.settingMark(.done, atLine: e6Line)

        // Exactly one character differs between source and updated.
        #expect(updated.count == source.count)
        let diffs = zip(source, updated).filter { $0 != $1 }
        #expect(diffs.count == 1)
        #expect(diffs.first?.1 == "x")
        // And it re-parses with E6 now done, date suffix intact.
        let reparsed = MarkdownDocument(source: updated)
        let e6 = reparsed.checklist.first { $0.text.contains("E6") }!
        #expect(e6.mark == .done)
        #expect(reparsed.checklist.first { $0.text.contains("E1") }!.text.contains("*(2026-07-19)*"))
    }

    @Test func togglingNonCheckboxLineIsNoOp() {
        let doc = MarkdownDocument(source: "# Not a checkbox\n\ntext")
        #expect(doc.settingMark(.done, atLine: 0) == "# Not a checkbox\n\ntext")
    }

    @Test func markCyclesTodoWipDone() {
        #expect(ChecklistMark.todo.next == .wip)
        #expect(ChecklistMark.wip.next == .done)
        #expect(ChecklistMark.done.next == .todo)
    }
}

@Suite struct WikiLinkTests {
    @Test func extractsPlainAndAliasedLinks() {
        let links = WikiLinkParser.links(in: "See [[architecture]] and [[jsonl-schema|the schema]].")
        #expect(links.count == 2)
        #expect(links[0].target == "architecture")
        #expect(links[0].alias == nil)
        #expect(links[0].displayText == "architecture")
        #expect(links[1].target == "jsonl-schema")
        #expect(links[1].displayText == "the schema")
    }

    @Test func resolvesAgainstKnownSlugs() {
        let known = ["architecture": "docs/wiki/architecture.md",
                     "jsonl-schema": "docs/wiki/jsonl-schema.md"]
        #expect(WikiLinkParser.resolve(WikiLink(target: "Architecture", alias: nil), in: known)
                == "docs/wiki/architecture.md")
        #expect(WikiLinkParser.resolve(WikiLink(target: "JSONL_Schema", alias: nil), in: known)
                == "docs/wiki/jsonl-schema.md")
        #expect(WikiLinkParser.resolve(WikiLink(target: "missing", alias: nil), in: known) == nil)
    }

    @Test func slugNormalises() {
        #expect(WikiLinkParser.slug("Docs Drift Judge") == "docs-drift-judge")
        #expect(WikiLinkParser.slug("platform_vtable.md") == "platform-vtable")
    }

    @Test func parsesFrontmatter() {
        let source = """
        ---
        name: architecture
        description: Code-tree layout and the seams
        type: reference
        ---

        # Architecture

        Body text.
        """
        let parsed = Frontmatter.parse(source)
        #expect(parsed?.fields["name"] == "architecture")
        #expect(parsed?.fields["type"] == "reference")
        #expect(source[parsed!.bodyRange].contains("# Architecture"))
        #expect(!source[parsed!.bodyRange].contains("name: architecture"))
    }

    @Test func noFrontmatterReturnsNil() {
        #expect(Frontmatter.parse("# Just a heading\n\ntext") == nil)
        #expect(Frontmatter.fields("# No frontmatter").isEmpty)
    }
}
