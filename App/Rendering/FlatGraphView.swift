import SwiftUI
import CygnusKit

// The 2D "Flat" renderer: SwiftUI Canvas over a progressive force
// layout. Nodes are colored by project area (GraphPalette), sized by
// import count; labels and zoom are user-controlled.

struct FlatGraphView: View {
    @Environment(WorkspaceStore.self) private var store
    let scene: GraphScene

    @State private var frame: LayoutFrame = .empty
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var activeMagnification: CGFloat = 1
    @State private var activeDrag: CGSize = .zero
    @State private var labelMode: LabelMode = .auto
    @State private var labelSize: Double = 11
    @State private var legendShown = true

    var body: some View {
        GeometryReader { geometry in
            canvas(in: geometry.size)
                .gesture(dragGesture)
                .simultaneousGesture(magnifyGesture)
                .onTapGesture { location in
                    select(at: location, in: geometry.size)
                }
                .onTapGesture(count: 2) {
                    withAnimation(.snappy) { zoom = 1; pan = .zero }
                }
        }
        .task(id: scene) {
            frame = .empty
            for await next in LayoutEngine(scene: scene).frames() {
                frame = next
            }
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
            Text("\(scene.nodes.count) nodes · \(scene.edges.count) edges")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(6)
        }
    }

    private func canvas(in size: CGSize) -> some View {
        Canvas { context, size in
            let transform = viewTransform(in: size)
            let colors = GraphPalette.groupColors(for: scene)
            var edgePath = Path()
            for edge in scene.edges {
                guard let from = frame.positions[edge.from],
                      let to = frame.positions[edge.to] else { continue }
                edgePath.move(to: CGPoint(x: from.x, y: from.y).applying(transform))
                edgePath.addLine(to: CGPoint(x: to.x, y: to.y).applying(transform))
            }
            context.stroke(edgePath, with: .color(.secondary.opacity(0.25)), lineWidth: 1)

            let showLabels = labelMode == .on
                || (labelMode == .auto
                    && (scene.nodes.count <= 250 || currentScale(in: size) > 1.5))
            for node in scene.nodes {
                guard let position = frame.positions[node.id] else { continue }
                let point = CGPoint(x: position.x, y: position.y).applying(transform)
                let radius = nodeRadius(node)
                let rect = CGRect(x: point.x - radius, y: point.y - radius,
                                  width: radius * 2, height: radius * 2)
                let isSelected = node.id == store.selectedNode
                context.fill(Path(ellipseIn: rect),
                             with: .color(GraphPalette.color(for: node, in: colors)))
                if isSelected {
                    context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)),
                                   with: .color(.accentColor), lineWidth: 2)
                }
                if showLabels || isSelected {
                    context.draw(
                        Text(node.label).font(.system(size: labelSize))
                            .foregroundStyle(isSelected ? Color.primary : .secondary),
                        at: CGPoint(x: point.x, y: point.y - radius - labelSize * 0.7))
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Transform

    private func currentScale(in size: CGSize) -> CGFloat {
        let bounds = layoutBounds()
        guard bounds.width > 0, bounds.height > 0 else { return 1 }
        let fit = min(size.width / bounds.width, size.height / bounds.height, 2) * 0.9
        return fit * zoom * activeMagnification
    }

    private func viewTransform(in size: CGSize) -> CGAffineTransform {
        let bounds = layoutBounds()
        let scale = currentScale(in: size)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        return CGAffineTransform.identity
            .translatedBy(x: size.width / 2 + pan.width + activeDrag.width,
                          y: size.height / 2 + pan.height + activeDrag.height)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -center.x, y: -center.y)
    }

    private func layoutBounds() -> CGRect {
        guard !frame.positions.isEmpty else { return CGRect(x: -1, y: -1, width: 2, height: 2) }
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for position in frame.positions.values {
            minX = min(minX, position.x); maxX = max(maxX, position.x)
            minY = min(minY, position.y); maxY = max(maxY, position.y)
        }
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
    }

    private func nodeRadius(_ node: GraphSnapshot.Node) -> CGFloat {
        4 + min(CGFloat(scene.degree[node.id] ?? 0).squareRoot() * 1.5, 10)
    }

    // MARK: - Interaction

    private func select(at location: CGPoint, in size: CGSize) {
        let transform = viewTransform(in: size)
        var best: (id: String, distance: CGFloat)?
        for node in scene.nodes {
            guard let position = frame.positions[node.id] else { continue }
            let point = CGPoint(x: position.x, y: position.y).applying(transform)
            let distance = hypot(point.x - location.x, point.y - location.y)
            if distance < nodeRadius(node) + 6, distance < (best?.distance ?? .infinity) {
                best = (node.id, distance)
            }
        }
        store.selectedNode = best?.id
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { activeDrag = $0.translation }
            .onEnded { value in
                pan.width += value.translation.width
                pan.height += value.translation.height
                activeDrag = .zero
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { activeMagnification = $0.magnification }
            .onEnded { value in
                zoom = max(0.2, min(zoom * value.magnification, 8))
                activeMagnification = 1
            }
    }
}
