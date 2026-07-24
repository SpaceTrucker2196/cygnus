import SwiftUI
import CygnusKit

// The production-order work queue: a filterable list of GitHub issues
// with a detail pane (body, labels, linked closing commits). Read-only.

struct IssuesView: View {
    @Environment(WorkspaceStore.self) private var store
    let repoID: UUID

    private var state: FactoryState { store.factoryState(for: repoID) }

    var body: some View {
        LoadableContent(state: state.issues, retry: { store.refresh(.issues, for: repoID) }) { issues in
            if issues.isEmpty {
                ContentUnavailableView("No Issues", systemImage: "checklist",
                    description: Text("No open or closed issues on this repo."))
            } else {
                HSplitView {
                    IssuesListView(issues: issues, repoID: repoID)
                        .frame(minWidth: 260, idealWidth: 320)
                    IssueDetailPane(issues: issues, repoID: repoID)
                        .frame(minWidth: 360)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { store.refresh(.issues, for: repoID) } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }
}

private struct IssuesListView: View {
    @Environment(WorkspaceStore.self) private var store
    let issues: [Issue]
    let repoID: UUID
    @State private var filter: Filter = .orders
    @State private var search = ""

    enum Filter: String, CaseIterable { case orders = "Orders", open = "Open", all = "All" }

    private var filtered: [Issue] {
        issues.filter { issue in
            switch filter {
            case .orders: return issue.isProductionOrder
            case .open: return issue.state == .open
            case .all: return true
            }
        }.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            Picker("Filter", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).padding(8)

            List(filtered, selection: $store.selectedOrder) { issue in
                IssueRow(issue: issue).tag(issue.number)
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Filter issues")
        }
        .onChange(of: store.selectedOrder) { _, new in
            if let new { store.loadIssueDetail(new, for: repoID) }
        }
    }
}

private struct IssueRow: View {
    let issue: Issue
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: issue.state == .open ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(issue.state == .open ? .green : .purple)
                .font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title).lineLimit(2).font(.callout)
                HStack(spacing: 4) {
                    Text("#\(issue.number)").font(.caption2).foregroundStyle(.secondary)
                    ForEach(issue.labels.prefix(2)) { label in
                        LabelChip(label: label)
                    }
                }
            }
        }
    }
}

private struct LabelChip: View {
    let label: IssueLabel
    var body: some View {
        Text(label.name)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color(hex: label.color).opacity(0.25), in: Capsule())
    }
}

private struct IssueDetailPane: View {
    @Environment(WorkspaceStore.self) private var store
    let issues: [Issue]
    let repoID: UUID

    private var selected: Issue? {
        guard let number = store.selectedOrder else { return nil }
        return issues.first { $0.number == number }
    }

    var body: some View {
        if let issue = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(issue)
                    Divider()
                    MarkdownRenderView(source: issue.body)
                    if !issue.comments.isEmpty {
                        Divider()
                        commentsSection(issue)
                    }
                    closingCommits(issue)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Select an Order", systemImage: "sidebar.right",
                description: Text("Pick an issue to see its goal and acceptance criteria."))
        }
    }

    private func header(_ issue: Issue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(issue.title).font(.title2.weight(.semibold))
            HStack(spacing: 6) {
                StatusBadge(status: issue.state == .open ? .running : .success,
                            text: issue.state == .open ? "Open" : "Closed")
                Text("#\(issue.number) · \(issue.author)").font(.caption).foregroundStyle(.secondary)
            }
            if !issue.labels.isEmpty {
                HStack { ForEach(issue.labels) { LabelChip(label: $0) } }
            }
        }
    }

    private func commentsSection(_ issue: Issue) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Comments").font(.headline)
            ForEach(issue.comments) { comment in
                VStack(alignment: .leading, spacing: 4) {
                    Text(comment.author).font(.caption.weight(.semibold))
                    MarkdownRenderView(source: comment.body)
                }
                .padding(10)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder private func closingCommits(_ issue: Issue) -> some View {
        let commits = (store.factoryState(for: repoID).commits.value ?? [])
            .filter { $0.closesIssues.contains(issue.number) }
        if !commits.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Closed by").font(.headline)
                ForEach(commits) { commit in
                    HStack(spacing: 6) {
                        Text(commit.shortSha).font(.caption.monospaced()).foregroundStyle(.blue)
                        Text(commit.subject).font(.caption).lineLimit(1)
                    }
                }
            }
        }
    }
}

// Hex color helper for GitHub label colors.
extension Color {
    init(hex: String) {
        let s = Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
        var rgb: UInt64 = 0
        s.scanHexInt64(&rgb)
        self.init(.sRGB,
                  red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}

#if DEBUG
#Preview {
    let store = WorkspaceStore.previewFactory()
    store.selectedOrder = 48
    return IssuesView(repoID: store.previewRepoID).environment(store).frame(width: 820, height: 500)
}
#endif
