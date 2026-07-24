import SwiftUI
import CygnusKit

// Shared pieces for the Flat graph renderer: group palette, legend,
// and the view-control bar.

enum GraphPalette {
    /// Distinct hues for project areas; assignment is stable within a
    /// scene (sorted group names).
    static let hues: [Color] = [
        .blue, .green, .orange, .pink, .teal, .yellow, .indigo,
        .mint, .red, .cyan, .brown,
    ]

    static func groupColors(for scene: GraphScene) -> [String: Color] {
        let groups = Set(scene.nodes.map { GraphScene.group(of: $0) })
            .subtracting(["modules"])
            .sorted()
        var colors: [String: Color] = ["modules": .purple]
        for (index, group) in groups.enumerated() {
            colors[group] = hues[index % hues.count]
        }
        return colors
    }

    static func color(for node: GraphSnapshot.Node, in colors: [String: Color]) -> Color {
        colors[GraphScene.group(of: node)] ?? .gray
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

/// Zoom / label controls for the graph view.
struct GraphControlBar: View {
    @Binding var zoom: CGFloat
    @Binding var labelMode: LabelMode
    @Binding var labelSize: Double
    @Binding var legendShown: Bool

    var body: some View {
        HStack(spacing: 14) {
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
