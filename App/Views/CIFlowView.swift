import SwiftUI
import Foundation
import CygnusKit

// The CI Flow section: a full-pane Metal flowchart of the selected
// repo's build pipeline — fastlane (trigger → lane → action) when a
// Fastfile exists, otherwise a Makefile's target graph (goal → target →
// recipe). Built from the actual files the capability scan parsed.
//
// Make flows can be RUN: the Run button starts the build and the flow
// animates live — each node lights up as its work happens, greens as it
// completes, reds on failure. Fastlane lanes aren't run from here (they
// can sign and upload).

struct CIFlowView: View {
    @Environment(WorkspaceStore.self) private var store
    let repoID: UUID
    @State private var selection: String?

    private var state: FactoryState { store.factoryState(for: repoID) }
    private var flow: CIFlow? { state.caps.ciFlow }
    private var progress: BuildProgress { store.buildProgress(for: repoID) }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .task(id: repoID) { store.ensureCapabilities(repoID) }
            .toolbar {
                if let flow, !flow.isEmpty {
                    ToolbarItem { buildButton(flow) }
                }
                ToolbarItem {
                    Button { store.refresh(.capabilities, for: repoID) } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .disabled(progress.isRunning)
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

    // MARK: Run / Stop

    @ViewBuilder private func buildButton(_ flow: CIFlow) -> some View {
        if progress.isRunning {
            Button(role: .destructive) { store.cancelBuild(for: repoID) } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .accessibilityIdentifier("ciflow.stop")
            .help("Stop the running build")
        } else if store.canBuild(repoID) {
            Button { store.startBuild(for: repoID) } label: {
                Label("Run Build", systemImage: "play.fill")
            }
            .accessibilityIdentifier("ciflow.run")
            .help("Run `\(buildCommandPreview(flow))` and animate the flow live")
        } else {
            Button {} label: { Label("Run Build", systemImage: "play.fill") }
                .disabled(true)
                .help("Running fastlane lanes from here isn't supported — they can sign and upload.")
        }
    }

    // MARK: Canvas

    private func flowCanvas(_ flow: CIFlow) -> some View {
        Group {
            if progress.isRunning {
                TimelineView(.animation) { timeline in
                    metal(flow, pulse: pulse(at: timeline.date))
                }
            } else {
                metal(flow, pulse: 0)
            }
        }
        .overlay(alignment: .topLeading) { statsBadge(flow) }
        .overlay(alignment: .bottom) { bottomBar(flow) }
        .accessibilityElement()
        .accessibilityLabel(flow.source == .make ? "Make target flow chart" : "Fastlane CI flow chart")
        .accessibilityValue(accessibilityValue(flow))
        .accessibilityHint("Scroll to zoom, drag to pan, click a node to select it.")
    }

    private func metal(_ flow: CIFlow, pulse: Double) -> some View {
        CIFlowMetalView(flow: flow, selection: $selection,
                        nodeStates: progress.nodeStates, pulse: pulse)
    }

    /// A gentle 0…1 breathing curve for the active node's glow.
    private func pulse(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        return 0.5 + 0.5 * sin(t * 4.5)
    }

    // MARK: Overlays

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

    @ViewBuilder private func bottomBar(_ flow: CIFlow) -> some View {
        VStack(spacing: 8) {
            if progress.phase != .idle { buildStatus }
            legendBar(flow)
        }
        .padding(12)
    }

    @ViewBuilder private var buildStatus: some View {
        HStack(spacing: 8) {
            switch progress.phase {
            case .running:
                ProgressView().controlSize(.small)
                Text("Building").font(.caption.weight(.semibold))
                if let label = activeLabel {
                    Text(label).font(.caption.monospaced()).foregroundStyle(.teal)
                }
            case .succeeded:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Build succeeded").font(.caption.weight(.semibold))
            case .failed:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text("Build failed").font(.caption.weight(.semibold))
            case .idle:
                EmptyView()
            }
            if !progress.lastLine.isEmpty {
                Divider().frame(height: 12)
                Text(progress.lastLine)
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .frame(maxWidth: 620)
        .background(.regularMaterial, in: Capsule())
    }

    private var activeLabel: String? {
        guard let id = progress.activeNodeID else { return nil }
        return flow?.nodes.first { $0.id == id }?.label
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
    }

    private func legendChip(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(text).foregroundStyle(.secondary)
        }
    }

    // Source-specific wording: fastlane speaks lanes/triggers, make
    // speaks targets/goals.
    private func terms(_ source: CIFlow.Source) -> (group: String, entry: String, step: String, call: String) {
        switch source {
        case .fastlane: ("Lane", "Trigger", "Action", "Sub-lane call")
        case .make:     ("Target", "Goal", "Recipe", "Prerequisite")
        }
    }

    private func accessibilityValue(_ flow: CIFlow) -> String {
        let t = terms(flow.source)
        let groups = flow.nodes.filter { $0.kind == .lane }.count
        let entries = flow.nodes.filter { $0.kind == .trigger }.count
        var value = "\(groups) \(t.group.lowercased())s, \(entries) \(t.entry.lowercased())s"
        switch progress.phase {
        case .running: value += ", building" + (activeLabel.map { ": \($0)" } ?? "")
        case .succeeded: value += ", build succeeded"
        case .failed: value += ", build failed"
        case .idle: break
        }
        if let id = selection, let label = flow.nodes.first(where: { $0.id == id })?.label {
            value += ", selected: \(label)"
        }
        return value
    }

    private func buildCommandPreview(_ flow: CIFlow) -> String {
        "make" + (WorkspaceStore.defaultGoal(of: flow).map { " \($0)" } ?? "")
    }
}
