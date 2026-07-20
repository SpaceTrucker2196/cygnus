import SwiftUI
import CygnusKit

// Selected-entity details: identity, source anchor, and clickable
// relationships — graph-walking from the inspector.

struct EntityInspectorView: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        if let node = store.selectedNodeValue, let index = store.currentIndex {
            List {
                Section {
                    LabeledContent("Name", value: node.label)
                    LabeledContent("Kind", value: shortKind(node.kind))
                    if let path = node.path {
                        LabeledContent("Path") {
                            Text(path)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    NodeRowView(node: node)
                        .font(.headline)
                }
                EdgeSection(title: "Outgoing",
                            edges: index.outgoing[node.id] ?? [],
                            endpoint: \.to, index: index)
                EdgeSection(title: "Incoming",
                            edges: index.incoming[node.id] ?? [],
                            endpoint: \.from, index: index)
            }
        } else {
            ContentUnavailableView("No Selection", systemImage: "cursorarrow.rays",
                                   description: Text("Select an entity to inspect it."))
        }
    }

    private func shortKind(_ kind: String) -> String {
        kind.split(separator: ":").last.map(String.init) ?? kind
    }
}

struct EdgeSection: View {
    @Environment(WorkspaceStore.self) private var store
    let title: String
    let edges: [GraphSnapshot.Edge]
    let endpoint: KeyPath<GraphSnapshot.Edge, String>
    let index: SnapshotIndex

    var body: some View {
        if !edges.isEmpty {
            Section("\(title) (\(edges.count))") {
                ForEach(Array(edges.prefix(100).enumerated()), id: \.offset) { _, edge in
                    if let other = index.byID[edge[keyPath: endpoint]] {
                        Button {
                            store.selectedNode = other.id
                        } label: {
                            HStack {
                                Text(edge.kind.split(separator: ":").last.map(String.init) ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                NodeRowView(node: other)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                if edges.count > 100 {
                    Text("… and \(edges.count - 100) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
