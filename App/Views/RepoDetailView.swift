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
        case .ready:
            OutlineContainerView()
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
