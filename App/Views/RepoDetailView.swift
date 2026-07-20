import SwiftUI
import CygnusKit

struct RepoDetailView: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        switch store.currentState {
        case nil:
            ContentUnavailableView(
                "No Repository Selected",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("Cygnus builds a knowledge graph from repository evidence."))
        case .idle:
            ContentUnavailableView {
                Label("Not Analyzed", systemImage: "circle.dotted")
            } actions: {
                Button("Run Analysis") {
                    if let id = store.selectedRepo { store.analyze(id) }
                }
                .buttonStyle(.borderedProminent)
            }
        case .analyzing(let phase, let progress):
            AnalysisProgressView(phase: phase, progress: progress)
        case .failed(let message):
            ContentUnavailableView {
                Label("Analysis Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).font(.caption).lineLimit(4)
            } actions: {
                Button("Retry") {
                    if let id = store.selectedRepo { store.analyze(id) }
                }
            }
        case .needsRelink:
            ContentUnavailableView {
                Label("Folder Not Found", systemImage: "questionmark.folder")
            } description: {
                Text("The repository folder moved or was deleted. Locate it to continue.")
            } actions: {
                Button("Locate Folder…") { relink() }
                    .buttonStyle(.borderedProminent)
            }
        case .ready(let snapshot):
            ReadyContentView(snapshot: snapshot)
        }
    }

    private func relink() {
        guard let id = store.selectedRepo else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Locate the repository folder"
        if panel.runModal() == .OK, let url = panel.url {
            store.relink(id, to: url)
        }
    }
}

struct ReadyContentView: View {
    @Environment(WorkspaceStore.self) private var store
    let snapshot: GraphSnapshot

    var body: some View {
        @Bindable var store = store
        Group {
            switch store.viewMode {
            case .outline:
                OutlineContainerView()
            case .flat, .space:
                if store.searchText.isEmpty {
                    DependencyGraphView(snapshot: snapshot, mode: store.viewMode)
                } else {
                    OutlineContainerView()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $store.viewMode) {
                    ForEach(WorkspaceStore.ViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Menu {
                    Toggle("Show External Modules", isOn: $store.showExternalModules)
                    Text("Apple frameworks and language runtimes are never charted.")
                } label: {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
    }
}

struct DependencyGraphView: View {
    @Environment(WorkspaceStore.self) private var store
    let snapshot: GraphSnapshot
    let mode: WorkspaceStore.ViewMode

    var body: some View {
        let scene = GraphScene.dependencies(from: snapshot,
                                            showExternal: store.showExternalModules)
        if scene.nodes.isEmpty {
            ContentUnavailableView(
                "No Internal Imports",
                systemImage: "point.3.filled.connected.trianglepath.dotted",
                description: Text("Only project-internal imports are charted. " +
                                  "Try Filters → Show External Modules."))
        } else if mode == .space {
            Orbit3DView(scene: scene)
        } else {
            FlatGraphView(scene: scene)
        }
    }
}

struct AnalysisProgressView: View {
    @Environment(WorkspaceStore.self) private var store
    let phase: String
    let progress: Double?

    var body: some View {
        VStack(spacing: 12) {
            if let progress {
                ProgressView(value: progress) { Text(phase.capitalized) }
                    .frame(maxWidth: 280)
            } else {
                ProgressView { Text(phase.capitalized) }
            }
            Button("Cancel") {
                if let id = store.selectedRepo { store.cancel(id) }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
