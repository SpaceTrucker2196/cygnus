import SwiftUI
import CygnusKit

// The 3D container: projection, progress, and the legend that keeps the
// metaphor honest.
//
// A molecule *is* a 2D group: this uses `GraphScene.clusters(grouping:)`,
// the same function the Flat view uses, so the two can never disagree
// about what a group is. The picker is local because the Flat view's is
// too — sharing the selection would be an improvement, but duplicating
// the *definition* of a group would make this a second model rather than
// another projection of the same one.

struct MolecularGraphView: View {
    @Environment(WorkspaceStore.self) private var store
    let snapshot: GraphSnapshot

    @State private var progress: Float = 0
    @State private var grouping: GraphScene.Grouping = .area

    private var scene: MolecularScene {
        let graph: GraphScene
        switch store.graphContent {
        case .code: graph = GraphScene.dependencies(from: snapshot,
                                                    showExternal: store.showExternalModules)
        case .callers: graph = GraphScene.callers(from: snapshot)
        case .symbols: graph = GraphScene.symbols(from: snapshot)
        case .build: graph = GraphScene.build(from: snapshot)
        }
        return MolecularScene(scene: graph, grouping: grouping)
    }

    var body: some View {
        let molecular = scene
        Group {
            if molecular.isEmpty {
                ContentUnavailableView("Nothing to chart",
                                       systemImage: "atom",
                                       description: Text("This content mode has no nodes yet."))
            } else {
                MolecularMetalView(scene: molecular) { progress = $0 }
                    .overlay(alignment: .topLeading) { legend(molecular) }
                    .overlay(alignment: .bottom) { assembling }
                    .toolbar {
                        ToolbarItem {
                            Picker("Group", selection: $grouping) {
                                ForEach(GraphScene.Grouping.allCases, id: \.self) {
                                    Text($0.rawValue).tag($0)
                                }
                            }
                            .accessibilityLabel("Grouping")
                        }
                    }
            }
        }
    }

    /// Says what the picture means. A molecular view is only legible if
    /// the viewer knows that distance is coupling and size is fan-in.
    private func legend(_ molecular: MolecularScene) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(molecular.molecules.count) groups · \(molecular.atoms.count) nodes")
                .font(.caption.weight(.medium))
            Text("size = connections · thick bonds stay inside a group")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("drag to orbit · scroll to zoom")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }

    /// Progress rather than a spinner: the scene is already on screen
    /// and visibly assembling, so this says how much is left, not that
    /// something is happening.
    @ViewBuilder private var assembling: some View {
        if progress < 1 {
            ProgressView(value: Double(progress))
                .progressViewStyle(.linear)
                .frame(width: 180)
                .padding(8)
                .background(.regularMaterial, in: Capsule())
                .padding(12)
                .transition(.opacity)
        }
    }
}
