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
    @State private var grouping: GraphScene.Grouping = .area
    @State private var coverageMode = false
    @State private var coverage: CoverageReport?

    /// Layout restarts when either the scene or the grouping changes;
    /// warm-start keeps existing nodes near where they were.
    private struct LayoutInput: Equatable {
        let scene: GraphScene
        let grouping: GraphScene.Grouping
    }

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
        .task(id: LayoutInput(scene: scene, grouping: grouping)) {
            // Warm-start from wherever nodes already are: when the
            // scene grows during analysis, new nodes join a stable
            // layout instead of restarting it.
            for await next in LayoutEngine(scene: scene,
                                           initial: frame.positions,
                                           clusters: scene.clusters(grouping: grouping))
                .frames() {
                frame = next
            }
        }
        .overlay(alignment: .top) {
            GraphControlBar(zoom: $zoom, labelMode: $labelMode,
                            labelSize: $labelSize, legendShown: $legendShown,
                            grouping: $grouping, coverageMode: $coverageMode)
        }
        .task(id: coverageMode) {
            guard coverageMode, let repo = store.selectedRepo else { return }
            coverage = await store.loadCoverage(for: repo)
        }
        .overlay(alignment: .topLeading) {
            if coverageMode, coverage == nil {
                Text("No coverage artifact — run `swift test --enable-code-coverage`, then toggle again.")
                    .font(.caption)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(.top, 52)
                    .padding(.leading, 10)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if legendShown {
                GraphLegendView(scene: scene,
                                colors: GraphPalette.colors(for: scene, grouping: grouping))
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
            let colors = GraphPalette.colors(for: scene, grouping: grouping)
            drawGroupRegions(context: context, transform: transform, colors: colors)
            // Edges touching a test node draw blue so test wiring is
            // traceable at a glance; everything else stays muted.
            let testIDs = Set(scene.nodes.filter(GraphScene.isTest).map(\.id))
            var edgePath = Path()
            var testEdgePath = Path()
            for edge in scene.edges {
                guard let from = frame.positions[edge.from],
                      let to = frame.positions[edge.to] else { continue }
                let isTestEdge = testIDs.contains(edge.from) || testIDs.contains(edge.to)
                var path = isTestEdge ? testEdgePath : edgePath
                path.move(to: CGPoint(x: from.x, y: from.y).applying(transform))
                path.addLine(to: CGPoint(x: to.x, y: to.y).applying(transform))
                if isTestEdge { testEdgePath = path } else { edgePath = path }
            }
            context.stroke(edgePath, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
            context.stroke(testEdgePath, with: .color(.blue.opacity(0.45)), lineWidth: 1)

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
                             with: .color(GraphPalette.color(for: node, grouping: grouping,
                                                             in: colors)))
                // Coverage halo: arc length = covered fraction, red →
                // green ramp. Declarations inherit their file's
                // coverage; nodes without data get no halo.
                if coverageMode,
                   let fraction = coverage?.fraction(forPath: node.path) {
                    let haloRadius = radius + 4.5
                    var halo = Path()
                    halo.addArc(center: point, radius: haloRadius,
                                startAngle: .degrees(-90),
                                endAngle: .degrees(-90 + 360 * fraction),
                                clockwise: false)
                    context.stroke(
                        halo,
                        with: .color(Color(hue: 0.33 * fraction, saturation: 0.85,
                                           brightness: 0.85)),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
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

    /// Tinted, labeled region behind each cluster (background tint +
    /// label reads better than outlines alone at low zoom). The hull
    /// is computed in screen space and padded by stroking the same
    /// path wide with round joins — a soft blob, not a hard polygon.
    private func drawGroupRegions(context: GraphicsContext,
                                  transform: CGAffineTransform,
                                  colors: [String: Color]) {
        guard grouping != .none else { return }
        var members: [String: [SIMD2<Double>]] = [:]
        for node in scene.nodes {
            guard let position = frame.positions[node.id],
                  let key = GraphScene.clusterKey(of: node, grouping: grouping)
            else { continue }
            let point = CGPoint(x: position.x, y: position.y).applying(transform)
            members[key, default: []].append(SIMD2(point.x, point.y))
        }
        let padding: CGFloat = 26
        for (key, points) in members.sorted(by: { $0.key < $1.key }) {
            let hull = ConvexHull.hull(of: points)
            guard let first = hull.first else { continue }
            var path = Path()
            path.move(to: CGPoint(x: first.x, y: first.y))
            for point in hull.dropFirst() {
                path.addLine(to: CGPoint(x: point.x, y: point.y))
            }
            path.closeSubpath()
            let color = colors[key] ?? .gray
            // The tests cloud reads a touch stronger than ordinary
            // regions — it's the band the eye should find first.
            let opacity = GraphPalette.isTestKey(key) ? 0.16 : 0.10
            let style = StrokeStyle(lineWidth: padding * 2,
                                    lineCap: .round, lineJoin: .round)
            context.stroke(path, with: .color(color.opacity(opacity)), style: style)
            context.fill(path, with: .color(color.opacity(opacity)))
            // Label above the region's topmost point.
            let top = hull.min(by: { $0.y < $1.y }) ?? first
            context.draw(
                Text(key).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color.opacity(0.85)),
                at: CGPoint(x: top.x, y: top.y - padding - 9))
        }
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
