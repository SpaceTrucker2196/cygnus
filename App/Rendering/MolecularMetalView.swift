import SwiftUI
import MetalKit
import simd
import CygnusKit

// The 3D molecular view.
//
// Metal directly rather than RealityKit, which the renderer rules allow
// as the escape hatch and the CI-flow chart already uses. The reason is
// instancing: this draws one sphere mesh and one bond mesh, N times
// each, from a buffer the CPU refreshes as the layout settles. An
// entity-per-node scene graph is what made the previous 3D attempt cost
// too much memory to keep.
//
// Two GPU traps here were already paid for once (docs/wiki/renderers.md)
// and are not re-learned: geometry goes up through an MTLBuffer, never
// setVertexBytes, which caps at 4 KB and aborts past it; and the view
// draws on demand rather than free-running.
//
// The perf budget S5 asked for, so 3D returning is not another
// open-ended cost: one draw call per pass regardless of node count,
// instance buffers rebuilt only while the layout is unsettled, and the
// view paused the moment it settles. A still scene costs nothing.

struct MolecularMetalView: NSViewRepresentable {
    let scene: MolecularScene
    /// Progressive reveal: nil once fully assembled.
    var onProgress: ((Float) -> Void)?

    func makeCoordinator() -> MolecularRenderer {
        MolecularRenderer(scene: scene, onProgress: onProgress)
    }

    func makeNSView(context: Context) -> MTKView {
        let renderer = context.coordinator
        let view = MolecularMTKView(frame: .zero, device: renderer.device)
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0.043, green: 0.047, blue: 0.063, alpha: 1)
        view.enableSetNeedsDisplay = true
        view.isPaused = true                 // …never a free-running loop
        view.renderer = renderer
        renderer.view = view
        // One nudge to start the assembly; the renderer re-arms itself
        // each frame until the layout settles, then stops.
        view.needsDisplay = true
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.update(scene: scene)
        view.needsDisplay = true
    }
}

/// Turns drags into orbit and scrolls into zoom.
final class MolecularMTKView: MTKView {
    weak var renderer: MolecularRenderer?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDragged(with event: NSEvent) {
        renderer?.orbit(dx: Float(event.deltaX), dy: Float(event.deltaY))
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        renderer?.zoom(by: Float(event.scrollingDeltaY))
        needsDisplay = true
    }
}

final class MolecularRenderer: NSObject, MTKViewDelegate {
    let device: any MTLDevice
    weak var view: MTKView?

    private let queue: any MTLCommandQueue
    private var atomPipeline: (any MTLRenderPipelineState)!
    private var bondPipeline: (any MTLRenderPipelineState)!
    private var depthState: (any MTLDepthStencilState)!

    private var scene: MolecularScene
    private var layout: Layout3D
    private let onProgress: ((Float) -> Void)?

    // Geometry, uploaded once.
    private var sphereVertices: (any MTLBuffer)!
    private var sphereIndexCount = 0
    private var sphereIndices: (any MTLBuffer)!

    // Instances, refreshed while the layout moves.
    private var atomInstances: (any MTLBuffer)?
    private var bondInstances: (any MTLBuffer)?
    private var atomCount = 0
    private var bondCount = 0

    private var yaw: Float = 0.6
    private var pitch: Float = 0.35
    private var distance: Float = 90

    /// How much of the scene has appeared so far. The reveal is what
    /// makes a large repository feel like it is assembling rather than
    /// hanging — the first atoms are visible in frame one.
    private var revealed: Float = 0

