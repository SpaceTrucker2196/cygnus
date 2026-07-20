import SwiftUI
import CygnusKit

// The reliable browse path: containment tree + search, selection
// synced with the inspector.

struct OutlineContainerView: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Group {
            if let index = store.currentIndex {
                if store.searchText.isEmpty {
                    OutlineView(index: index)
                } else {
                    SearchResultsView(index: index)
                }
            }
        }
        .searchable(text: $store.searchText, placement: .toolbar,
                    prompt: "Search entities")
    }
}

struct OutlineView: View {
    @Environment(WorkspaceStore.self) private var store
    let index: SnapshotIndex

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selectedNode) {
            OutlineGroup(index.trees, children: \.children) { tree in
                NodeRowView(node: tree.node)
                    .tag(tree.node.id)
            }
        }
    }
}

struct SearchResultsView: View {
    @Environment(WorkspaceStore.self) private var store
    let index: SnapshotIndex

    var body: some View {
        @Bindable var store = store
        List(index.search(store.searchText), selection: $store.selectedNode) { node in
            NodeRowView(node: node, showPath: true)
                .tag(node.id)
        }
    }
}

struct NodeRowView: View {
    let node: GraphSnapshot.Node
    var showPath = false

    var body: some View {
        Label {
            HStack {
                Text(node.label)
                if showPath, let path = node.path {
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } icon: {
            Image(systemName: KindStyle.symbol(for: node.kind))
                .foregroundStyle(KindStyle.color(for: node.kind))
        }
    }
}

enum KindStyle {
    static func symbol(for kind: String) -> String {
        switch kind {
        case "core:repository": "shippingbox"
        case "core:directory": "folder"
        case "core:file": "doc.text"
        case "core:module": "puzzlepiece.extension"
        case "core:type": "t.square"
        case "core:interface": "p.square"
        case "core:enumeration": "e.square"
        case "core:function": "function"
        case "core:variable": "v.square"
        default: "circle"
        }
    }

    static func color(for kind: String) -> Color {
        switch kind {
        case "core:repository": .brown
        case "core:directory": .secondary
        case "core:file": .primary
        case "core:module": .purple
        case "core:type": .blue
        case "core:interface": .teal
        case "core:enumeration": .orange
        case "core:function": .green
        case "core:variable": .gray
        default: .secondary
        }
    }
}
