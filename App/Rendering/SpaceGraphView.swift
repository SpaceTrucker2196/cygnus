import SwiftUI
import RealityKit
import AppKit
import CygnusKit

// The 3D renderer: RealityKit behind the same scene/layout inputs as
// the Flat view. Nodes are instanced spheres (one shared mesh, one
// material per kind); every edge lives in ONE batched mesh entity —
// never one entity per edge (AGENTS.md).

struct SpaceGraphView: View {
    let scene: GraphScene
    @State private var frame: LayoutFrame3D?

    var body: some View {
        Group {
            if let frame {
                SpaceRenderView(scene: scene, frame: frame)
            } else {
                ProgressView("Laying out…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: scene) {
            frame = nil
            frame = await Layout3D.solve(scene)
        }
        .overlay(alignment: .bottomTrailing) {
            Text("\(scene.nodes.count) nodes · \(scene.edges.count) edges")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(6)
        }
    }
}

struct SpaceRenderView: View {
    @Environment(WorkspaceStore.self) private var store
    let scene: GraphScene
    let frame: LayoutFrame3D

    @State private var yaw: Float = 0.7
    @State private var pitch: Float = 0.35
    @State private var distance: Float = 9
    @State private var dragOrigin: (yaw: Float, pitch: Float)?

    var body: some View {
        RealityView { content in
            let root = GraphSceneBuilder.build(scene: scene, frame: frame)
            root.name = "graph-root"
            content.add(root)

            let camera = PerspectiveCamera()
            camera.name = "camera"
            content.add(camera)

            let highlight = GraphSceneBuilder.highlightEntity()
            highlight.name = "highlight"
            highlight.isEnabled = false
            content.add(highlight)
        } update: { content in
            if let camera = content.entities.first(where: { $0.name == "camera" }) {
                camera.look(at: .zero, from: cameraPosition, relativeTo: nil)
            }
            if let highlight = content.entities.first(where: { $0.name == "highlight" }) {
                if let selected = store.selectedNode,
                   let position = frame.positions[selected] {
                    highlight.isEnabled = true
                    highlight.position = GraphSceneBuilder.scenePoint(position)
                } else {
                    highlight.isEnabled = false
                }
            }
        }
        .gesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    if !value.entity.name.isEmpty {
                        store.selectedNode = value.entity.name
                    }
                })
        .simultaneousGesture(orbitGesture)
        .simultaneousGesture(zoomGesture)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var cameraPosition: SIMD3<Float> {
        let clampedPitch = max(-1.4, min(pitch, 1.4))
        return SIMD3(
            distance * cos(clampedPitch) * sin(yaw),
            distance * sin(clampedPitch),
            distance * cos(clampedPitch) * cos(yaw))
    }

    private var orbitGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let origin = dragOrigin ?? (yaw, pitch)
                dragOrigin = origin
                yaw = origin.yaw - Float(value.translation.width) * 0.008
                pitch = max(-1.4, min(origin.pitch + Float(value.translation.height) * 0.008, 1.4))
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onEnded { value in
                distance = max(2, min(distance / Float(value.magnification), 40))
            }
    }
}

// MARK: - Scene construction

@MainActor
enum GraphSceneBuilder {
    /// Layout coordinates are ~hundreds of points; scene units are
    /// meters-ish. One scale factor everywhere.
    static let worldScale: Float = 1.0 / 100.0

    static func scenePoint(_ position: SIMD3<Double>) -> SIMD3<Float> {
        SIMD3<Float>(Float(position.x), Float(position.y), Float(position.z)) * worldScale
    }

    static func build(scene: GraphScene, frame: LayoutFrame3D) -> Entity {
        let root = Entity()

        // One shared sphere mesh; one material per kind → RealityKit
        // auto-instances the whole node set.
        let sphere = MeshResource.generateSphere(radius: 0.05)
        var materials: [String: UnlitMaterial] = [:]

        for node in scene.nodes {
            guard let position = frame.positions[node.id] else { continue }
            let material = materials[node.kind] ?? UnlitMaterial(color: nsColor(for: node.kind))
            materials[node.kind] = material

            let entity = ModelEntity(mesh: sphere, materials: [material])
            entity.name = node.id
            entity.position = scenePoint(position)
            let scale = 1 + min(Float(scene.degree[node.id] ?? 0).squareRoot() * 0.35, 2.5)
            entity.scale = SIMD3(repeating: scale)
            entity.components.set(InputTargetComponent())
            entity.components.set(CollisionComponent(
                shapes: [.generateSphere(radius: 0.05 * scale + 0.02)]))
            root.addChild(entity)
        }

        if let edgeMesh = edgeMesh(scene: scene, frame: frame) {
            let edges = ModelEntity(
                mesh: edgeMesh,
                materials: [UnlitMaterial(color: NSColor.secondaryLabelColor.withAlphaComponent(0.5))])
            edges.name = ""
            root.addChild(edges)
        }
        return root
    }

    /// All edges baked into one mesh: a thin 4-sided prism per edge,
    /// one entity, one draw call.
    static func edgeMesh(scene: GraphScene, frame: LayoutFrame3D) -> MeshResource? {
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        let halfWidth: Float = 0.006

        for edge in scene.edges {
            guard let fromD = frame.positions[edge.from],
                  let toD = frame.positions[edge.to] else { continue }
            let from = scenePoint(fromD)
            let to = scenePoint(toD)
            let axis = to - from
            let length = simd_length(axis)
            guard length > 0.0001 else { continue }
            let direction = axis / length

            // Orthonormal cross-section basis.
            let reference: SIMD3<Float> = abs(direction.y) < 0.9 ? [0, 1, 0] : [1, 0, 0]
            let u = simd_normalize(simd_cross(direction, reference)) * halfWidth
            let v = simd_normalize(simd_cross(direction, u)) * halfWidth

            let base = UInt32(positions.count)
            for end in [from, to] {
                positions.append(end + u)
                positions.append(end + v)
                positions.append(end - u)
                positions.append(end - v)
            }
            // Four side quads between cross-sections 0-3 and 4-7.
            for i in 0..<4 {
                let a = base + UInt32(i)
                let b = base + UInt32((i + 1) % 4)
                let c = a + 4
                let d = b + 4
                indices.append(contentsOf: [a, b, c, b, d, c])
            }
        }
        guard !positions.isEmpty else { return nil }

        var descriptor = MeshDescriptor(name: "edges")
        descriptor.positions = MeshBuffer(positions)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    static func highlightEntity() -> Entity {
        let entity = ModelEntity(
            mesh: .generateSphere(radius: 0.09),
            materials: [UnlitMaterial(color: NSColor.controlAccentColor.withAlphaComponent(0.35))])
        return entity
    }

    static func nsColor(for kind: String) -> NSColor {
        switch kind {
        case "core:repository": .systemBrown
        case "core:directory": .systemGray
        case "core:file": .labelColor
        case "core:module": .systemPurple
        case "core:type": .systemBlue
        case "core:interface": .systemTeal
        case "core:enumeration": .systemOrange
        case "core:function": .systemGreen
        case "core:variable": .systemGray
        default: .secondaryLabelColor
        }
    }
}
