import SwiftUI
import CygnusKit

// The CI Flow section: a full-pane Metal flowchart of the selected
// repo's build pipeline — fastlane (trigger → lane → action) when a
// Fastfile exists, otherwise a Makefile's target graph (goal → target →
// recipe). Built from the actual files the capability scan parsed; no
// fixtures. If the repo has neither, the section says so.

struct CIFlowView: View {
    @Environment(WorkspaceStore.self) private var store
    let repoID: UUID
    @State private var selection: String?

    private var state: FactoryState { store.factoryState(for: repoID) }
    private var flow: CIFlow? { state.caps.ciFlow }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .task(id: repoID) { store.ensureCapabilities(repoID) }
            .toolbar {
                ToolbarItem {
                    Button { store.refresh(.capabilities, for: repoID) } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                }
            }
    }

    @ViewBuilder private var content: some View {
        if let flow, !flow.isEmpty {
            flowCanvas(flow)
        } else if state.capabilities.value == nil {
            ProgressView().controlSize(.small)
        } else {
            ContentUnavailableView {
                Label("No Pipeline", systemImage: "flowchart")
            } description: {
                Text("This repository has no fastlane Fastfile or Makefile to chart. The CI Flow visualizes fastlane lanes or Make targets, their steps, and how they connect.")
            }
        }
    }

    private func flowCanvas(_ flow: CIFlow) -> some View {
        CIFlowMetalView(flow: flow, selection: $selection)
            .overlay(alignment: .topLeading) { statsBadge(flow) }
            .overlay(alignment: .bottom) { legendBar(flow) }
            .accessibilityElement()
            .accessibilityLabel(flow.source == .make ? "Make target flow chart" : "Fastlane CI flow chart")
            .accessibilityValue(accessibilityValue(flow))
            .accessibilityHint("Scroll to zoom, drag to pan, click a node to select it.")
    }

    // Source-specific wording: fastlane speaks lanes/triggers, make
    // speaks targets/goals.
    private func terms(_ source: CIFlow.Source) -> (group: String, entry: String, step: String, call: String) {
        switch source {
        case .fastlane: ("Lane", "Trigger", "Action", "Sub-lane call")
        case .make:     ("Target", "Goal", "Recipe", "Prerequisite")
        }
    }

    private func statsBadge(_ flow: CIFlow) -> some View {
        let t = terms(flow.source)
        let groups = flow.nodes.filter { $0.kind == .lane }.count
        let entries = flow.nodes.filter { $0.kind == .trigger }.count
        let steps = flow.nodes.filter { $0.kind == .action || $0.kind == .laneCall }.count
        return HStack(spacing: 6) {
            Image(systemName: flow.source == .make ? "hammer" : "flowchart")
            Text("\(groups) \(t.group.lowercased())s · \(entries) \(t.entry.lowercased())s · \(steps) steps")
                .font(.caption.monospaced())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(12)
    }

    private func legendBar(_ flow: CIFlow) -> some View {
        let t = terms(flow.source)
        return HStack(spacing: 16) {
            legendChip(t.entry, .blue)
            legendChip(t.group, .purple)
            legendChip(t.step, .teal)
            legendChip(t.call, .orange)
            if let label = selection.flatMap({ id in flow.nodes.first { $0.id == id }?.label }) {
                Divider().frame(height: 12)
                Text(label).font(.caption.monospaced().weight(.semibold))
            }
        }
        .font(.caption2)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .padding(12)
    }

    private func legendChip(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func accessibilityValue(_ flow: CIFlow) -> String {
        let t = terms(flow.source)
        let groups = flow.nodes.filter { $0.kind == .lane }.count
        let entries = flow.nodes.filter { $0.kind == .trigger }.count
        var value = "\(groups) \(t.group.lowercased())s, \(entries) \(t.entry.lowercased())s"
        if let id = selection, let label = flow.nodes.first(where: { $0.id == id })?.label {
            value += ", selected: \(label)"
        }
        return value
    }
}
