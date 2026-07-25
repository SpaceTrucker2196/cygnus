import SwiftUI
import CygnusKit

// The detail pane. Sidebar picks a repo; a segmented section picker
// switches between the ops sections and the original Code Graph. The
// four ops sections read the factory provider layer; only Code Graph
// consumes the code-analysis state machine.

struct RepoDetailView: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        Group {
            if let repoID = store.selectedRepo {
                section(for: repoID)
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            Picker("Section", selection: sectionBinding(repoID)) {
                                ForEach(RepoSection.allCases, id: \.self) { section in
                                    Label(section.title, systemImage: section.systemImage).tag(section)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    .task(id: repoID) { store.selectRepoSection(store.selectedSection, for: repoID) }
            } else {
                // S7: no selection means the portfolio, not a blank.
                PortfolioView()
            }
        }
    }

    private func sectionBinding(_ id: UUID) -> Binding<RepoSection> {
        Binding(get: { store.selectedSection },
                set: { store.selectRepoSection($0, for: id) })
    }

    @ViewBuilder private func section(for id: UUID) -> some View {
        switch store.selectedSection {
        case .dashboard: DashboardView(repoID: id)
        case .workflow: WorkflowView(repoID: id)
        case .issues: IssuesView(repoID: id)
        case .docs: DocsView(repoID: id)
        case .codeGraph: CodeGraphContainerView()
        }
    }
}

// MARK: - Code Graph (the original analysis surface)

struct CodeGraphContainerView: View {
    @Environment(WorkspaceStore.self) private var store
    @State private var inspectorShown = true

    var body: some View {
        content
            .inspector(isPresented: $inspectorShown) {
                EntityInspectorView()
                    .inspectorColumnWidth(min: 260, ideal: 300)
            }
            .toolbar {
                ToolbarItem {
                    Button { inspectorShown.toggle() } label: {
                        Label("Inspector", systemImage: "sidebar.trailing")
                    }
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch store.currentState {
        case nil:
            ContentUnavailableView(
                "Not Analyzed",
                systemImage: "circle.dotted",
                description: Text("This repository hasn't been analyzed into a knowledge graph yet."))
        case .idle:
            ContentUnavailableView {
                Label("Not Analyzed", systemImage: "circle.dotted")
            } actions: {
                Button("Run Analysis") {
                    if let id = store.selectedRepo { store.analyze(id) }
                }
                .buttonStyle(.borderedProminent)
            }
        case .analyzing(let phase, let progress, let partial):
            if let partial {
                ReadyContentView(snapshot: partial)
                    .overlay(alignment: .bottom) { AnalyzingBadge(phase: phase, progress: progress) }
            } else {
                AnalysisProgressView(phase: phase, progress: progress)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Analysis Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).font(.caption).lineLimit(4)
            } actions: {
                Button("Retry") { if let id = store.selectedRepo { store.analyze(id) } }
            }
        case .needsRelink:
            ContentUnavailableView {
                Label("Folder Not Found", systemImage: "questionmark.folder")
            } description: {
                Text("The repository folder moved or was deleted. Locate it to continue.")
            } actions: {
                Button("Locate Folder…") { relink() }.buttonStyle(.borderedProminent)
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
            case .flat:
                if store.searchText.isEmpty {
                    DependencyGraphView(snapshot: snapshot)
                } else {
                    OutlineContainerView()
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Picker("View", selection: $store.viewMode) {
                    ForEach(WorkspaceStore.ViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            if store.viewMode == .flat {
                ToolbarItem {
                    Picker("Content", selection: $store.graphContent) {
                        ForEach(WorkspaceStore.GraphContent.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .help("Code = file/module dependencies · Symbols = declaration references (needs an index build)")
                }
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

    var body: some View {
        let scene = switch store.graphContent {
        case .code: GraphScene.dependencies(from: snapshot,
                                            showExternal: store.showExternalModules)
        case .symbols: GraphScene.symbols(from: snapshot)
        }
        if scene.nodes.isEmpty {
            emptyState
        } else {
            FlatGraphView(scene: scene)
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch store.graphContent {
        case .code:
            ContentUnavailableView(
                "No Internal Imports",
                systemImage: "point.3.filled.connected.trianglepath.dotted",
                description: Text("Only project-internal imports are charted. " +
                                  "Try Filters → Show External Modules."))
        case .symbols:
            ContentUnavailableView {
                Label("No Symbol References", systemImage: "arrow.triangle.branch")
            } description: {
                Text("Declaration references come from a compiled index store.")
            } actions: {
                Button {
                    if let id = store.selectedRepo { store.buildIndex(for: id) }
                } label: {
                    if store.indexBuilding {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Building…") }
                    } else {
                        Label("Build Index", systemImage: "hammer")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.indexBuilding)
                .help("Runs swift build to emit an index store, then re-analyzes")
            }
        }
    }
}

struct AnalyzingBadge: View {
    @Environment(WorkspaceStore.self) private var store
    let phase: String
    let progress: Double?

    var body: some View {
        HStack(spacing: 10) {
            if let progress {
                ProgressView(value: progress).frame(width: 120)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(phase.capitalized).font(.caption)
            Button("Cancel") { if let id = store.selectedRepo { store.cancel(id) } }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .padding(10)
    }
}

struct AnalysisProgressView: View {
    @Environment(WorkspaceStore.self) private var store
    let phase: String
    let progress: Double?

    var body: some View {
        VStack(spacing: 12) {
            if let progress {
                ProgressView(value: progress) { Text(phase.capitalized) }.frame(maxWidth: 280)
            } else {
                ProgressView { Text(phase.capitalized) }
            }
            Button("Cancel") { if let id = store.selectedRepo { store.cancel(id) } }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
