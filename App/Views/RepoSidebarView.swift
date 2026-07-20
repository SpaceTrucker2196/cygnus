import SwiftUI
import AppKit
import CygnusKit

struct RepoSidebarView: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selectedRepo) {
            Section("Repositories") {
                if store.repos.isEmpty {
                    Text("Add a repository to begin")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.repos) { repo in
                    RepoRowView(repo: repo)
                        .tag(repo.id)
                        .contextMenu {
                            Button("Re-analyze") { store.analyze(repo.id) }
                            Button("Reveal in Finder") { reveal(repo) }
                            Divider()
                            Button("Remove", role: .destructive) {
                                store.removeRepository(repo.id)
                            }
                        }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    addRepository()
                } label: {
                    Label("Add Repository", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(8)
        }
    }

    private func addRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a repository folder to analyze"
        if panel.runModal() == .OK, let url = panel.url {
            store.addRepository(at: url)
        }
    }

    private func reveal(_ repo: RegisteredRepo) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: repo.pathHint)
    }
}

struct RepoRowView: View {
    @Environment(WorkspaceStore.self) private var store
    let repo: RegisteredRepo

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading) {
                    Text(repo.displayName)
                    Text(repo.pathHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } icon: {
                Image(systemName: "folder")
            }
            Spacer()
            statusGlyph
        }
    }

    @ViewBuilder private var statusGlyph: some View {
        switch store.states[repo.id] {
        case .analyzing:
            ProgressView().controlSize(.small)
        case .ready:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .idle, nil:
            Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        }
    }
}
