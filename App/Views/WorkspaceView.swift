import SwiftUI
import CygnusKit

// Single-window workspace shell. Sidebar = registered repos, content =
// graph / analysis status, inspector = selected entity. S1 fills in
// repo registration; this is the S0 skeleton.

struct WorkspaceView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Section("Repositories") {
                    Text("Add a repository to begin")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            ContentUnavailableView(
                "No Repository Selected",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("Cygnus builds a knowledge graph from repository evidence.")
            )
        }
        .navigationTitle("Cygnus")
    }
}

#Preview {
    WorkspaceView()
}
