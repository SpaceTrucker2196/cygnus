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

    /// Colors keyed by the active grouping's cluster names. Semantic
    /// groups get pinned colors (tests are always blue, imported
    /// modules always purple — segregating tests/externals visually);
    /// the rest take stable sorted hues.
    static func colors(for scene: GraphScene,
                       grouping: GraphScene.Grouping) -> [String: Color] {
        let keys = Set(scene.nodes.compactMap {
            GraphScene.clusterKey(of: $0, grouping: grouping) ?? GraphScene.group(of: $0)
        })
        var colors: [String: Color] = [:]
        var hueIndex = 0
        for key in keys.sorted() {
            if key == "modules" || key == "Modules" {
                colors[key] = .purple
            } else if isTestKey(key) {
                colors[key] = .blue
            } else {
                colors[key] = hues[hueIndex % hues.count]
                hueIndex += 1
            }
        }
        return colors
    }

    static func color(for node: GraphSnapshot.Node,
                      grouping: GraphScene.Grouping,
                      in colors: [String: Color]) -> Color {
        let key = GraphScene.clusterKey(of: node, grouping: grouping)
            ?? GraphScene.group(of: node)
        return colors[key] ?? .gray
    }
}

/// What node size means, what colors mean. Overlaid on the graph view.
struct GraphLegendView: View {
    let scene: GraphScene
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
            Divider().frame(width: 130)
            HStack(spacing: 6) {
                Circle().stroke(.secondary).frame(width: 12, height: 12)
                Text("size = import count").font(.caption)
            }
        }
        .padding(9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }
}

enum LabelMode: String, CaseIterable {
    case auto = "Auto", on = "On", off = "Off"
}

/// Zoom / label / grouping controls for the graph view.
struct GraphControlBar: View {
    @Binding var zoom: CGFloat
    @Binding var labelMode: LabelMode
    @Binding var labelSize: Double
    @Binding var legendShown: Bool
    @Binding var grouping: GraphScene.Grouping

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
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .padding(8)
    }
}
