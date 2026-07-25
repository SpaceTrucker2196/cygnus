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
    @State private var expandFunctions = false
    @State private var coverage: CoverageReport?
    @State private var cyclicEdges: Set<String> = []
    @State private var viewSize: CGSize = .zero
    /// A legend group clicked to "explode" — it moves to center, the
    /// rest ring around it.
    @State private var explodedGroup: String?

    private struct LayoutInput: Equatable {
        let scene: GraphScene
        let grouping: GraphScene.Grouping
        let explodedGroup: String?
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
                    store.selectedNode = nil
                    withAnimation(.smooth(duration: 0.5)) { zoom = 1; pan = .zero }
                }
                .onAppear { viewSize = geometry.size }
                .onChange(of: geometry.size) { viewSize = $1 }
        }
        .onChange(of: store.selectedNode) { _, _ in focusOnSelection() }
        .task(id: LayoutInput(scene: scene, grouping: grouping, explodedGroup: explodedGroup)) {
            cyclicEdges = scene.cyclicEdges
            for await next in LayoutEngine(scene: scene, initial: frame.positions,
                                           clusters: scene.clusters(grouping: grouping),
                                           focusCluster: explodedGroup).frames() {
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
                            expandFunctions: $expandFunctions, cycleCount: cyclicEdges.count)
        }
        .overlay(alignment: .topLeading) { coverageStatus }
        .overlay(alignment: .bottomLeading) {
            if legendShown {
                let clusters = scene.clusters(grouping: grouping)
                GraphLegendView(scene: scene, cycleCount: cyclicEdges.count,
                                colors: GraphPalette.colors(nodes: scene.nodes, clusters: clusters),
                                explodedGroup: $explodedGroup)
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
            let clusters = scene.clusters(grouping: grouping)
            let colors = GraphPalette.colors(nodes: scene.nodes, clusters: clusters)
            let focus = focusSet
            let byID = Dictionary(uniqueKeysWithValues: scene.nodes.map { ($0.id, $0) })
            drawGroupRegions(context: context, transform: transform,
                             clusters: clusters, colors: colors, focus: focus)
            drawEdges(context: context, transform: transform, focus: focus, byID: byID)
            drawNodes(context: context, in: size, transform: transform,
                      clusters: clusters, colors: colors, focus: focus)
            // Satellites: all nodes when Expand is on; otherwise just
            // the selected node's, so selecting expands its functions.
            if expandFunctions || store.selectedNode != nil {
                drawSatellites(context: context, in: size, transform: transform, focus: focus)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func drawEdges(context: GraphicsContext, transform: CGAffineTransform,
                           focus: Set<String>?, byID: [String: GraphSnapshot.Node]) {
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
            // A test→code link with a known run result glows in its
            // outcome colour — green passing, red failing, amber mixed.
            let testColor = testLinkColor(edge, byID: byID)

            let color: Color, width: CGFloat, arrow: Bool, glow: Bool
            if cyclesOnly && !isCyclic {
                color = .secondary.opacity(0.04); width = 0.5; arrow = false; glow = false
            } else if let testColor, focus == nil || inFocus {
                color = testColor; width = 1.5; arrow = touchesSelection; glow = true
            } else if isCyclic {
                color = .orange.opacity(inFocus ? 0.9 : 0.55); width = 2
                arrow = touchesSelection; glow = false
            } else if focus != nil && !inFocus {
                color = .secondary.opacity(0.05); width = 0.5; arrow = false; glow = false
            } else if touchesSelection {
                color = .accentColor.opacity(0.9); width = 2; arrow = true; glow = false
            } else if testIDs.contains(edge.from) || testIDs.contains(edge.to) {
                color = .blue.opacity(0.4); width = 1; arrow = false; glow = false
            } else {
                color = .secondary.opacity(focus == nil ? 0.25 : 0.4); width = 1
                arrow = false; glow = false
            }

            // Heavier reference edges draw thicker — log-scaled so an
            // 80× edge is bold, not a slab. Structural edges (weight 1)
            // are unaffected.
            let weighted = width + min(CGFloat(log2(Double(max(edge.weight, 1)) + 1)) * 0.6, 4)

            var path = Path()
            path.move(to: from); path.addLine(to: to)
            if glow {   // phosphor: a soft wide underlay + a bright core.
                context.stroke(path, with: .color(color.opacity(0.3)), lineWidth: weighted + 3)
            }
            context.stroke(path, with: .color(color), lineWidth: weighted)
            if arrow { drawArrowhead(context: context, from: from, to: to,
                                     radius: nodeRadius(id: edge.to), color: color) }
        }
    }

    /// If this edge is a reference from test code to the code it
    /// exercises and we know that test class's last outcome, the
    /// phosphor colour for the link.
    private func testLinkColor(_ edge: GraphSnapshot.Edge,
                               byID: [String: GraphSnapshot.Node]) -> Color? {
        guard edge.kind == "core:refersToSymbol",
              let source = byID[edge.from], GraphScene.isTest(source),
              let target = byID[edge.to], !GraphScene.isTest(target) else { return nil }
        let testClass = source.label.split(separator: ".").first.map(String.init) ?? source.label
        switch store.testResults[testClass] {
        case .passed: return .green
        case .failed: return .red
        case .partial: return .yellow
        case nil: return nil
        }
    }

    private func coverageColor(_ fraction: Double) -> Color {
        Color(hue: 0.33 * fraction, saturation: 0.85, brightness: 0.85)
    }

    // MARK: - Function satellites (expand mode)

    /// Member functions of a node, from the full snapshot's declares
    /// edges — the satellites that orbit it when expanded.
    private func memberFunctions(of id: String) -> [GraphSnapshot.Node] {
        guard let index = store.currentIndex else { return [] }
        return (index.outgoing[id] ?? [])
            .filter { $0.kind == "core:declares" }
            .compactMap { index.byID[$0.to] }
            .filter { $0.kind.hasSuffix(":function") }
            .sorted { ($0.line ?? 0) < ($1.line ?? 0) }
    }

    /// Every function satellite's screen position, keyed for both
    /// drawing and hit-testing so a click lands on the same dot the
    /// eye sees. Orbit radius grows a little with the parent so its
    /// own ring/label clears the satellites.
    private func satellites(in size: CGSize) -> [(node: GraphSnapshot.Node, at: CGPoint,
                                                  parent: CGPoint, parentSelected: Bool)] {
        let transform = viewTransform(in: size)
        // When Expand is off, only the selected node expands.
        let parents = expandFunctions ? scene.nodes
            : scene.nodes.filter { $0.id == store.selectedNode }
        var result: [(GraphSnapshot.Node, CGPoint, CGPoint, Bool)] = []
        for node in parents {
            guard let position = frame.positions[node.id] else { continue }
            let functions = memberFunctions(of: node.id)
            guard !functions.isEmpty else { continue }
            let center = CGPoint(x: position.x, y: position.y).applying(transform)
            // The selected node's ring is roomier so its labels don't
            // collide; more functions push the radius out further.
            let selected = node.id == store.selectedNode
            let base: CGFloat = selected ? 34 : 16
            let orbit = nodeRadius(node) + base + CGFloat(functions.count) * (selected ? 3 : 1)
            for (i, function) in functions.enumerated() {
                let angle = 2 * .pi * Double(i) / Double(functions.count) - .pi / 2
                let at = CGPoint(x: center.x + orbit * cos(angle),
                                 y: center.y + orbit * sin(angle))
                result.append((function, at, center, selected))
            }
        }
        return result
    }

    private func drawSatellites(context: GraphicsContext, in size: CGSize,
                                transform: CGAffineTransform, focus: Set<String>?) {
        let showLabels = labelMode != .off && currentScale(in: size) > 1.2
        for (function, at, parent, parentSelected) in satellites(in: size) {
            let dimmed = focus != nil && !focus!.contains(function.id)
            let coverageFraction = activeCoverage?.functionFraction(
                path: function.path, line: function.line)
            let fill = coverageFraction.map(coverageColor) ?? .secondary
            // A thin tether to the parent, then the satellite dot.
            var tether = Path()
            tether.move(to: parent); tether.addLine(to: at)
            context.stroke(tether, with: .color(.secondary.opacity(dimmed ? 0.05 : 0.2)),
                           lineWidth: 0.5)
            let selected = function.id == store.selectedNode
            let r: CGFloat = selected ? 4 : 2.8
            context.fill(Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: r * 2, height: r * 2)),
                         with: .color(fill.opacity(dimmed ? 0.25 : 1)))
            if selected {
                context.stroke(Path(ellipseIn: CGRect(x: at.x - r - 2, y: at.y - r - 2,
                                                       width: (r + 2) * 2, height: (r + 2) * 2)),
                               with: .color(.accentColor), lineWidth: 1.5)
            }
            // The selected node's satellites always label (the point of
            // selecting is to read its functions); others follow zoom.
            if (parentSelected || showLabels || selected) && !dimmed {
                context.draw(Text(function.label).font(.system(size: labelSize - 1)),
                             at: CGPoint(x: at.x, y: at.y - r - 6))
            }
        }
    }

    /// Per-function coverage for a class-like node: its member
    /// functions' fractions, or nil when the node isn't a type or its
    /// file wasn't instrumented (fall back to a single-arc halo).
    private func functionRing(for node: GraphSnapshot.Node) -> [Double]? {
        guard node.kind.hasSuffix(":type") || node.kind.hasSuffix(":interface")
                || node.kind.hasSuffix(":enumeration"),
              let path = node.path, let index = store.currentIndex,
              let coverage = activeCoverage, coverage.functionsByPath[path] != nil
        else { return nil }
        let functions = (index.outgoing[node.id] ?? [])
            .filter { $0.kind == "core:declares" }
            .compactMap { index.byID[$0.to] }
            .filter { $0.kind.hasSuffix(":function") }
        guard !functions.isEmpty else { return nil }
        return functions
            .sorted { ($0.line ?? 0) < ($1.line ?? 0) }
            .map { coverage.functionFraction(path: $0.path, line: $0.line) ?? 0 }
    }

    /// Draw the segmented function ring: equal arcs, one per function,
    /// small gaps between, each coloured by its own coverage.
    private func drawFunctionRing(context: GraphicsContext, center: CGPoint,
                                  radius: CGFloat, fractions: [Double]) {
        let n = fractions.count
        let gap = min(6.0, 120.0 / Double(n))     // degrees; shrink as count grows
        let span = 360.0 / Double(n)
        for (i, fraction) in fractions.enumerated() {
            let start = -90.0 + Double(i) * span + gap / 2
            let end = -90.0 + Double(i + 1) * span - gap / 2
            var arc = Path()
            arc.addArc(center: center, radius: radius,
                       startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
            context.stroke(arc, with: .color(coverageColor(fraction)),
                           style: StrokeStyle(lineWidth: 3, lineCap: .butt))
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
                           transform: CGAffineTransform, clusters: [String: String],
                           colors: [String: Color], focus: Set<String>?) {
        let showLabels = labelMode == .on
            || (labelMode == .auto && (scene.nodes.count <= 250 || currentScale(in: size) > 1.5))
        for node in scene.nodes {
            guard let position = frame.positions[node.id] else { continue }
            let point = CGPoint(x: position.x, y: position.y).applying(transform)
            let radius = nodeRadius(node)
            let rect = CGRect(x: point.x - radius, y: point.y - radius,
                              width: radius * 2, height: radius * 2)
            let isSelected = node.id == store.selectedNode
            let outsideGroup = explodedGroup != nil
                && GraphPalette.key(for: node, clusters: clusters) != explodedGroup
            let dimmed = (focus != nil && !focus!.contains(node.id)) || outsideGroup
            let fill = GraphPalette.color(for: node, clusters: clusters, in: colors)
            context.fill(Path(ellipseIn: rect),
                         with: .color(fill.opacity(dimmed ? 0.2 : 1)))

            if coverageMode, !dimmed {
                if let ring = functionRing(for: node) {
                    // Per-function coverage: one ring segment per method
                    // of the class, each red→green by its own coverage —
                    // the class's coverage broken out, function by function.
                    drawFunctionRing(context: context, center: point,
                                     radius: radius + 4.5, fractions: ring)
                } else if let fraction = activeCoverage?.fraction(forPath: node.path) {
                    var arc = Path()
                    arc.addArc(center: point, radius: radius + 4.5, startAngle: .degrees(-90),
                               endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
                    context.stroke(arc, with: .color(coverageColor(fraction)),
                                   style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
            }
            if isSelected {
                context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)),
                               with: .color(.accentColor), lineWidth: 2)
            }
            // Everything in the focused blast radius labels, so a
            // selection is fully readable, not just the node itself.
            let inFocus = focus?.contains(node.id) ?? false
            if (showLabels || isSelected || inFocus) && !dimmed {
                context.draw(
                    Text(node.label).font(.system(size: labelSize))
                        .foregroundStyle(isSelected ? Color.primary : .secondary),
                    at: CGPoint(x: point.x, y: point.y - radius - labelSize * 0.7))
            }
        }
    }

    /// Tinted, labeled hull behind each cluster.
    private func drawGroupRegions(context: GraphicsContext, transform: CGAffineTransform,
                                  clusters: [String: String], colors: [String: Color],
                                  focus: Set<String>?) {
        guard grouping != .none else { return }
        var members: [String: [SIMD2<Double>]] = [:]
        for node in scene.nodes {
            guard let position = frame.positions[node.id],
                  let key = clusters[node.id] else { continue }
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

    // MARK: - Focus zoom

    /// Selecting a node frames it: pan+zoom so its blast radius fills
    /// the view with room for labels and its function satellites.
    /// Deselecting leaves the view where it is (double-tap resets).
    private func focusOnSelection() {
        guard let selected = store.selectedNode, viewSize != .zero,
              let index = store.currentIndex else { return }
        let ids = index.neighborhood(of: selected)
        let points = ids.compactMap { frame.positions[$0] }
        guard let anchor = frame.positions[selected] else { return }
        var minX = anchor.x, maxX = anchor.x, minY = anchor.y, maxY = anchor.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let center = SIMD2((minX + maxX) / 2, (minY + maxY) / 2)
        // Extent padded generously so satellite rings and labels clear
        // the edges rather than being cropped.
        let extent = max(maxX - minX, maxY - minY, 120) + 160
        let bounds = layoutBounds()
        let fit = min(viewSize.width / bounds.width, viewSize.height / bounds.height, 2) * 0.9
        let desiredScale = 0.5 * min(viewSize.width, viewSize.height) / extent
        let newZoom = min(max(desiredScale / fit, 0.5), 6)
        let scale = fit * newZoom
        // A smooth spring reads as a camera glide rather than a snap;
        // Canvas re-renders each interpolated step of zoom/pan.
        withAnimation(.smooth(duration: 0.55)) {
            zoom = newZoom
            pan = CGSize(width: scale * (bounds.midX - center.x),
                         height: scale * (bounds.midY - center.y))
        }
    }

    // MARK: - Interaction

    private func select(at location: CGPoint, in size: CGSize) {
        var best: (id: String, distance: CGFloat)?
        // Satellites sit on top — hit-test them first, with a tight
        // radius so they don't steal clicks meant for their parent.
        if expandFunctions || store.selectedNode != nil {
            for entry in satellites(in: size) {
                let distance = hypot(entry.at.x - location.x, entry.at.y - location.y)
                if distance < 6, distance < (best?.distance ?? .infinity) {
                    best = (entry.node.id, distance)
                }
            }
        }
        if best == nil {
            let transform = viewTransform(in: size)
            for node in scene.nodes {
                guard let position = frame.positions[node.id] else { continue }
                let point = CGPoint(x: position.x, y: position.y).applying(transform)
                let distance = hypot(point.x - location.x, point.y - location.y)
                if distance < nodeRadius(node) + 6, distance < (best?.distance ?? .infinity) {
                    best = (node.id, distance)
                }
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
