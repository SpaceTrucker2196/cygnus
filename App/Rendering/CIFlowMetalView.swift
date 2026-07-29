import SwiftUI
import MetalKit
import CoreText
import CygnusKit

// A CI/build flow (fastlane or make), drawn with Metal — the
// sanctioned escape hatch (AGENTS.md) for GPU rendering. Every path is
// a row: entry → group → its ordered steps, with calls/prerequisites
// wired across. Nodes are SDF rounded-rects, edges are arrowed line
// quads, labels are CoreText rasterized into per-node textures. The
// view is paused and draws only on demand (flow change, resize, pan,
// zoom, select) — no render loop, so it costs nothing when idle.

struct CIFlowMetalView: NSViewRepresentable {
    let flow: CIFlow
    @Binding var selection: String?

    func makeCoordinator() -> FlowRenderer { FlowRenderer() }

    func makeNSView(context: Context) -> MTKView {
        let renderer = context.coordinator
        let view = FlowMTKView(frame: .zero, device: renderer.device)
        view.renderer = renderer
        view.delegate = renderer
        view.enableSetNeedsDisplay = true      // draw on demand…
        view.isPaused = true                   // …never a free-running loop
        view.framebufferOnly = true
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.055, green: 0.065, blue: 0.085, alpha: 1)
        view.layer?.isOpaque = true
        renderer.onSelect = { id in selection = id }
        renderer.setFlow(flow)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        let renderer = context.coordinator
        if renderer.flow != flow { renderer.setFlow(flow) }
        renderer.selection = selection
        view.needsDisplay = true
    }
}

/// MTKView subclass that turns mouse gestures into pan / zoom / select.
final class FlowMTKView: MTKView {
    weak var renderer: FlowRenderer?
    private var didFit = false

    override var isFlipped: Bool { true }   // top-left origin, like content space
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        // First layout with a real size: fit the whole chart in view.
        if !didFit, bounds.width > 1, let renderer, !renderer.flow.isEmpty {
            renderer.fit(viewSize: bounds.size)
            didFit = true
            needsDisplay = true
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let renderer else { return }
        let factor = 1.0 - Double(event.scrollingDeltaY) * 0.005
        let p = convert(event.locationInWindow, from: nil)
        renderer.zoom(by: factor, around: p, viewSize: bounds.size)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let renderer else { return }
        let p = convert(event.locationInWindow, from: nil)
        renderer.select(atViewPoint: p, viewSize: bounds.size)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let renderer else { return }
        renderer.pan(byViewDelta: CGSize(width: event.deltaX, height: event.deltaY),
                     viewSize: bounds.size)
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        guard let renderer else { return }
        let p = convert(event.locationInWindow, from: nil)
        renderer.zoom(by: 1 + event.magnification, around: p, viewSize: bounds.size)
        needsDisplay = true
    }
}

@MainActor
final class FlowRenderer: NSObject, MTKViewDelegate {
    let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let nodePipeline: any MTLRenderPipelineState
    private let edgePipeline: any MTLRenderPipelineState
    private let labelPipeline: any MTLRenderPipelineState
    private let sampler: any MTLSamplerState

    private(set) var flow = CIFlow(nodes: [], edges: [])
    var selection: String? { didSet { if selection != oldValue { /* redraw driven by view */ } } }
    var onSelect: ((String?) -> Void)?

    // View transform: content points → drawable pixels.
    private var zoomLevel: CGFloat = 1     // pixels per content point
    private var pan = CGPoint(x: 0, y: 0)  // content point shown at top-left

    // Laid-out geometry in content-point space.
    private var placed: [PlacedNode] = []
    private var contentSize = CGSize.zero
    private var labelTextures: [String: any MTLTexture] = [:]

    private struct PlacedNode {
        let node: CIFlow.Node
        var rect: CGRect            // content-point space
        let labelSize: CGSize       // logical points
    }

    // MARK: Setup

