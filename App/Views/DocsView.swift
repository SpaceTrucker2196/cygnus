import SwiftUI
import CygnusKit

// Browse and edit the repo's agent docs: a tree grouped by kind on the
// left, an edit/preview/split editor on the right. Save writes to disk
// atomically; an optional commit stages just this file. LEDGER.md is
// preview-only.

struct DocsView: View {
    @Environment(WorkspaceStore.self) private var store
    let repoID: UUID

    private var state: FactoryState { store.factoryState(for: repoID) }

    var body: some View {
        LoadableContent(state: state.docs, retry: { store.refresh(.docs, for: repoID) }) { tree in
            if tree.isEmpty {
                ContentUnavailableView("No Docs", systemImage: "doc.text",
                    description: Text("No agent docs, wiki, or markdown found in this repo."))
            } else {
                HSplitView {
                    DocTreeView(tree: tree, repoID: repoID)
                        .frame(minWidth: 220, idealWidth: 260)
                    DocEditorView(repoID: repoID)
                        .frame(minWidth: 420)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { store.refresh(.docs, for: repoID) } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }
}

private struct DocTreeView: View {
    @Environment(WorkspaceStore.self) private var store
    let tree: DocTree
    let repoID: UUID

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selectedDoc) {
            ForEach(tree.sections) { section in
                Section(section.kind.title) {
                    ForEach(section.entries) { entry in
                        HStack(spacing: 6) {
                            Text(entry.name)
                            if entry.policy != .editable {
                                Image(systemName: "lock")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .tag(entry.path)
                    }
                }
            }
        }
    }
}

struct DocEditorView: View {
    @Environment(WorkspaceStore.self) private var store
    let repoID: UUID

    @State private var doc: DocFile?
    @State private var draft = ""
    @State private var original = ""
    @State private var mode: Mode = .preview
    @State private var showCommit = false
    @State private var commitMessage = ""
    @State private var busy = false
    @State private var error: String?

    enum Mode: String, CaseIterable { case edit = "Edit", preview = "Preview", split = "Split" }

    private var isDirty: Bool { draft != original }
    private var editable: Bool { doc?.policy == .editable }

    var body: some View {
        Group {
            if let doc {
                editor(doc)
            } else if store.selectedDoc != nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Select a Document", systemImage: "doc.text",
                    description: Text("Pick a doc to read or edit."))
            }
        }
        .task(id: store.selectedDoc) { await load() }
        .toolbar { editorToolbar }
        .alert("Save failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .sheet(isPresented: $showCommit) { commitSheet }
    }

    private var toggleHandler: ((ChecklistItem) -> Void)? {
        editable ? { toggle($0) } : nil
    }

    @ViewBuilder private func editor(_ doc: DocFile) -> some View {
        switch (mode, editable) {
        case (.preview, _), (_, false):
            ScrollView { MarkdownRenderView(source: draft, onToggle: toggleHandler).padding(18) }
        case (.edit, true):
            sourceEditor
        case (.split, true):
            HSplitView {
                sourceEditor
                ScrollView { MarkdownRenderView(source: draft, onToggle: { toggle($0) }).padding(18) }
            }
        }
    }

    private var sourceEditor: some View {
        TextEditor(text: $draft)
            .font(.body.monospaced())
            .padding(6)
    }

    @ToolbarContentBuilder private var editorToolbar: some ToolbarContent {
        if let doc, editable {
            ToolbarItem {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
            }
            ToolbarItem {
                Button("Save") { Task { await save(commit: nil) } }
                    .disabled(!isDirty || busy)
            }
            ToolbarItem {
                Button("Commit…") { commitMessage = defaultMessage(doc); showCommit = true }
                    .disabled(!isDirty || busy)
            }
        } else if doc != nil {
            ToolbarItem { StatusBadge(status: .neutral, text: "Read-only") }
        }
    }

    private var commitSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Commit Document").font(.headline)
            Text("Stages only this file and commits. No push.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Commit message", text: $commitMessage, axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showCommit = false }
                Button("Commit") { showCommit = false; Task { await save(commit: DocCommit(message: commitMessage)) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(commitMessage.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 420)
    }

    // MARK: - Actions

    private func load() async {
        guard let path = store.selectedDoc else { doc = nil; return }
        doc = nil
        guard let loaded = await store.readDoc(path, for: repoID) else { return }
        doc = loaded
        draft = loaded.content
        original = loaded.content
        mode = loaded.policy == .editable ? .preview : .preview
    }

    private func save(commit: DocCommit?) async {
        guard let path = store.selectedDoc else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await store.saveDoc(path, content: draft, commit: commit, for: repoID)
            original = draft
        } catch {
            self.error = WorkspaceStore.describe(error)
        }
    }

    private func toggle(_ item: ChecklistItem) {
        let md = MarkdownDocument(source: draft)
        draft = md.settingMark(item.mark.next, atLine: item.lineIndex)
    }

    private func defaultMessage(_ doc: DocFile) -> String {
        "docs: update \((doc.path as NSString).lastPathComponent)"
    }
}

#if DEBUG
#Preview {
    let store = WorkspaceStore.previewFactory()
    var s = store.factoryState(for: store.previewRepoID)
    s.docs = .loaded(DocTree(sections: FixtureDocsProvider.group(
        FixtureDocsProvider.sampleFiles.keys.sorted().map {
            DocEntry(path: $0, name: ($0 as NSString).lastPathComponent,
                     kind: FactoryDocScan.kind(forPath: $0),
                     policy: FactoryDocScan.policy(forPath: $0))
        })))
    store.testInjectFactory(s, to: store.previewRepoID)
    return DocsView(repoID: store.previewRepoID).environment(store).frame(width: 820, height: 520)
}
#endif
