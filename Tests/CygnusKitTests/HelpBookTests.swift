import Testing
import Foundation
@testable import CygnusKit

// The help reference is only useful if it is actually there. These
// tests catch the packaging failure the UI would otherwise show as a
// blank pane, and the drift where a topic is listed but never written.

@Suite struct HelpBookTests {
    @Test func everyTopicHasContent() {
        for topic in HelpBook.topics {
            let markdown = HelpBook.markdown(for: topic.id)
            #expect(markdown != nil, "no bundled markdown for '\(topic.id)'")
            #expect((markdown?.count ?? 0) > 200,
                    "help topic '\(topic.id)' is suspiciously short")
        }
    }

    /// Each file opens with the heading the reader expects to see —
    /// a renamed topic with a stale heading reads as a bug.
    @Test func everyTopicStartsWithAHeading() {
        for topic in HelpBook.topics {
            let first = HelpBook.markdown(for: topic.id)?
                .split(separator: "\n", omittingEmptySubsequences: true).first ?? ""
            #expect(first.hasPrefix("# "), "'\(topic.id)' does not open with an H1")
        }
    }

    @Test func topicIDsAreUniqueAndLookUp() {
        #expect(Set(HelpBook.topics.map(\.id)).count == HelpBook.topics.count)
        for topic in HelpBook.topics {
            #expect(HelpBook.topic(id: topic.id) == topic)
        }
        #expect(HelpBook.topic(id: "no-such-topic") == nil)
    }

    /// Every bundled file is reachable from the topic list — a page
    /// nobody can navigate to is the same as a missing page.
    @Test func noOrphanedHelpFiles() throws {
        let directory = try #require(
            Bundle.module.url(forResource: "Help", withExtension: nil),
            "Help resources missing from the bundle")
        let bundled = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .map { $0.deletingPathExtension().lastPathComponent }
        #expect(Set(bundled) == Set(HelpBook.topics.map(\.id)))
    }

    @Test func searchMatchesTitleSummaryAndBody() {
        #expect(HelpBook.search("").count == HelpBook.topics.count)
        #expect(HelpBook.search("   ").count == HelpBook.topics.count)
        // Title.
        #expect(HelpBook.search("coverage").contains { $0.id == "coverage" })
        // Body only: "blast radius" is prose, not a title or summary.
        let blast = HelpBook.search("blast radius")
        #expect(blast.contains { $0.id == "visual-grammar" })
        #expect(!blast.isEmpty)
        // Case-insensitive.
        #expect(HelpBook.search("CYCLES").isEmpty == false)
        #expect(HelpBook.search("zzzznotinanytopic").isEmpty)
    }
}
