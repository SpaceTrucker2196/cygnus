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
            // Full-width previews below the stat grid.
            VStack(alignment: .leading, spacing: 14) {
                if let fastlane = state.caps.fastlane {
                    FastlaneCard(info: fastlane)
                }
                if !state.caps.screenshots.isEmpty, let root = store.repoURL(repoID) {
                    ScreenshotsCard(repoRoot: root, screenshots: state.caps.screenshots)
                }
                if let pagesURL = state.caps.pagesURL {
                    PagesPreviewCard(pagesURL: pagesURL)
                }
            }
            .padding([.horizontal, .bottom], 16)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .topTrailing) { refreshButton }
        .overlay { if notAFactory { notFactoryOverlay } }
        .safeAreaInset(edge: .bottom) {
            if needsLedger, !notAFactory {
                InstallFactoryBanner(repoID: repoID)
            }
        }
    }

    private var notAFactory: Bool {
        if case .loaded(let caps) = state.capabilities {
            return !caps.github && !caps.hasMetrics && !caps.hasConverge && !caps.hasDocs
        }
        return false
    }

    /// Capabilities known and no LEDGER.md: the repo is missing the
    /// ledger system (and likely the rest of the factory skeleton).
    private var needsLedger: Bool {
        if case .loaded(let caps) = state.capabilities { return !caps.hasLedger }
        return false
    }

    private var notFactoryOverlay: some View {
        ContentUnavailableView {
            Label("Not a Factory Repo", systemImage: "building.2")
        } description: {
            Text("No GitHub remote or dark-factory files detected. The Code Graph section still works on any repo.")
        } actions: {
            InstallFactoryButton(repoID: repoID)
        }
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

// MARK: - Factory installation

/// Installs the DF_Template skeleton into the repo. Additive only —
/// existing files are never overwritten — so it's safe on partial
/// factories. Confirmation dialog states exactly what will happen.
struct InstallFactoryButton: View {
    @Environment(WorkspaceStore.self) private var store
    let repoID: UUID
    @State private var confirming = false
    @State private var installing = false
    @State private var errorMessage: String?
    @State private var installedCount: Int?

    var body: some View {
        VStack(spacing: 6) {
            if let installedCount {
                Label("\(installedCount) factory files installed — open FIRST_RUN.md to adapt",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button {
                    confirming = true
                } label: {
                    if installing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Install Factory…", systemImage: "building.2")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(installing)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
        }
        .confirmationDialog(
            "Install the dark-factory skeleton into this repository?",
            isPresented: $confirming, titleVisibility: .visible) {
            Button("Install") { install() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Copies LEDGER.md, FACTORY.md, MISSION.md and the rest of the DF_Template skeleton. Existing files are never overwritten. Nothing is committed.")
        }
    }

    private func install() {
        installing = true
        errorMessage = nil
        Task {
            do {
                let result = try await store.installFactory(repoID)
                installedCount = result.installed.count
            } catch FactoryInstaller.InstallerError.templateMissing(let path) {
                errorMessage = "Template not found at \(path). Clone DF_Template into ~/projects first."
            } catch {
                errorMessage = "\(error)"
            }
            installing = false
        }
    }
}

/// Compact bottom banner for repos that are partly a factory (GitHub
/// remote, maybe docs) but have no ledger system.
struct InstallFactoryBanner: View {
    let repoID: UUID

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "book.and.wrench")
                .foregroundStyle(.secondary)
            Text("No ledger system in this repository.")
                .font(.callout)
            Spacer()
            InstallFactoryButton(repoID: repoID)
        }
        .padding(10)
        .background(.regularMaterial)
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