    init(scene: MolecularScene, onProgress: ((Float) -> Void)?) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("Metal is unavailable on this device")
        }
        self.device = device
        self.queue = queue
        self.scene = scene
        self.layout = Layout3D(scene: scene)
        self.onProgress = onProgress
        super.init()
        buildPipelines()
        buildSphere()
        distance = max(45, layout.extent * 2.6)
    }

    func update(scene: MolecularScene) {
        guard scene != self.scene else { return }
        self.scene = scene
        layout = Layout3D(scene: scene)
        revealed = 0
        atomInstances = nil
        bondInstances = nil
        distance = max(45, layout.extent * 2.6)
    }

    func orbit(dx: Float, dy: Float) {
        yaw += dx * 0.01
        pitch = simd_clamp(pitch + dy * 0.01, -1.5, 1.5)
    }

    func zoom(by delta: Float) {
        distance = simd_clamp(distance * (1 - delta * 0.02), 6, 4000)
    }

    // MARK: - Frame

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        // Advance the layout by one slice per frame, and reveal a
        // little more of the scene. Both are bounded, so a frame costs
        // the same whether the repository has 50 atoms or 5,000.
        let moving = layout.step()
        revealed = min(1, revealed + 0.035)
        if moving || revealed < 1 { rebuildInstances() }

        let size = view.drawableSize
        let aspect = Float(max(size.width, 1) / max(size.height, 1))
        var uniforms = Uniforms(
            viewProjection: viewProjectionMatrix(aspect: aspect),
            cameraPosition: cameraPosition(),
            lightDirection: simd_normalize(SIMD3<Float>(0.4, 0.8, 0.5)))

        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.back)

        if bondCount > 0, let instances = bondInstances {
            encoder.setRenderPipelineState(bondPipeline)
            encoder.setVertexBuffer(instances, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            // Bonds are camera-facing quads: cheaper than cylinders and
            // indistinguishable at the widths a bond is ever drawn.
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                   vertexCount: 6, instanceCount: bondCount)
        }

        if atomCount > 0, let instances = atomInstances {
            encoder.setRenderPipelineState(atomPipeline)
            encoder.setVertexBuffer(sphereVertices, offset: 0, index: 0)
            encoder.setVertexBuffer(instances, offset: 0, index: 2)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawIndexedPrimitives(
                type: .triangle, indexCount: sphereIndexCount, indexType: .uint16,
                indexBuffer: sphereIndices, indexBufferOffset: 0,
                instanceCount: atomCount)
        }

        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()

        onProgress?(min(layout.progress, revealed))
        // Re-arm only while there is something left to do. The moment
        // the layout settles and the scene is fully revealed, the view
        // goes quiet and costs nothing until the user moves it.
        if moving || revealed < 1 { view.needsDisplay = true }
    }

    // MARK: - Instances

    /// Rebuild the instance buffers from the current layout.
    ///
    /// Atoms appear in molecule order, so the reveal reads as one group
    /// assembling after another rather than as random noise resolving.
    private func rebuildInstances() {
        let visible = Int(Float(scene.atoms.count) * revealed)
        guard visible > 0 else { atomCount = 0; bondCount = 0; return }

        var atoms: [AtomInstance] = []
        atoms.reserveCapacity(visible)
        for index in 0..<visible {
            let atom = scene.atoms[index]
            atoms.append(AtomInstance(
                position: layout.positions[index],
                radius: atom.radius,
                color: Self.color(forMolecule: atom.molecule,
                                  of: max(scene.molecules.count, 1))))
        }
        atomInstances = device.makeBuffer(bytes: atoms,
                                          length: MemoryLayout<AtomInstance>.stride * atoms.count,
                                          options: .storageModeShared)
        atomCount = atoms.count

        var bonds: [BondInstance] = []
        bonds.reserveCapacity(scene.bonds.count)
        for bond in scene.bonds where bond.from < visible && bond.to < visible {
            bonds.append(BondInstance(
                from: layout.positions[bond.from],
                to: layout.positions[bond.to],
                // Internal bonds read as structure, external as strain.
                width: bond.isInternal ? 0.16 : 0.07,
                alpha: bond.isInternal ? 0.85 : 0.4))
        }
        bondInstances = bonds.isEmpty ? nil
            : device.makeBuffer(bytes: bonds,
                                length: MemoryLayout<BondInstance>.stride * bonds.count,
                                options: .storageModeShared)
        bondCount = bonds.count
    }

    /// Golden-angle hues: adjacent molecules never share a colour, and
    /// the palette is stable for a given molecule index.
    static func color(forMolecule index: Int, of count: Int) -> SIMD3<Float> {
        let hue = Float(index) * 0.618_034
        return hsv(hue.truncatingRemainder(dividingBy: 1), 0.55, 0.95)
    }

    static func hsv(_ h: Float, _ s: Float, _ v: Float) -> SIMD3<Float> {
        let i = Int(h * 6)
        let f = h * 6 - Float(i)
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i % 6 {
        case 0: return SIMD3(v, t, p)
        case 1: return SIMD3(q, v, p)
        case 2: return SIMD3(p, v, t)
        case 3: return SIMD3(p, q, v)
        case 4: return SIMD3(t, p, v)
        default: return SIMD3(v, p, q)
        }
    }

    // MARK: - Camera

    private func cameraPosition() -> SIMD3<Float> {
        let centroid = layout.positions.isEmpty ? SIMD3<Float>.zero
            : layout.positions.reduce(SIMD3<Float>.zero, +) / Float(layout.positions.count)
        return centroid + SIMD3(cosf(pitch) * sinf(yaw), sinf(pitch),
                                cosf(pitch) * cosf(yaw)) * distance
    }

    private func viewProjectionMatrix(aspect: Float) -> simd_float4x4 {
        let centroid = layout.positions.isEmpty ? SIMD3<Float>.zero
            : layout.positions.reduce(SIMD3<Float>.zero, +) / Float(layout.positions.count)
        let eye = cameraPosition()
        let forward = simd_normalize(centroid - eye)
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), forward))
        let up = simd_cross(forward, right)

        let viewMatrix = simd_float4x4(
            SIMD4(right.x, up.x, forward.x, 0),
            SIMD4(right.y, up.y, forward.y, 0),
            SIMD4(right.z, up.z, forward.z, 0),
            SIMD4(-simd_dot(right, eye), -simd_dot(up, eye), -simd_dot(forward, eye), 1))

        let fov: Float = 0.9
        let near: Float = 0.5, far: Float = 8000
        let yScale = 1 / tanf(fov * 0.5)
        let projection = simd_float4x4(
            SIMD4(yScale / aspect, 0, 0, 0),
            SIMD4(0, yScale, 0, 0),
            SIMD4(0, 0, far / (far - near), 1),
            SIMD4(0, 0, -near * far / (far - near), 0))
        return projection * viewMatrix
    }

    // MARK: - Setup

    private func buildPipelines() {
        let library: any MTLLibrary
        do { library = try device.makeLibrary(source: Self.shaderSource, options: nil) }
        catch { fatalError("molecular shaders failed to compile: \(error)") }

        func pipeline(_ vertex: String, _ fragment: String,
                      blending: Bool) -> any MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.depthAttachmentPixelFormat = .depth32Float
            if blending {
                descriptor.colorAttachments[0].isBlendingEnabled = true
                descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            }
            return try! device.makeRenderPipelineState(descriptor: descriptor)
        }
        atomPipeline = pipeline("atomVertex", "atomFragment", blending: false)
        bondPipeline = pipeline("bondVertex", "bondFragment", blending: true)

        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .less
        depth.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depth)
    }

    /// A low-poly icosphere, uploaded once and instanced. Detail beyond
    /// this is invisible at the size an atom is ever drawn, and every
    /// extra triangle is multiplied by the instance count.
    private func buildSphere() {
        var vertices: [SIMD3<Float>] = []
        var indices: [UInt16] = []
        let stacks = 8, slices = 12
        for stack in 0...stacks {
            let phi = Float.pi * Float(stack) / Float(stacks)
            for slice in 0...slices {
                let theta = 2 * Float.pi * Float(slice) / Float(slices)
                vertices.append(SIMD3(sinf(phi) * cosf(theta), cosf(phi),
                                      sinf(phi) * sinf(theta)))
            }
        }
        for stack in 0..<stacks {
            for slice in 0..<slices {
                let a = UInt16(stack * (slices + 1) + slice)
                let b = UInt16(a + UInt16(slices) + 1)
                indices += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        sphereVertices = device.makeBuffer(bytes: vertices,
                                           length: MemoryLayout<SIMD3<Float>>.stride * vertices.count,
                                           options: .storageModeShared)
        sphereIndices = device.makeBuffer(bytes: indices,
                                          length: MemoryLayout<UInt16>.stride * indices.count,
                                          options: .storageModeShared)
        sphereIndexCount = indices.count
    }

    // MARK: - Types shared with the shaders

    struct Uniforms {
        var viewProjection: simd_float4x4
        var cameraPosition: SIMD3<Float>
        var lightDirection: SIMD3<Float>
    }

    struct AtomInstance {
        var position: SIMD3<Float>
        var radius: Float
        var color: SIMD3<Float>
    }

    struct BondInstance {
        var from: SIMD3<Float>
        var to: SIMD3<Float>
        var width: Float
        var alpha: Float
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4x4 viewProjection;
        packed_float3 cameraPosition;
        packed_float3 lightDirection;
    };

    struct AtomInstance {
        packed_float3 position;
        float radius;
        packed_float3 color;
    };

    struct BondInstance {
        packed_float3 from;
        packed_float3 to;
        float width;
        float alpha;
    };

    struct AtomOut {
        float4 position [[position]];
        float3 normal;
        float3 color;
    };

    vertex AtomOut atomVertex(uint vid [[vertex_id]],
                              uint iid [[instance_id]],
                              const device packed_float3 *mesh [[buffer(0)]],
                              constant Uniforms &uniforms [[buffer(1)]],
                              const device AtomInstance *instances [[buffer(2)]]) {
        AtomInstance instance = instances[iid];
        float3 local = float3(mesh[vid]);
        float3 world = float3(instance.position) + local * instance.radius;
        AtomOut out;
        out.position = uniforms.viewProjection * float4(world, 1);
        out.normal = normalize(local);
        out.color = float3(instance.color);
        return out;
    }

    fragment float4 atomFragment(AtomOut in [[stage_in]],
                                 constant Uniforms &uniforms [[buffer(1)]]) {
        float3 light = normalize(float3(uniforms.lightDirection));
        // Half-lambert: keeps unlit faces readable instead of black,
        // which matters when a molecule occludes its own far side.
        float diffuse = saturate(dot(in.normal, light)) * 0.5 + 0.5;
        float rim = pow(1.0 - saturate(dot(in.normal, float3(0, 0, -1))), 2.0) * 0.25;
        return float4(in.color * diffuse + rim, 1.0);
    }

    struct BondOut {
        float4 position [[position]];
        float alpha;
    };

    vertex BondOut bondVertex(uint vid [[vertex_id]],
                              uint iid [[instance_id]],
                              const device BondInstance *instances [[buffer(0)]],
                              constant Uniforms &uniforms [[buffer(1)]]) {
        BondInstance bond = instances[iid];
        float3 from = float3(bond.from), to = float3(bond.to);
        float3 axis = to - from;

        // A camera-facing quad: expand perpendicular to both the bond
        // axis and the view direction, so the bond keeps its width from
        // every angle without needing a cylinder's triangles.
        float3 midpoint = (from + to) * 0.5;
        float3 toCamera = normalize(float3(uniforms.cameraPosition) - midpoint);
        float3 side = normalize(cross(normalize(axis), toCamera)) * bond.width;

        float2 corners[6] = { float2(0,-1), float2(1,-1), float2(0,1),
                              float2(0,1),  float2(1,-1), float2(1,1) };
        float2 corner = corners[vid];
        float3 world = from + axis * corner.x + side * corner.y;

        BondOut out;
        out.position = uniforms.viewProjection * float4(world, 1);
        out.alpha = bond.alpha;
        return out;
    }

    fragment float4 bondFragment(BondOut in [[stage_in]]) {
        return float4(0.62, 0.68, 0.78, in.alpha);
    }
    """
}
