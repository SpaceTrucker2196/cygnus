import SwiftUI
import CygnusKit

// The 2D "Flat" renderer: a pattern visualizer over a progressive
// force layout. The visual grammar, all at once:
//   • node color   = group / architectural role
//   • node size    = importance (degree — hubs are large)
//   • coverage halo = test line-coverage arc (red → green), live
//   • group hulls  = tinted, labeled regions per cluster
//   • amber edges  = dependency cycles (the first smell to find)
//   • focus mode   = select a node → its blast radius lights, the
//                    rest dims, and edges gain direction arrows

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
    @State private var coverageMode = true
    @State private var cyclesOnly = false
    @State private var coverage: CoverageReport?
    @State private var cyclicEdges: Set<String> = []

    private struct LayoutInput: Equatable {
        let scene: GraphScene
        let grouping: GraphScene.Grouping
    }

    /// Halo source, most-specific first: the live suite run, then a
    /// single attributed test, then the loaded whole-repo artifact.
    private var activeCoverage: CoverageReport? {
        store.liveCoverage ?? store.attributedCoverage?.report ?? coverage
    }

    /// The selected node's blast radius (itself + direct neighbors),
    /// or nil when nothing is selected — the signal for focus mode.
    private var focusSet: Set<String>? {
        guard let selected = store.selectedNode,
              scene.nodes.contains(where: { $0.id == selected }) else { return nil }
        return store.currentIndex?.neighborhood(of: selected) ?? [selected]
    }

    var body: some View {
        GeometryReader { geometry in
            canvas(in: geometry.size)
                .gesture(dragGesture)
                .simultaneousGesture(magnifyGesture)
                .onTapGesture { location in select(at: location, in: geometry.size) }
                .onTapGesture(count: 2) {
                    withAnimation(.snappy) { zoom = 1; pan = .zero }
                }
        }
        .task(id: LayoutInput(scene: scene, grouping: grouping)) {
            cyclicEdges = scene.cyclicEdges
            for await next in LayoutEngine(scene: scene, initial: frame.positions,
                                           clusters: scene.clusters(grouping: grouping)).frames() {
                frame = next
            }
        }
        .task(id: "\(coverageMode)-\(store.selectedRepo?.uuidString ?? "")") {
            guard coverageMode, let repo = store.selectedRepo else { return }
            coverage = await store.loadCoverage(for: repo)
        }
        .overlay(alignment: .top) {
            GraphControlBar(zoom: $zoom, labelMode: $labelMode, labelSize: $labelSize,
                            legendShown: $legendShown, grouping: $grouping,
                            coverageMode: $coverageMode, cyclesOnly: $cyclesOnly,
                            cycleCount: cyclicEdges.count)
        }
        .overlay(alignment: .topLeading) { coverageStatus }
        .overlay(alignment: .bottomLeading) {
            if legendShown {
                GraphLegendView(scene: scene, cycleCount: cyclicEdges.count,
                                colors: GraphPalette.colors(for: scene, grouping: grouping))
            }
        }
        .overlay(alignment: .bottomTrailing) { statusReadout }
    }

    // MARK: - Coverage overlay (status + live run)

    @ViewBuilder private var coverageStatus: some View {
        if coverageMode {
            VStack(alignment: .leading, spacing: 6) {
                if let run = store.coverageRun {
                    Label(run.isFinished
                          ? "Coverage: \(run.total) tests"
                          : "Running \(run.current) (\(run.done)/\(run.total))",
                          systemImage: run.isFinished ? "checkmark.circle" : "timer")
                        .font(.caption.weight(.medium))
                    if !run.isFinished {
                        Button("Cancel") { store.cancelCoverageSuite() }.controlSize(.mini)
                    }
                } else if let attributed = store.attributedCoverage {
                    Label("Halos: \(attributed.testClass)", systemImage: "scope")
                        .font(.caption.weight(.medium))
                    Button("Clear") { store.attributedCoverage = nil }.controlSize(.mini)
                } else if activeCoverage == nil {
                    Text("No coverage loaded. Run the suite to fill halos live, or "
                         + "load a `swift test --enable-code-coverage` / fastlane scan artifact.")
                        .font(.caption).frame(maxWidth: 240, alignment: .leading)
                }
                if store.coverageRun == nil {
                    Button {
                        if let repo = store.selectedRepo { store.runCoverageSuite(for: repo) }
                    } label: {
                        Label("Run Coverage", systemImage: "play.circle")
                    }
                    .controlSize(.small)
                }
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(.top, 52).padding(.leading, 10)
        }
    }

    private var statusReadout: some View {
        Text("\(scene.nodes.count) nodes · \(scene.edges.count) edges"
             + (cyclicEdges.isEmpty ? "" : " · \(cyclicEdges.count) in cycles"))
            .font(.caption).foregroundStyle(.secondary).padding(6)
    }

    // MARK: - Canvas

    private func canvas(in size: CGSize) -> some View {
        Canvas { context, size in
            let transform = viewTransform(in: size)
            let colors = GraphPalette.colors(for: scene, grouping: grouping)
            let focus = focusSet
            drawGroupRegions(context: context, transform: transform,
                             colors: colors, focus: focus)
            drawEdges(context: context, transform: transform, focus: focus)
            drawNodes(context: context, in: size, transform: transform,
                      colors: colors, focus: focus)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func drawEdges(context: GraphicsContext, transform: CGAffineTransform,
                           focus: Set<String>?) {
        let testIDs = Set(scene.nodes.filter(GraphScene.isTest).map(\.id))
        let selected = store.selectedNode
        for edge in scene.edges {
            guard let fromPos = frame.positions[edge.from],
                  let toPos = frame.positions[edge.to] else { continue }
            let from = CGPoint(x: fromPos.x, y: fromPos.y).applying(transform)
            let to = CGPoint(x: toPos.x, y: toPos.y).applying(transform)
            let isCyclic = cyclicEdges.contains("\(edge.from)\u{1}\(edge.to)")
            let touchesSelection = edge.from == selected || edge.to == selected
            let inFocus = focus == nil
                || (focus!.contains(edge.from) && focus!.contains(edge.to))

            // Resolve the edge's colour + weight from its role.
            let color: Color, width: CGFloat, arrow: Bool
            if cyclesOnly && !isCyclic {
                color = .secondary.opacity(0.04); width = 0.5; arrow = false
            } else if isCyclic {
                color = .orange.opacity(inFocus ? 0.9 : 0.55); width = 2; arrow = touchesSelection
            } else if focus != nil && !inFocus {
                color = .secondary.opacity(0.05); width = 0.5; arrow = false
            } else if touchesSelection {
                color = .accentColor.opacity(0.9); width = 2; arrow = true
            } else if testIDs.contains(edge.from) || testIDs.contains(edge.to) {
                color = .blue.opacity(0.4); width = 1; arrow = false
            } else {
                color = .secondary.opacity(focus == nil ? 0.25 : 0.4); width = 1; arrow = false
            }

            var path = Path()
            path.move(to: from); path.addLine(to: to)
            context.stroke(path, with: .color(color), lineWidth: width)
            if arrow { drawArrowhead(context: context, from: from, to: to,
                                     radius: nodeRadius(id: edge.to), color: color) }
        }
    }

    /// A small filled triangle at the target end, backed off the node
    /// radius — shows dependency direction on focused/cycle edges.
    private func drawArrowhead(context: GraphicsContext, from: CGPoint, to: CGPoint,
                               radius: CGFloat, color: Color) {
        let dx = to.x - from.x, dy = to.y - from.y
        let len = max(hypot(dx, dy), 0.001)
        let ux = dx / len, uy = dy / len
        let tip = CGPoint(x: to.x - ux * (radius + 1), y: to.y - uy * (radius + 1))
        let size: CGFloat = 6
        let left = CGPoint(x: tip.x - ux * size - uy * size * 0.5,
                           y: tip.y - uy * size + ux * size * 0.5)
        let right = CGPoint(x: tip.x - ux * size + uy * size * 0.5,
                            y: tip.y - uy * size - ux * size * 0.5)
        var head = Path()
        head.move(to: tip); head.addLine(to: left); head.addLine(to: right); head.closeSubpath()
        context.fill(head, with: .color(color))
    }

    private func drawNodes(context: GraphicsContext, in size: CGSize,
                           transform: CGAffineTransform, colors: [String: Color],
                           focus: Set<String>?) {
        let showLabels = labelMode == .on
            || (labelMode == .auto && (scene.nodes.count <= 250 || currentScale(in: size) > 1.5))
        for node in scene.nodes {
            guard let position = frame.positions[node.id] else { continue }
            let point = CGPoint(x: position.x, y: position.y).applying(transform)
            let radius = nodeRadius(node)
            let rect = CGRect(x: point.x - radius, y: point.y - radius,
                              width: radius * 2, height: radius * 2)
            let isSelected = node.id == store.selectedNode
            let dimmed = focus != nil && !focus!.contains(node.id)
            let fill = GraphPalette.color(for: node, grouping: grouping, in: colors)
            context.fill(Path(ellipseIn: rect),
                         with: .color(fill.opacity(dimmed ? 0.2 : 1)))

            if coverageMode, !dimmed,
               let fraction = activeCoverage?.fraction(forPath: node.path) {
                let halo = Path()
                var arc = halo
                arc.addArc(center: point, radius: radius + 4.5, startAngle: .degrees(-90),
                           endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
                context.stroke(arc, with: .color(Color(hue: 0.33 * fraction, saturation: 0.85,
                                                        brightness: 0.85)),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            if isSelected {
                context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)),
                               with: .color(.accentColor), lineWidth: 2)
            }
            if (showLabels || isSelected) && !dimmed {
                context.draw(
                    Text(node.label).font(.system(size: labelSize))
                        .foregroundStyle(isSelected ? Color.primary : .secondary),
                    at: CGPoint(x: point.x, y: point.y - radius - labelSize * 0.7))
            }
        }
    }

    /// Tinted, labeled hull behind each cluster.
    private func drawGroupRegions(context: GraphicsContext, transform: CGAffineTransform,
                                  colors: [String: Color], focus: Set<String>?) {
        guard grouping != .none else { return }
        var members: [String: [SIMD2<Double>]] = [:]
        for node in scene.nodes {
            guard let position = frame.positions[node.id],
                  let key = GraphScene.clusterKey(of: node, grouping: grouping) else { continue }
            let point = CGPoint(x: position.x, y: position.y).applying(transform)
            members[key, default: []].append(SIMD2(point.x, point.y))
        }
        let padding: CGFloat = 26
        let dim: Double = focus == nil ? 1 : 0.4
        for (key, points) in members.sorted(by: { $0.key < $1.key }) {
            let hull = ConvexHull.hull(of: points)
            guard let first = hull.first else { continue }
            var path = Path()
            path.move(to: CGPoint(x: first.x, y: first.y))
            for point in hull.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
            path.closeSubpath()
            let color = colors[key] ?? .gray
            let opacity = (GraphPalette.isTestKey(key) ? 0.16 : 0.10) * dim
            let style = StrokeStyle(lineWidth: padding * 2, lineCap: .round, lineJoin: .round)
            context.stroke(path, with: .color(color.opacity(opacity)), style: style)
            context.fill(path, with: .color(color.opacity(opacity)))
            let top = hull.min(by: { $0.y < $1.y }) ?? first
            context.draw(Text(key).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color.opacity(0.85 * dim)),
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
    private func nodeRadius(id: String) -> CGFloat {
        4 + min(CGFloat(scene.degree[id] ?? 0).squareRoot() * 1.5, 10)
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
        // Tapping empty space clears the focus.
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
