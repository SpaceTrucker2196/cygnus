import SwiftUI
import CygnusKit

// The build workflow: the converge loop as a stage diagram, and the
// GitHub Actions workflows with their latest run status.

struct WorkflowView: View {
    @Environment(WorkspaceStore.self) private var store
    let repoID: UUID
    @State private var lens: Lens = .converge

    enum Lens: String, CaseIterable { case converge = "Converge", ci = "CI" }

    private var state: FactoryState { store.factoryState(for: repoID) }

    var body: some View {
        content
            .toolbar {
                ToolbarItem {
                    Picker("Lens", selection: $lens) {
                        ForEach(Lens.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                }
                ToolbarItem {
                    Button { store.refresh(lens == .converge ? .converge : .runs, for: repoID) } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch lens {
        case .converge:
            LoadableContent(state: state.converge, retry: { store.refresh(.converge, for: repoID) }) { pipeline in
                if let pipeline {
                    StageDiagramView(pipeline: pipeline)
                } else {
                    ContentUnavailableView("No Converge Loop", systemImage: "arrow.triangle.2.circlepath",
                        description: Text("No converge.md found in agents/ or .claude/commands/."))
                }
            }
        case .ci:
            LoadableContent(state: state.runs, retry: { store.refresh(.runs, for: repoID) }) { runs in
                CIRunsList(runs: runs, repoID: repoID)
            }
        }
    }
}

private struct CIRunsList: View {
    @Environment(WorkspaceStore.self) private var store
    let runs: [WorkflowRun]
    let repoID: UUID

    /// Latest run per workflow name.
    private var latestByWorkflow: [WorkflowRun] {
        var seen = Set<String>()
        return runs.filter { seen.insert($0.name).inserted }
    }

    var body: some View {
        if runs.isEmpty {
            ContentUnavailableView("No CI Runs", systemImage: "arrow.trianglehead.branch",
                description: Text("No GitHub Actions runs found for this repo."))
        } else {
            List {
                Section("Workflows") {
                    ForEach(latestByWorkflow) { run in RunRow(run: run) }
                }
                Section("Recent Runs") {
                    ForEach(runs.prefix(20)) { run in RunRow(run: run, showBranch: true) }
                }
            }
        }
    }
}

private struct RunRow: View {
    let run: WorkflowRun
    var showBranch = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: run.factoryStatus.systemImage)
                .foregroundStyle(run.factoryStatus.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.name).font(.callout)
                if showBranch {
                    Text("\(run.headBranch) · \(run.event) · \(run.headSha.prefix(7))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let url = URL(string: run.url) {
                Link(destination: url) { Image(systemName: "arrow.up.forward.square") }
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#if DEBUG
#Preview {
    let store = WorkspaceStore.previewFactory()
    return WorkflowView(repoID: store.previewRepoID).environment(store).frame(width: 700, height: 460)
}
#endif
