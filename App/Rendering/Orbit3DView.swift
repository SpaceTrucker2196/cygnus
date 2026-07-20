import SwiftUI
import CygnusKit

// 3D graph view rendered by projecting the Layout3D solution through
// a perspective transform onto the proven SwiftUI Canvas. Drag to
// orbit, pinch/slider to zoom, click to select. Chosen over the
// RealityKit renderer, which is parked: its GPU initialization
// crashed and then kernel-wedged on this machine (see PROGRESS.md).

struct Orbit3DView: View {
    @Environment(WorkspaceStore.self) private var store
    let scene: GraphScene

    @State private var frame: LayoutFrame3D?
    @State private var yaw: Double = 0.7
    @State private var pitch: Double = 0.3
    @State private var zoom: CGFloat = 1
    @State private var dragOrigin: (yaw: Double, pitch: Double)?
    @State private var labelMode: LabelMode = .auto
    @State private var labelSize: Double = 11
    @State private var legendShown = true

    var body: some View {
        Group {
            if let frame {
                projectionCanvas(frame)
            } else {
                ProgressView("Laying out…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: scene) {
            frame = nil
            frame = await Layout3D.solve(scene).normalized(toRadius: 320)
        }
        .overlay(alignment: .top) {
            GraphControlBar(zoom: $zoom, labelMode: $labelMode,
                            labelSize: $labelSize, legendShown: $legendShown)
        }
        .overlay(alignment: .bottomLeading) {
            if legendShown {
                GraphLegendView(scene: scene, colors: GraphPalette.groupColors(for: scene))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text("\(scene.nodes.count) nodes · \(scene.edges.count) edges · drag to orbit")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(6)
        }
    }

    private func projectionCanvas(_ frame: LayoutFrame3D) -> some View {
        GeometryReader { geometry in
            let projected = project(frame, in: geometry.size)
            Canvas { context, _ in
                draw(projected, context: &context)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .gesture(orbitGesture)
            .simultaneousGesture(magnifyGesture)
            .onTapGesture { location in
                select(at: location, projected: projected)
            }
        }
    }

    // MARK: - Projection

    struct ProjectedNode {
        let node: GraphSnapshot.Node
        let point: CGPoint
        let scale: CGFloat        // perspective attenuation, 0…1+
        let depth: Double
    }

    private func project(_ frame: LayoutFrame3D,
                         in size: CGSize) -> [String: ProjectedNode] {
        let cosY = cos(yaw), sinY = sin(yaw)
        let cosP = cos(pitch), sinP = sin(pitch)
        let focal = 900.0
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let fit = min(size.width, size.height) / 760 * zoom

        var result: [String: ProjectedNode] = [:]
        result.reserveCapacity(scene.nodes.count)
        for node in scene.nodes {
            guard let p = frame.positions[node.id] else { continue }
            let x1 = p.x * cosY + p.z * sinY
            let z1 = -p.x * sinY + p.z * cosY
            let y1 = p.y * cosP - z1 * sinP
            let z2 = p.y * sinP + z1 * cosP
            let attenuation = focal / (focal + z2 + 400)
            result[node.id] = ProjectedNode(
                node: node,
                point: CGPoint(x: center.x + x1 * attenuation * fit,
                               y: center.y - y1 * attenuation * fit),
                scale: attenuation,
                depth: z2)
        }
        return result
    }

    private func radius(_ node: GraphSnapshot.Node, _ scale: CGFloat) -> CGFloat {
        (4 + min(CGFloat(scene.degree[node.id] ?? 0).squareRoot() * 1.5, 10)) * scale
    }

    // MARK: - Drawing

    private func draw(_ projected: [String: ProjectedNode], context: inout GraphicsContext) {
        let colors = GraphPalette.groupColors(for: scene)

        var edgePath = Path()
        for edge in scene.edges {
            guard let from = projected[edge.from], let to = projected[edge.to] else { continue }
            edgePath.move(to: from.point)
            edgePath.addLine(to: to.point)
        }
        context.stroke(edgePath, with: .color(.secondary.opacity(0.22)), lineWidth: 1)

        let showLabels = labelMode == .on
            || (labelMode == .auto && (scene.nodes.count <= 250 || zoom > 1.5))
        // Painter's order: far nodes first.
        for item in projected.values.sorted(by: { $0.depth > $1.depth }) {
            let r = radius(item.node, item.scale)
            let rect = CGRect(x: item.point.x - r, y: item.point.y - r,
                              width: r * 2, height: r * 2)
            let isSelected = item.node.id == store.selectedNode
            let color = GraphPalette.color(for: item.node, in: colors)
            context.fill(Path(ellipseIn: rect),
                         with: .color(color.opacity(0.45 + 0.55 * min(item.scale, 1))))
            if isSelected {
                context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)),
                               with: .color(.accentColor), lineWidth: 2)
            }
            if isSelected || (showLabels && (scene.degree[item.node.id] ?? 0) >= 1) {
                context.draw(
                    Text(item.node.label)
                        .font(.system(size: labelSize * item.scale))
                        .foregroundStyle(isSelected ? Color.primary : .secondary),
                    at: CGPoint(x: item.point.x, y: item.point.y - r - labelSize * 0.7))
            }
        }
    }

    // MARK: - Interaction

    private func select(at location: CGPoint, projected: [String: ProjectedNode]) {
        var best: (id: String, distance: CGFloat)?
        for item in projected.values {
            let d = hypot(item.point.x - location.x, item.point.y - location.y)
            if d < radius(item.node, item.scale) + 6, d < (best?.distance ?? .infinity) {
                best = (item.node.id, d)
            }
        }
        store.selectedNode = best?.id
    }

    private var orbitGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let origin = dragOrigin ?? (yaw, pitch)
                dragOrigin = origin
                yaw = origin.yaw + Double(value.translation.width) * 0.008
                pitch = max(-1.4, min(origin.pitch + Double(value.translation.height) * 0.008, 1.4))
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onEnded { value in
                zoom = max(0.25, min(zoom * value.magnification, 8))
            }
    }
}
