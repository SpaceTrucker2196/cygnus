import Foundation

// The in-app help reference. Content is markdown bundled with this
// package, so it is editable as prose and testable without launching
// the app — the same reason the rest of the kit is headless.

public struct HelpTopic: Sendable, Equatable, Identifiable {
    /// Resource basename, and the stable id the UI selects by.
    public let id: String
    public let title: String
    /// One line describing what the topic answers, shown under the
    /// title in the topic list and matched by search.
    public let summary: String

    public init(id: String, title: String, summary: String) {
        self.id = id
        self.title = title
        self.summary = summary
    }
}

public enum HelpBook {
    /// Reading order, not alphabetical: concepts before controls,
    /// troubleshooting last.
    public static let topics: [HelpTopic] = [
        HelpTopic(id: "getting-started", title: "Getting Started",
                  summary: "Add a repository, analyze it, and find your way around."),
        HelpTopic(id: "concepts", title: "How Cygnus Thinks",
                  summary: "The graph is the model; every view is a projection of it."),
        HelpTopic(id: "code-graph", title: "Code Graph",
                  summary: "View modes, content, grouping, and how to drive the graph."),
        HelpTopic(id: "visual-grammar", title: "Visual Grammar",
                  summary: "What every color, size, halo, hull, and arrow means."),
        HelpTopic(id: "coverage", title: "Coverage",
                  summary: "Test coverage on the graph, live, and per-test attribution."),
        HelpTopic(id: "ci-flow", title: "CI Flow",
                  summary: "The build pipeline as a flowchart, and running one."),
        HelpTopic(id: "ops-sections", title: "Dashboard, Workflow, Issues, Docs",
                  summary: "The sections that read your repository directly."),
        HelpTopic(id: "shortcuts", title: "Menus and Shortcuts",
                  summary: "Keyboard shortcuts, gestures, and accessibility."),
        HelpTopic(id: "troubleshooting", title: "Troubleshooting",
                  summary: "Empty views, missing references, and what they mean."),
    ]

    public static func topic(id: String) -> HelpTopic? {
        topics.first { $0.id == id }
    }

    /// Markdown body for a topic. Nil only when the resource is
    /// missing from the bundle — a packaging error, not a user-facing
    /// state, and the tests assert it never happens.
    public static func markdown(for id: String) -> String? {
        guard let url = Bundle.module.url(
            forResource: id, withExtension: "md", subdirectory: "Help")
            ?? Bundle.module.url(forResource: id, withExtension: "md")
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Topics matching `query` by title, summary, or body text.
    /// Empty query returns everything, so the list is never blank
    /// while typing.
    public static func search(_ query: String) -> [HelpTopic] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return topics }
        return topics.filter { topic in
            topic.title.lowercased().contains(needle)
                || topic.summary.lowercased().contains(needle)
                || (markdown(for: topic.id)?.lowercased().contains(needle) ?? false)
        }
    }
}
