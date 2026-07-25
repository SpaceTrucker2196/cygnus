import SwiftUI
import CygnusKit

// Selected-entity details: identity, source anchor, and clickable
// relationships — graph-walking from the inspector.

struct EntityInspectorView: View {
    @Environment(WorkspaceStore.self) private var store

    @State private var source: SourcePreview?

    var body: some View {
        if let node = store.selectedNodeValue, let index = store.currentIndex {
            VSplitView {
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
                    if isTestClass(node) {
                        Section("Coverage") {
                            if store.attributingTest == node.label {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Running \(node.label)…").font(.caption)
                                }
                            } else {
                                Button {
                                    store.attributeCoverage(testClass: node.label)
                                } label: {
                                    Label("Show coverage from this test",
                                          systemImage: "scope")
                                }
                                .disabled(store.attributingTest != nil)
                                .help("Runs only this test class with coverage; graph halos switch to what it exercises")
                            }
                        }
                    }
                    EdgeSection(title: "Outgoing",
                                edges: index.outgoing[node.id] ?? [],
                                endpoint: \.to, index: index)
                    EdgeSection(title: "Incoming",
                                edges: index.incoming[node.id] ?? [],
                                endpoint: \.from, index: index)
                }
                .frame(minHeight: 160)
                if node.path != nil {
                    // The code pane owns all remaining split space and
                    // grows with the pane as the divider or window
                    // moves.
                    codePane(node: node)
                        .frame(minHeight: 120, maxHeight: .infinity)
                }
            }
            .task(id: node.id) {
                source = nil
                guard let path = node.path, let repo = store.selectedRepo else { return }
                source = await store.loadSource(path: path, for: repo)
            }
        } else {
            ContentUnavailableView("No Selection", systemImage: "cursorarrow.rays",
                                   description: Text("Select an entity to inspect it."))
        }
    }

    @ViewBuilder private func codePane(node: GraphSnapshot.Node) -> some View {
        if let source {
            CodePreviewView(preview: source, highlightLine: node.line)
        } else {
            ContentUnavailableView {
                Label("Loading Source…", systemImage: "doc.text")
            }
            .symbolVariant(.none)
        }
    }

    private func shortKind(_ kind: String) -> String {
        kind.split(separator: ":").last.map(String.init) ?? kind
    }

    /// A type declared in test code whose name follows the test-class
    /// convention — the unit swift test's --filter accepts.
    private func isTestClass(_ node: GraphSnapshot.Node) -> Bool {
        node.kind.hasSuffix(":type") && GraphScene.isTest(node)
            && (node.label.hasSuffix("Tests") || node.label.hasSuffix("Test"))
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
