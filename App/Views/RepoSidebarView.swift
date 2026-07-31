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
            VStack(spacing: 6) {
                MemoryMeterView(governor: store.memory)
                HStack {
                    Button {
                        addRepository()
                    } label: {
                        Label("Add Repository", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("sidebar.addRepository")
                    .accessibilityHint("Choose a repository folder to analyze")
                    Spacer()
                }
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

/// Live process-memory meter against the hard cap. Turns amber as the
/// governor starts shedding the live preview, red at the ceiling.
struct MemoryMeterView: View {
    let governor: MemoryGovernor

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "memorychip")
                    .font(.caption2)
                Text(governor.summary)
                    .font(.caption2)
                    .monospacedDigit()
                Spacer()
            }
            .foregroundStyle(tint)
            ProgressView(value: governor.fraction)
                .progressViewStyle(.linear)
                .tint(tint)
        }
        .help("Memory usage against the \(governor.summary.split(separator: "/").last ?? "") hard limit")
        .accessibilityElement()
        .accessibilityLabel("Memory usage")
        .accessibilityValue(governor.summary + (governor.isCritical ? ", at limit"
            : governor.isHigh ? ", high" : ""))
        // Post-launch side effect on purpose: starting the sampler in
        // WorkspaceStore.init (App.init time) suppressed window
        // creation on this OS.
        .task { governor.startSampling() }
    }

    private var tint: Color {
        if governor.isCritical { return .red }
        if governor.isHigh { return .orange }
        return .secondary
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
        // children: .ignore collapses the row into one element, so the
        // name is no longer a static text anything can query. The
        // identifier is the stable handle for UI tests; the label is
        // for VoiceOver and free to change wording.
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("sidebar.repo.\(repo.displayName)")
        .accessibilityLabel(repo.displayName)
        .accessibilityValue(statusDescription)
    }

    private var statusDescription: String {
        switch store.states[repo.id] {
        case .analyzing: "analyzing"
        case .ready: "analyzed"
        case .failed: "failed"
        case .needsRelink: "folder not found"
        case .idle, nil: "not analyzed"
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
        case .needsRelink:
            Image(systemName: "questionmark.folder.fill").foregroundStyle(.orange)
        case .idle, nil:
            Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        }
    }
}
