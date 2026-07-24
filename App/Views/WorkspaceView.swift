import SwiftUI
import CygnusKit

// Single-window workspace shell. Sidebar = registered repos, content
// = analysis status / outline, inspector = selected entity.

struct WorkspaceView: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        NavigationSplitView {
            RepoSidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            RepoDetailView()
        }
        .navigationTitle(currentRepoName)
    }

    private var currentRepoName: String {
        store.repos.first(where: { $0.id == store.selectedRepo })?.displayName ?? "Cygnus"
    }
}

#Preview {
    WorkspaceView()
        .environment(WorkspaceStore(engine: FixtureGraphEngine(),
                                    persistence: WorkspacePersistence(
                                        fileURL: FileManager.default.temporaryDirectory
                                            .appendingPathComponent("preview-workspace.json"))))
}
