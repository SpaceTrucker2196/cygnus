import SwiftUI
import CygnusKit

// Shared plumbing for the ops sections: the Loadable → view mapping
// (idle/loading/failed/empty/content) so each section body stays small,
// plus a fixture-backed store for #Previews.

/// Render a `Loadable<T>` with standard idle/loading/failed states and
/// a caller-supplied content builder. `retry` powers the failure state.
struct LoadableContent<Value: Sendable & Equatable, Content: View>: View {
    let state: Loadable<Value>
    var retry: (() -> Void)?
    @ViewBuilder var content: (Value) -> Content

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).font(.callout)
            } actions: {
                if let retry { Button("Retry", action: retry) }
            }
        case .loaded(let value):
            content(value)
        }
    }
}

/// A card container matching the app's material chrome.
struct OpsCard<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Label {
                    Text(title).font(.subheadline.weight(.semibold))
                } icon: {
                    if let systemImage { Image(systemName: systemImage) }
                }
                .foregroundStyle(.secondary)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

#if DEBUG
extension WorkspaceStore {
    /// A store pre-seeded with a fixture factory for previews.
    @MainActor static func previewFactory() -> WorkspaceStore {
        let dir = FileManager.default.temporaryDirectory
        let store = WorkspaceStore(
            engine: FixtureGraphEngine(),
            persistence: WorkspacePersistence(fileURL: dir.appendingPathComponent("pv.json")),
            factory: FixtureFactoryProvider(),
            docs: FixtureDocsProvider())
        let repo = RegisteredRepo(displayName: "sloth", pathHint: dir.path, bookmark: Data())
        store.testInject(repo: repo)
        var state = FactoryState()
        state.capabilities = .loaded(.sample)
        state.issues = .loaded(Issue.samples)
        state.runs = .loaded(WorkflowRun.samples)
        state.commits = .loaded(CommitInfo.samples)
        state.metrics = .loaded(MetricsRow.samples)
        state.ledger = .loaded(LedgerRow.samples)
        state.converge = .loaded(.sample)
        store.testInjectFactory(state, to: repo.id)
        store.selectedRepo = repo.id
        return store
    }

    @MainActor var previewRepoID: UUID { repos.first!.id }
}
#endif
