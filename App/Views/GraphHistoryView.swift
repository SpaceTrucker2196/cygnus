import SwiftUI
import Charts
import CygnusKit

// History for the selected repo: pick two revisions to see what
// changed, and watch one metric move across the recent ones. A
// snapshot says how things are; only this says whether they are
// getting better.

struct GraphHistoryView: View {
    @Environment(WorkspaceStore.self) private var store
    let repoID: UUID
    /// Which pair is being compared. Local because it is a control
    /// position, not workspace state — the store holds the resulting
    /// delta, which is what the renderer needs.
    @State private var from: Int64?
    @State private var to: Int64?

    private var revisions: [GraphRevision] { store.history[repoID] ?? [] }

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 10) {
            if revisions.count < 2 {
                Text(revisions.isEmpty
                     ? "No revisions yet — analyze the repository."
                     : "One revision so far. History needs a second analysis to compare against.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                comparison
                Divider()
                trend(bindable: store)
            }
        }
        .padding(12)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(8)
        .task(id: repoID) { await store.loadHistory(for: repoID) }
        .accessibilityIdentifier("graph.history")
    }

    // MARK: - Revision comparison

    @ViewBuilder private var comparison: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Compare revisions").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                revisionPicker($from, label: "From revision")
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                revisionPicker($to, label: "To revision")
            }
            if let delta = store.activeDelta {
                deltaSummary(delta)
            } else {
                Button("Show changes") { loadDelta() }.controlSize(.small)
            }
        }
        .onAppear {
            from = from ?? defaultRange.from
            to = to ?? defaultRange.to
        }
        .onChange(of: from) { loadDelta() }
        .onChange(of: to) { loadDelta() }
    }

    private func revisionPicker(_ selection: Binding<Int64?>, label: String) -> some View {
        Picker(label, selection: selection) {
            ForEach(revisions) { revision in
                Text("r\(revision.id)").tag(Int64?.some(revision.id))
            }
        }
        .labelsHidden()
        .frame(width: 90)
        .accessibilityLabel(label)
    }

    /// Only a forward interval means anything — (from, to] with the
    /// ends the wrong way round has no facts in it.
    private func loadDelta() {
        guard let from, let to, from < to else {
            store.clearDelta()
            return
        }
        Task { await store.showDelta(for: repoID, from: from, to: to) }
    }

    @ViewBuilder private func deltaSummary(_ delta: RevisionDelta) -> some View {
        if delta.isEmpty {
            Text("Nothing changed for this repository.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                countRow("Added", delta.addedNodes.count, .green)
                countRow("Removed", delta.removedNodes.count, .red)
                countRow("Changed", delta.changedNodes.count, .orange)
                Text("\(delta.addedEdges) edges added, \(delta.removedEdges) removed")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Clear") { store.clearDelta() }
                    .controlSize(.small).buttonStyle(.link)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("graph.deltaSummary")
        }
    }

    private func countRow(_ label: String, _ count: Int, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(count) \(label.lowercased())").font(.caption)
        }
        .foregroundStyle(count == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    }

    /// Newest against the one before it — the comparison anyone wants
    /// first.
    private var defaultRange: WorkspaceStore.RevisionRange {
        WorkspaceStore.RevisionRange(from: revisions[revisions.count - 2].id,
                                     to: revisions[revisions.count - 1].id)
    }

    // MARK: - Trend

    @ViewBuilder private func trend(bindable store: WorkspaceStore) -> some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 6) {
            Picker("Metric", selection: $store.trendMetric) {
                ForEach(GraphMetric.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .accessibilityLabel("Trend metric")

            if store.trendPoints.isEmpty {
                Text("Building trend…").font(.caption).foregroundStyle(.secondary)
            } else {
                Chart(store.trendPoints) { point in
                    LineMark(x: .value("Revision", point.revision),
                             y: .value(store.trendMetric.rawValue, point.value))
                    PointMark(x: .value("Revision", point.revision),
                              y: .value(store.trendMetric.rawValue, point.value))
                }
                .chartXAxisLabel("revision")
                .frame(height: 110)
                .accessibilityLabel("\(store.trendMetric.rawValue) over the last \(store.trendPoints.count) revisions")
                .accessibilityValue(trendDescription)
            }
        }
        .task(id: "\(repoID)-\(store.trendMetric.rawValue)") {
            store.loadTrend(for: repoID, metric: store.trendMetric)
        }
    }

    /// Spoken summary: direction matters more than the numbers, and
    /// for cycles and orphans a rise is bad — say so rather than
    /// leaving it to a color nobody can hear.
    private var trendDescription: String {
        guard let first = store.trendPoints.first, let last = store.trendPoints.last
        else { return "no data" }
        let change = last.value - first.value
        guard change != 0 else { return "flat at \(last.value)" }
        let direction = change > 0 ? "up" : "down"
        let judgement = switch (store.trendMetric.risingIsGood, change > 0) {
        case (false?, true): ", getting worse"
        case (false?, false): ", improving"
        default: ""
        }
        return "\(direction) \(abs(change)) to \(last.value)\(judgement)"
    }
}