    override init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("Metal is unavailable")
        }
        self.device = device
        self.queue = queue
        let library: any MTLLibrary
        do { library = try device.makeLibrary(source: Self.shaderSource, options: nil) }
        catch { fatalError("flow shader compile failed: \(error)") }

        func pipeline(_ vfn: String, _ ffn: String, premultiplied: Bool) -> any MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vfn)
            d.fragmentFunction = library.makeFunction(name: ffn)
            let c = d.colorAttachments[0]!
            c.pixelFormat = .bgra8Unorm
            c.isBlendingEnabled = true
            c.rgbBlendOperation = .add; c.alphaBlendOperation = .add
            c.sourceRGBBlendFactor = premultiplied ? .one : .sourceAlpha
            c.sourceAlphaBlendFactor = premultiplied ? .one : .sourceAlpha
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return (try? device.makeRenderPipelineState(descriptor: d))!
        }
        nodePipeline = pipeline("node_vertex", "node_frag", premultiplied: false)
        edgePipeline = pipeline("edge_vertex", "edge_frag", premultiplied: false)
        labelPipeline = pipeline("label_vertex", "label_frag", premultiplied: true)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
        sampler = device.makeSamplerState(descriptor: sd)!
        super.init()
    }

    // MARK: Layout

    func setFlow(_ flow: CIFlow) {
        self.flow = flow
        labelTextures.removeAll()
        layoutNodes()
    }

    private func layoutNodes() {
        placed.removeAll()
        guard !flow.isEmpty else { contentSize = .zero; return }

        let margin: CGFloat = 28, colGap: CGFloat = 46, rowGap: CGFloat = 16
        let nodeH: CGFloat = 34, padX: CGFloat = 12, minW: CGFloat = 58

        // Measure every label, size each node, find each column's width.
        var sizes: [CGSize] = []
        var nodeW: [CGFloat] = []
        var columnWidth: [Int: CGFloat] = [:]
        for node in flow.nodes {
            let s = Self.measure(node.label)
            sizes.append(s)
            let w = max(minW, s.width + 2 * padX)
            nodeW.append(w)
            columnWidth[node.column] = max(columnWidth[node.column] ?? 0, w)
        }
        let maxCol = flow.columns - 1
        var columnX: [CGFloat] = []
        var x = margin
        for c in 0...max(maxCol, 0) {
            columnX.append(x)
            x += (columnWidth[c] ?? minW) + colGap
        }
        let totalW = x - colGap + margin

        var maxY: CGFloat = 0
        for (i, node) in flow.nodes.enumerated() {
            let px = columnX[node.column]
            let py = margin + CGFloat(node.row) * (nodeH + rowGap)
            let rect = CGRect(x: px, y: py, width: nodeW[i], height: nodeH)
            placed.append(PlacedNode(node: node, rect: rect, labelSize: sizes[i]))
            maxY = max(maxY, rect.maxY)
        }
        contentSize = CGSize(width: totalW, height: maxY + margin)
    }

    // MARK: View transform

    func fit(viewSize: CGSize) {
        guard contentSize.width > 0, viewSize.width > 0 else { return }
        let px = pixelScale(viewSize)
        let vw = viewSize.width * px, vh = viewSize.height * px
        let z = min(vw / contentSize.width, vh / contentSize.height)
        zoomLevel = min(max(z, 0.2), 3)
        // Center the content.
        pan.x = (contentSize.width - vw / zoomLevel) / 2
        pan.y = (contentSize.height - vh / zoomLevel) / 2
    }

    func zoom(by factor: CGFloat, around viewPoint: CGPoint, viewSize: CGSize) {
        let px = pixelScale(viewSize)
        let before = contentPoint(viewPoint: viewPoint, pixelScale: px)
        zoomLevel = min(max(zoomLevel * factor, 0.15), 6)
        let after = contentPoint(viewPoint: viewPoint, pixelScale: px)
        pan.x += before.x - after.x
        pan.y += before.y - after.y
    }

    func pan(byViewDelta delta: CGSize, viewSize: CGSize) {
        let px = pixelScale(viewSize)
        pan.x -= delta.width * px / zoomLevel
        pan.y -= delta.height * px / zoomLevel
    }

    func select(atViewPoint viewPoint: CGPoint, viewSize: CGSize) {
        let p = contentPoint(viewPoint: viewPoint, pixelScale: pixelScale(viewSize))
        let hit = placed.last { $0.rect.contains(p) }?.node.id
        selection = hit
        onSelect?(hit)
    }

    private func pixelScale(_ viewSize: CGSize) -> CGFloat {
        contentScaleGuess
    }
    // Backing scale captured at draw time (drawableSize / bounds).
    private var contentScaleGuess: CGFloat = 2

    private func contentPoint(viewPoint: CGPoint, pixelScale px: CGFloat) -> CGPoint {
        CGPoint(x: pan.x + viewPoint.x * px / zoomLevel,
                y: pan.y + viewPoint.y * px / zoomLevel)
    }

    // MARK: Draw

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let drawable = view.currentDrawable
        let pass = view.currentRenderPassDescriptor
        guard let drawable, let pass,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        let W = Float(view.drawableSize.width), H = Float(view.drawableSize.height)
        if view.bounds.width > 0 { contentScaleGuess = view.drawableSize.width / view.bounds.width }

        if !placed.isEmpty, W > 0, H > 0 {
            drawEdges(encoder, W: W, H: H)
            drawNodes(encoder, W: W, H: H)
            drawLabels(encoder, W: W, H: H)
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    /// content point → drawable-pixel.
    private func toPixel(_ x: CGFloat, _ y: CGFloat) -> SIMD2<Float> {
        SIMD2(Float((x - pan.x) * zoomLevel), Float((y - pan.y) * zoomLevel))
    }
    private func toClip(_ p: SIMD2<Float>, _ W: Float, _ H: Float) -> SIMD2<Float> {
        SIMD2(p.x / (W / 2) - 1, 1 - p.y / (H / 2))
    }

    private func drawNodes(_ encoder: any MTLRenderCommandEncoder, W: Float, H: Float) {
        var verts: [NodeVertex] = []
        verts.reserveCapacity(placed.count * 6)
        let z = Float(zoomLevel)
        for pn in placed {
            let (fill, border) = palette(pn.node.kind, selected: pn.node.id == selection)
            let r = pn.rect
            let cx = r.midX, cy = r.midY
            let half = SIMD2(Float(r.width / 2) * z, Float(r.height / 2) * z)
            let radius = min(half.x, half.y, 9 * z)
            let corners: [(CGFloat, CGFloat, Float, Float)] = [
                (r.minX, r.minY, -half.x, -half.y), (r.maxX, r.minY, half.x, -half.y),
                (r.maxX, r.maxY, half.x, half.y),   (r.minX, r.minY, -half.x, -half.y),
                (r.maxX, r.maxY, half.x, half.y),   (r.minX, r.maxY, -half.x, half.y),
            ]
            _ = (cx, cy)
            for (px, py, lx, ly) in corners {
                verts.append(NodeVertex(
                    fill: fill, border: border,
                    clipPos: toClip(toPixel(px, py), W, H),
                    localPos: SIMD2(lx, ly), halfSize: half, radius: radius, pad: 0))
            }
        }
        guard !verts.isEmpty else { return }
        encoder.setRenderPipelineState(nodePipeline)
        encoder.setVertexBytes(verts, length: MemoryLayout<NodeVertex>.stride * verts.count, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
    }

    private func drawEdges(_ encoder: any MTLRenderCommandEncoder, W: Float, H: Float) {
        var byID: [String: CGRect] = [:]
        for pn in placed { byID[pn.node.id] = pn.rect }
        var verts: [EdgeVertex] = []
        for edge in flow.edges {
            guard let a = byID[edge.from], let b = byID[edge.to] else { continue }
            // Forward chains exit right / enter left; back-references
            // (sub-lane calls to an earlier column) drop from the
            // bottom into the target's top so they read as a branch.
            let backward = b.minX <= a.minX
            let start: CGPoint = backward
                ? CGPoint(x: a.midX, y: a.maxY) : CGPoint(x: a.maxX, y: a.midY)
            let end: CGPoint = backward
                ? CGPoint(x: b.midX, y: b.minY) : CGPoint(x: b.minX, y: b.midY)
            let color: SIMD4<Float> = backward
                ? SIMD4(1.0, 0.72, 0.30, 0.9) : SIMD4(0.45, 0.52, 0.60, 0.85)
            appendArrow(&verts, from: start, to: end, color: color, W: W, H: H)
        }
        guard !verts.isEmpty else { return }
        encoder.setRenderPipelineState(edgePipeline)
        encoder.setVertexBytes(verts, length: MemoryLayout<EdgeVertex>.stride * verts.count, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
    }

    private func appendArrow(_ verts: inout [EdgeVertex], from: CGPoint, to: CGPoint,
                             color: SIMD4<Float>, W: Float, H: Float) {
        let p0 = toPixel(from.x, from.y), p1 = toPixel(to.x, to.y)
        let dir = p1 - p0
        let len = max(simd_length(dir), 0.001)
        let d = dir / len
        let n = SIMD2(-d.y, d.x)
        let width: Float = 1.6, head: Float = 8 * Float(zoomLevel)
        let shaftEnd = p1 - d * head
        // Shaft quad.
        let a = shaftEnd + n * width, b = shaftEnd - n * width
        let c = p0 + n * width, e = p0 - n * width
        for v in [c, a, b, c, b, e] {
            verts.append(EdgeVertex(color: color, clipPos: toClip(v, W, H)))
        }
        // Arrowhead triangle.
        let base1 = p1 - d * head + n * head * 0.55
        let base2 = p1 - d * head - n * head * 0.55
        for v in [p1, base1, base2] {
            verts.append(EdgeVertex(color: color, clipPos: toClip(v, W, H)))
        }
    }

    private func drawLabels(_ encoder: any MTLRenderCommandEncoder, W: Float, H: Float) {
        encoder.setRenderPipelineState(labelPipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)
        let z = Float(zoomLevel)
        for pn in placed {
            guard let tex = labelTexture(for: pn.node.label) else { continue }
            let lw = pn.labelSize.width, lh = pn.labelSize.height
            let cx = pn.rect.midX, cy = pn.rect.midY
            let hx = Float(lw / 2) * z, hy = Float(lh / 2) * z
            let center = toPixel(cx, cy)
            // Quad corners in pixels; v flipped (CGContext is y-up).
            let quads: [(Float, Float, Float, Float)] = [
                (-hx, -hy, 0, 1), (hx, -hy, 1, 1), (hx, hy, 1, 0),
                (-hx, -hy, 0, 1), (hx, hy, 1, 0), (-hx, hy, 0, 0),
            ]
            var verts: [LabelVertex] = []
            for (ox, oy, u, v) in quads {
                verts.append(LabelVertex(
                    clipPos: toClip(SIMD2(center.x + ox, center.y + oy), W, H),
                    uv: SIMD2(u, v)))
            }
            encoder.setVertexBytes(verts, length: MemoryLayout<LabelVertex>.stride * 6, index: 0)
            encoder.setFragmentTexture(tex, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

    // MARK: Colors

    private func palette(_ kind: CIFlow.NodeKind, selected: Bool) -> (SIMD4<Float>, SIMD4<Float>) {
        let base: SIMD3<Float>
        switch kind {
        case .trigger:  base = SIMD3(0.32, 0.62, 1.0)
        case .lane:     base = SIMD3(0.66, 0.46, 1.0)
        case .action:   base = SIMD3(0.28, 0.86, 0.74)
        case .laneCall: base = SIMD3(1.0, 0.72, 0.30)
        }
        let fillL: Float = selected ? 0.34 : 0.20
        let fill = SIMD4(base * fillL, 1)
        let border = SIMD4(selected ? min(base + 0.15, SIMD3(repeating: 1)) : base, 1)
        return (fill, border)
    }

    // MARK: Label textures (CoreText → MTLTexture)

    private static let labelFont = CTFontCreateWithName(
        "Menlo" as CFString, 12, nil)
    private static let renderScale: CGFloat = 2

    private static func measure(_ text: String) -> CGSize {
        let attr = NSAttributedString(string: text, attributes: [.font: labelFont])
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let w = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return CGSize(width: ceil(w), height: ceil(ascent + descent))
    }

    private func labelTexture(for text: String) -> (any MTLTexture)? {
        if let t = labelTextures[text] { return t }
        guard let t = Self.makeLabelTexture(text, device: device) else { return nil }
        labelTextures[text] = t
        return t
    }

    private static func makeLabelTexture(_ text: String, device: any MTLDevice) -> (any MTLTexture)? {
        let scale = renderScale
        let font = CTFontCreateWithName("Menlo" as CFString, 12 * scale, nil)
        let attr = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.white,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let w = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let padX = 2 * scale
        let width = max(1, Int(ceil(w + 2 * padX)))
        let height = max(1, Int(ceil(ascent + descent)))
        let bytesPerRow = width * 4
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.textPosition = CGPoint(x: padX, y: descent)
        CTLineDraw(line, ctx)
        guard let data = ctx.data else { return nil }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: data, bytesPerRow: bytesPerRow)
        return tex
    }

    // MARK: Vertex layouts (mirrored in the shader)

    private struct NodeVertex {
        var fill: SIMD4<Float>
        var border: SIMD4<Float>
        var clipPos: SIMD2<Float>
        var localPos: SIMD2<Float>
        var halfSize: SIMD2<Float>
        var radius: Float
        var pad: Float
    }
    private struct EdgeVertex {
        var color: SIMD4<Float>
        var clipPos: SIMD2<Float>
    }
    private struct LabelVertex {
        var clipPos: SIMD2<Float>
        var uv: SIMD2<Float>
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct NodeVertex {
        float4 fill;
        float4 border;
        float2 clipPos;
        float2 localPos;
        float2 halfSize;
        float  radius;
        float  pad;
    };
    struct NodeInOut {
        float4 position [[position]];
        float4 fill;
        float4 border;
        float2 localPos;
        float2 halfSize;
        float  radius;
    };
    vertex NodeInOut node_vertex(uint vid [[vertex_id]],
                                 device const NodeVertex* v [[buffer(0)]]) {
        NodeVertex n = v[vid];
        NodeInOut o;
        o.position = float4(n.clipPos, 0, 1);
        o.fill = n.fill; o.border = n.border;
        o.localPos = n.localPos; o.halfSize = n.halfSize; o.radius = n.radius;
        return o;
    }
    static inline float sdRoundBox(float2 p, float2 b, float r) {
        float2 q = abs(p) - b + r;
        return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
    }
    fragment float4 node_frag(NodeInOut in [[stage_in]]) {
        float d = sdRoundBox(in.localPos, in.halfSize, in.radius);
        float aa = fwidth(d) + 0.75;
        float inside = 1.0 - smoothstep(-aa, aa, d);
        float ring = 1.0 - smoothstep(-aa, aa, abs(d) - 1.4);
        float4 col = mix(in.fill, in.border, clamp(ring, 0.0, 1.0));
        col.a *= clamp(inside, 0.0, 1.0);
        return col;
    }

    struct EdgeVertex { float4 color; float2 clipPos; };
    struct EdgeInOut { float4 position [[position]]; float4 color; };
    vertex EdgeInOut edge_vertex(uint vid [[vertex_id]],
                                 device const EdgeVertex* v [[buffer(0)]]) {
        EdgeInOut o;
        o.position = float4(v[vid].clipPos, 0, 1);
        o.color = v[vid].color;
        return o;
    }
    fragment float4 edge_frag(EdgeInOut in [[stage_in]]) { return in.color; }

    struct LabelVertex { float2 clipPos; float2 uv; };
    struct LabelInOut { float4 position [[position]]; float2 uv; };
    vertex LabelInOut label_vertex(uint vid [[vertex_id]],
                                   device const LabelVertex* v [[buffer(0)]]) {
        LabelInOut o;
        o.position = float4(v[vid].clipPos, 0, 1);
        o.uv = v[vid].uv;
        return o;
    }
    fragment float4 label_frag(LabelInOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               sampler s [[sampler(0)]]) {
        return tex.sample(s, in.uv);
    }
    """
}
