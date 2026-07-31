import Testing
import Foundation
@testable import CygnusKit

// The knowledge base at docs/wiki is read inside the app, where a
// broken [[link]] just renders as dead text. These tests fail loudly
// instead — a wiki nobody can navigate rots quietly.

@Suite struct WikiIntegrityTests {
    /// Walk up from this source file to the repo root. Tests run from
    /// varying working directories; the source path does not move.
    private var wikiDirectory: URL {
        URL(fileURLWithPath: #filePath)          // Tests/CygnusKitTests/…
            .deletingLastPathComponent()          // Tests/CygnusKitTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("docs/wiki")
    }

    private func pages() throws -> [(slug: String, source: String)] {
        try FileManager.default
            .contentsOfDirectory(at: wikiDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { (WikiLinkParser.slug($0.lastPathComponent),
                    try String(contentsOf: $0, encoding: .utf8)) }
    }

    @Test func theWikiExistsAndHasAHome() throws {
        let slugs = try pages().map(\.slug)
        #expect(!slugs.isEmpty, "docs/wiki has no pages")
        #expect(slugs.contains("home"), "docs/wiki has no home page")
    }

    @Test func everyWikiLinkResolves() throws {
        let all = try pages()
        let known = Dictionary(uniqueKeysWithValues: all.map { ($0.slug, $0.slug) })
        var broken: [String] = []
        for page in all {
            for link in WikiLinkParser.links(in: page.source)
            where WikiLinkParser.resolve(link, in: known) == nil {
                broken.append("\(page.slug) → [[\(link.target)]]")
            }
        }
        #expect(broken.isEmpty, "broken wiki links: \(broken.joined(separator: ", "))")
    }

    /// A page reachable from nowhere is a page nobody reads. Home is
    /// the entry point, so it is exempt from needing an inbound link.
    @Test func everyPageIsReachableFromAnotherPage() throws {
        let all = try pages()
        let known = Dictionary(uniqueKeysWithValues: all.map { ($0.slug, $0.slug) })
        var linked = Set<String>()
        for page in all {
            for link in WikiLinkParser.links(in: page.source) {
                if let target = WikiLinkParser.resolve(link, in: known), target != page.slug {
                    linked.insert(target)
                }
            }
        }
        let orphans = all.map(\.slug).filter { $0 != "home" && !linked.contains($0) }
        #expect(orphans.isEmpty, "unreachable wiki pages: \(orphans.joined(separator: ", "))")
    }

    /// Frontmatter drives the title and summary the Docs section
    /// shows; a page without it lists as a bare filename.
    @Test func everyPageHasTitleAndSummaryFrontmatter() throws {
        for page in try pages() {
            let fields = Frontmatter.fields(page.source)
            #expect(fields["title"]?.isEmpty == false, "\(page.slug): no title")
            #expect(fields["summary"]?.isEmpty == false, "\(page.slug): no summary")
        }
    }
}
