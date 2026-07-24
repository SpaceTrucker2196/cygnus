import SwiftUI
import Charts
import CygnusKit

// At-a-glance factory status for the selected repo: production-order
// counts, latest CI, recent converge throughput, and token spend.

struct DashboardView: View {
    @Environment(WorkspaceStore.self) private var store
    let repoID: UUID

    private var state: FactoryState { store.factoryState(for: repoID) }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)],
                      alignment: .leading, spacing: 14) {
                OrdersSummaryCard(issues: state.issues)
                CIStatusCard(runs: state.runs)
                ConvergeCard(metrics: state.metrics)
                TokenSpendCard(ledger: state.ledger)
                RecentCommitsCard(commits: state.commits)
            }
            .padding(16)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .topTrailing) { refreshButton }
        .overlay { if notAFactory { notFactoryOverlay } }
    }

    private var notAFactory: Bool {
        if case .loaded(let caps) = state.capabilities {
            return !caps.github && !caps.hasMetrics && !caps.hasConverge && !caps.hasDocs
        }
        return false
    }

    private var notFactoryOverlay: some View {
        ContentUnavailableView(
            "Not a Factory Repo",
            systemImage: "building.2",
            description: Text("No GitHub remote or dark-factory files detected. The Code Graph section still works on any repo."))
            .background(.background)
    }

    private var refreshButton: some View {
        Button { store.ensureCapabilities(repoID)
            for dataset in FactoryDataset.allCases where dataset != .docs { store.refresh(dataset, for: repoID) }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .padding(12)
    }
}

// MARK: - Cards

private struct OrdersSummaryCard: View {
    let issues: Loadable<[Issue]>
    var body: some View {
        OpsCard(title: "Production Orders", systemImage: "checklist") {
            if let issues = issues.value {
                let open = issues.filter { $0.state == .open }.count
                let orders = issues.filter(\.isProductionOrder).count
                HStack(spacing: 24) {
                    Stat(value: "\(open)", label: "Open")
                    Stat(value: "\(issues.count - open)", label: "Closed")
                    Stat(value: "\(orders)", label: "Orders")
                }
            } else { CardPlaceholder(state: issues) }
        }
    }
}

private struct CIStatusCard: View {
    let runs: Loadable<[WorkflowRun]>
    var body: some View {
        OpsCard(title: "Latest CI", systemImage: "arrow.trianglehead.branch") {
            if let runs = runs.value {
                if let latest = runs.first {
                    VStack(alignment: .leading, spacing: 6) {
                        StatusBadge(status: latest.factoryStatus)
                        Text(latest.name).font(.callout.weight(.medium))
                        Text("\(latest.headBranch) · \(latest.event)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No runs").foregroundStyle(.secondary)
                }
            } else { CardPlaceholder(state: runs) }
        }
    }
}

private struct ConvergeCard: View {
    let metrics: Loadable<[MetricsRow]>
    var body: some View {
        OpsCard(title: "Recent Converge", systemImage: "arrow.triangle.2.circlepath") {
            if let metrics = metrics.value {
                if metrics.isEmpty {
                    Text("No METRICS.md").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(metrics.suffix(4).reversed()) { row in
                            HStack {
                                Text(row.issue.map { "#\($0)" } ?? row.commit)
                                    .font(.caption.monospaced())
                                Spacer()
                                if let iters = row.convergeIters {
                                    Text("\(iters)×").font(.caption).foregroundStyle(.secondary)
                                }
                                Image(systemName: row.shipped == true ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(row.shipped == true ? .green : .secondary)
                                    .font(.caption)
                            }
                        }
                    }
                }
            } else { CardPlaceholder(state: metrics) }
        }
    }
}

private struct TokenSpendCard: View {
    let ledger: Loadable<[LedgerRow]>
    var body: some View {
        OpsCard(title: "Token Spend", systemImage: "dollarsign.circle") {
            if let ledger = ledger.value {
                let rows = ledger.suffix(30).enumerated().map { IndexedCost(index: $0.offset, cost: $0.element.costUSD ?? 0) }
                let total = ledger.compactMap(\.costUSD).reduce(0, +)
                VStack(alignment: .leading, spacing: 8) {
                    Text(total, format: .currency(code: "USD"))
                        .font(.title2.weight(.semibold)).monospacedDigit()
                    if rows.count > 1 {
                        Chart(rows) { row in
                            LineMark(x: .value("n", row.index), y: .value("cost", row.cost))
                                .foregroundStyle(.tint)
                        }
                        .chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 44)
                    }
                }
            } else { CardPlaceholder(state: ledger) }
        }
    }
    private struct IndexedCost: Identifiable { let index: Int; let cost: Double; var id: Int { index } }
}

private struct RecentCommitsCard: View {
    let commits: Loadable<[CommitInfo]>
    var body: some View {
        OpsCard(title: "Recent Ships", systemImage: "shippingbox") {
            if let commits = commits.value {
                let ships = commits.filter { !$0.ledgerMarker }.prefix(5)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(ships) { commit in
                        HStack(spacing: 6) {
                            Text(commit.shortSha).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(commit.subject).font(.caption).lineLimit(1)
                            if let n = commit.closesIssues.first {
                                Text("#\(n)").font(.caption2).foregroundStyle(.blue)
                            }
                        }
                    }
                }
            } else { CardPlaceholder(state: commits) }
        }
    }
}

// MARK: - Small pieces

private struct Stat: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct CardPlaceholder<T: Sendable & Equatable>: View {
    let state: Loadable<T>
    var body: some View {
        if let message = state.errorMessage {
            Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

#if DEBUG
#Preview {
    let store = WorkspaceStore.previewFactory()
    return DashboardView(repoID: store.previewRepoID).environment(store).frame(width: 700, height: 500)
}
#endif
