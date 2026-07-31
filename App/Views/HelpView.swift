import SwiftUI
import CygnusKit

// The Help window: topic list on the left, rendered markdown on the
// right. Content comes from CygnusKit's bundled help book, so the
// prose is unit-tested and this view stays presentation only.

struct HelpView: View {
    @State private var selection: String = HelpBook.topics.first?.id ?? ""
    @State private var query = ""

    private var results: [HelpTopic] { HelpBook.search(query) }

    var body: some View {
        NavigationSplitView {
            List(results, selection: $selection) { topic in
                VStack(alignment: .leading, spacing: 2) {
                    Text(topic.title).font(.headline)
                    Text(topic.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
                .tag(topic.id)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("help.topic.\(topic.id)")
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
            .searchable(text: $query, placement: .sidebar, prompt: "Search help")
            .accessibilityIdentifier("help.topics")
        } detail: {
            HelpTopicDetail(topicID: selection)
        }
        .frame(minWidth: 720, minHeight: 480)
        // A search that filters the selected topic out would otherwise
        // leave the detail pane showing something the list no longer
        // offers.
        .onChange(of: query) {
            guard !results.isEmpty, !results.contains(where: { $0.id == selection }),
                  let first = results.first else { return }
            selection = first.id
        }
    }
}

private struct HelpTopicDetail: View {
    let topicID: String

    var body: some View {
        Group {
            if let markdown = HelpBook.markdown(for: topicID) {
                ScrollView {
                    MarkdownRenderView(source: markdown)
                        .padding(24)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                ContentUnavailableView("Select a topic",
                                       systemImage: "questionmark.circle")
            }
        }
        .navigationTitle(HelpBook.topic(id: topicID)?.title ?? "Cygnus Help")
        .accessibilityIdentifier("help.detail")
    }
}
