import SwiftUI
import CygnusKit

// S7: the portfolio overview — what "no repo selected" shows instead
// of an empty state. One card per registered repo (CI, open orders,
// spend, analysis state) plus aggregate totals; clicking a card
// selects the repo. Reads the same per-repo factory states the
// dashboard uses, kicking loads for repos not yet touched.

struct PortfolioView: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        if store.repos.isEmpty {
            ContentUnavailableView(
                "No Repositories",
                systemImage: "building.2",
                description: Text("Add a repository to run it as a dark-factory ops dashboard."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PortfolioTotalsRow()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)],
                              alignment: .leading, spacing: 14) {
                        ForEach(store.repos) { repo in
                            PortfolioRepoCard(repo: repo)
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .task {
                // Kick dashboard-grade loads for every repo so the
                // portfolio fills in; each dataset loads only if idle.
                for repo in store.repos {
                    store.selectRepoSection(store.sectionByRepo[repo.id] ?? .dashboard,
                                            for: repo.id)
                }
            }
        }
    }
}

/// Aggregates across every repo with loaded data. Partial by nature —
/// totals count what's loaded, and say so.
private struct PortfolioTotalsRow: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        let states = store.repos.map { store.factoryState(for: $0.id) }
        let spend = states.compactMap { $0.ledger.value }
            .flatMap { $0 }.compactMap(\.costUSD).reduce(0, +)
        let openOrders = states.compactMap { $0.issues.value }
            .flatMap { $0 }.filter { $0.state == .open }.count
        let loadedLedgers = states.filter { $0.ledger.value != nil }.count

        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 2) {
                Text(spend, format: .currency(code: "USD"))
                    .font(.title.weight(.semibold)).monospacedDigit()
                Text("token spend · \(loadedLedgers)/\(store.repos.count) ledgers")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(openOrders)")
                    .font(.title.weight(.semibold)).monospacedDigit()
                Text("open issues").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct PortfolioRepoCard: View {
    @Environment(WorkspaceStore.self) private var store
    let repo: RegisteredRepo

    private var state: FactoryState { store.factoryState(for: repo.id) }

    var body: some View {
        Button {
            store.selectedRepo = repo.id
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(repo.displayName).font(.headline)
                    Spacer()
                    analysisGlyph
                }
                HStack(spacing: 14) {
                    ciBadge
                    if let issues = state.issues.value {
                        Label("\(issues.filter { $0.state == .open }.count)",
                              systemImage: "checklist")
                            .font(.caption)
                    }
                    if let ledger = state.ledger.value {
                        Label {
                            Text(ledger.compactMap(\.costUSD).reduce(0, +),
                                 format: .currency(code: "USD"))
                        } icon: {
                            Image(systemName: "dollarsign.circle")
                        }
                        .font(.caption).monospacedDigit()
                    }
                    Spacer()
                }
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var ciBadge: some View {
        if let runs = state.runs.value, let latest = runs.first {
            StatusBadge(status: latest.factoryStatus)
        } else if state.runs.isLoading {
            ProgressView().controlSize(.mini)
        }
    }

    @ViewBuilder private var analysisGlyph: some View {
        switch store.states[repo.id] {
        case .analyzing: ProgressView().controlSize(.small)
        case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .needsRelink: Image(systemName: "questionmark.folder.fill").foregroundStyle(.orange)
        case .idle, nil: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        }
    }
}
