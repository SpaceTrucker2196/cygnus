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
                    FunctionsSection(node: node, index: index)
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

/// The selected node's member functions, listed with their coverage
/// (when known) and selectable — the "functions panel" for a class.
struct FunctionsSection: View {
    @Environment(WorkspaceStore.self) private var store
    let node: GraphSnapshot.Node
    let index: SnapshotIndex

    private var functions: [GraphSnapshot.Node] {
        (index.outgoing[node.id] ?? [])
            .filter { $0.kind == "core:declares" }
            .compactMap { index.byID[$0.to] }
            .filter { $0.kind.hasSuffix(":function") }
            .sorted { ($0.line ?? 0) < ($1.line ?? 0) }
    }

    var body: some View {
        let functions = functions
        if !functions.isEmpty {
            Section("Functions (\(functions.count))") {
                ForEach(functions) { function in
                    Button {
                        store.selectedNode = function.id
                    } label: {
                        HStack(spacing: 8) {
                            coverageDot(for: function)
                            Text(function.label)
                                .font(.callout.monospaced())
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if let line = function.line {
                                Text("\(line)").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Function \(function.label)")
                    .accessibilityValue(coverageDescription(for: function))
                    .accessibilityHint("Select to focus")
                }
            }
        }
    }

    @ViewBuilder private func coverageDot(for function: GraphSnapshot.Node) -> some View {
        let report = store.liveCoverage ?? store.attributedCoverage?.report
        if let fraction = report?.functionFraction(path: function.path, line: function.line) {
            Circle()
                .fill(Color(hue: 0.33 * fraction, saturation: 0.85, brightness: 0.85))
                .frame(width: 8, height: 8)
                .help("\(Int(fraction * 100))% covered")
        } else {
            Image(systemName: "function").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func coverageDescription(for function: GraphSnapshot.Node) -> String {
        let report = store.liveCoverage ?? store.attributedCoverage?.report
        if let fraction = report?.functionFraction(path: function.path, line: function.line) {
            return "\(Int(fraction * 100)) percent covered"
        }
        return ""
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
                        let relation = edge.kind.split(separator: ":").last.map(String.init) ?? ""
                        Button {
                            store.selectedNode = other.id
                        } label: {
                            HStack {
                                Text(relation).font(.caption).foregroundStyle(.secondary)
                                NodeRowView(node: other)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(relation) \(other.label)")
                        .accessibilityHint("Select to navigate")
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
