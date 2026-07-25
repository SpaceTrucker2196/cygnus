import SwiftUI
import CygnusKit

// Shared pieces for the Flat graph renderer: group palette, legend,
// and the view-control bar.

enum GraphPalette {
    /// Distinct hues for project areas; assignment is stable within a
    /// scene (sorted group names). Blue is reserved for tests and
    /// never enters the rotation.
    static let hues: [Color] = [
        .green, .orange, .pink, .teal, .yellow, .indigo,
        .mint, .red, .cyan, .brown,
    ]

    /// Test clusters are blue in every grouping mode — the Layer/
    /// Pattern "Tests" band and Area keys under a test umbrella.
    static func isTestKey(_ key: String) -> Bool {
        key == "Tests" || key.hasPrefix("Tests/") || key.hasPrefix("tests/")
            || key.hasPrefix("test/") || key.hasPrefix("UITests")
    }

    /// A node's colour key: its cluster under the active grouping, or
    /// its project area when the grouping leaves it unassigned (e.g.
    /// None colours by area). One definition every drawing path uses.
    static func key(for node: GraphSnapshot.Node, clusters: [String: String]) -> String {
        clusters[node.id] ?? GraphScene.group(of: node)
    }

    /// Colors keyed by cluster name. Semantic groups get pinned colors
    /// (tests always blue, modules always purple — segregating
    /// tests/externals visually); the rest take stable sorted hues.
    static func colors(nodes: [GraphSnapshot.Node],
                       clusters: [String: String]) -> [String: Color] {
        let keys = Set(nodes.map { key(for: $0, clusters: clusters) })
        var colors: [String: Color] = [:]
        var hueIndex = 0
        for name in keys.sorted() {
            if name == "modules" || name == "Modules" {
                colors[name] = .purple
            } else if isTestKey(name) {
                colors[name] = .blue
            } else {
                colors[name] = hues[hueIndex % hues.count]
                hueIndex += 1
            }
        }
        return colors
    }

    static func color(for node: GraphSnapshot.Node, clusters: [String: String],
                      in colors: [String: Color]) -> Color {
        colors[key(for: node, clusters: clusters)] ?? .gray
    }
}

/// The visual grammar key: colors mean groups, and the encoding
/// legend explains size / halo / cycles. Overlaid on the graph view.
struct GraphLegendView: View {
    let scene: GraphScene
    var cycleCount: Int = 0
    let colors: [String: Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(colors.sorted(by: { $0.key < $1.key }), id: \.key) { group, color in
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 9, height: 9)
                    Text(group == "modules" ? "modules (imported targets)" : group)
                        .font(.caption)
                }
            }
            Divider().frame(width: 150)
            legendRow(symbol: circleSizes, "size = connections (hubs are big)")
            legendRow(symbol: coverageArc, "ring = per-function coverage")
            legendRow(symbol: AnyView(HStack(spacing: 2) {
                Capsule().fill(.green).frame(width: 5, height: 3)
                Capsule().fill(.yellow).frame(width: 5, height: 3)
                Capsule().fill(.red).frame(width: 5, height: 3)
            }), "test link: pass / partial / fail")
            if cycleCount > 0 {
                legendRow(symbol: AnyView(
                    Capsule().fill(.orange).frame(width: 14, height: 3)),
                    "amber = dependency cycle")
            }
            legendRow(symbol: AnyView(
                Image(systemName: "cursorarrow.rays").font(.caption2).foregroundStyle(Color.accentColor)),
                "click a node = its blast radius")
        }
        .padding(9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }

    private func legendRow(symbol: some View, _ text: String) -> some View {
        HStack(spacing: 6) {
            symbol.frame(width: 16, alignment: .center)
            Text(text).font(.caption)
        }
    }

    private var circleSizes: AnyView {
        AnyView(HStack(spacing: 2) {
            Circle().stroke(.secondary).frame(width: 6, height: 6)
            Circle().stroke(.secondary).frame(width: 12, height: 12)
        })
    }
    private var coverageArc: AnyView {
        AnyView(Circle()
            .trim(from: 0, to: 0.7)
            .stroke(.green, lineWidth: 2)
            .rotationEffect(.degrees(-90))
            .frame(width: 12, height: 12))
    }
}

enum LabelMode: String, CaseIterable {
    case auto = "Auto", on = "On", off = "Off"
}

/// Zoom / label / grouping / pattern controls for the graph view.
struct GraphControlBar: View {
    @Binding var zoom: CGFloat
    @Binding var labelMode: LabelMode
    @Binding var labelSize: Double
    @Binding var legendShown: Bool
    @Binding var grouping: GraphScene.Grouping
    @Binding var coverageMode: Bool
    @Binding var cyclesOnly: Bool
    @Binding var expandFunctions: Bool
    var cycleCount: Int = 0

    var body: some View {
        HStack(spacing: 14) {
            Picker("Group", selection: $grouping) {
                ForEach(GraphScene.Grouping.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .frame(width: 230)
            .help("How nodes cluster: project area, prod/tests/modules layers, or architectural roles (MVVM/MVC naming)")
            HStack(spacing: 6) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: Binding(get: { log2(zoom) }, set: { zoom = pow(2, $0) }),
                       in: -2...3)
                    .frame(width: 120)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                Slider(value: $labelSize, in: 8...20)
                    .frame(width: 90)
                Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
            }
            Picker("Labels", selection: $labelMode) {
                ForEach(LabelMode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            Toggle("Legend", isOn: $legendShown)
                .toggleStyle(.checkbox)
            Toggle("Coverage", isOn: $coverageMode)
                .toggleStyle(.checkbox)
                .help("Halo per node showing test line-coverage, live as the suite runs")
            Toggle(isOn: $cyclesOnly) {
                Label("Cycles\(cycleCount > 0 ? " (\(cycleCount))" : "")",
                      systemImage: "arrow.triangle.capsulepath")
            }
            .toggleStyle(.checkbox)
            .disabled(cycleCount == 0)
            .help("Dependency cycles draw amber always; toggle to isolate them")
            Toggle(isOn: $expandFunctions) {
                Label("Expand", systemImage: "circle.hexagongrid")
            }
            .toggleStyle(.checkbox)
            .help("Orbit each node's functions around it as selectable satellites, colored by coverage")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .padding(8)
    }
}
