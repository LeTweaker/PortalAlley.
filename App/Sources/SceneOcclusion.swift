import ARKit
import Foundation
import PortalCore
import RealityKit

/// LiDAR enhancement: real objects BETWEEN the viewer and the doorway hide the
/// doorway and the view through it.
///
/// RealityKit's built-in scene occlusion is deliberately NOT used: it would let
/// the real wall behind the doorway erase the destination (the alley is many
/// metres "inside" that wall).  Instead, reconstructed triangles are filtered
/// in portal space and only room-side geometry becomes an occluder:
///   * keep triangles entirely in front of the aperture plane,
///   * drop floor-level triangles (the floor never needs to occlude and its
///     noise would nibble the threshold),
///   * drop anything inside the doorway's own volume (reconstruction noise).
@MainActor
final class SceneOcclusion {
    let root = Entity()
    private var entities: [UUID: ModelEntity] = [:]
    private var triCounts: [UUID: Int] = [:]
    private var dirty: Set<UUID> = []
    private var lastBuild: TimeInterval = 0
    private let material = OcclusionMaterial()
    private let volume = DoorwayVolume()
    var dims = PortalDimensions()
    /// Floor / ceiling portal: the mounting surface is the aperture plane
    /// itself, so drop everything near that plane (not just the room floor).
    var horizontal = false
    private(set) var triangleCount = 0
    private(set) var rebuilds = 0

    var enabled = false {
        didSet { root.isEnabled = enabled }
    }

    init() { root.name = "SceneOcclusion"; root.isEnabled = false }

    func markDirty(_ id: UUID) { dirty.insert(id) }

    func remove(_ id: UUID) {
        entities[id]?.removeFromParent()
        entities[id] = nil
        triangleCount -= triCounts[id] ?? 0
        triCounts[id] = nil
        dirty.remove(id)
    }

    func reset() {
        for e in entities.values { e.removeFromParent() }
        entities.removeAll()
        triCounts.removeAll()
        dirty.removeAll()
        triangleCount = 0
    }

    /// Rebuilds at most one dirty mesh anchor per call (bounded per-frame cost).
    func update(meshAnchors: [ARMeshAnchor], portalWorld: simd_float4x4, now: TimeInterval) {
        guard enabled, now - lastBuild > 0.25, !dirty.isEmpty else { return }
        let origin = PortalMath.translation(portalWorld)
        guard let anchor = meshAnchors.first(where: { dirty.contains($0.identifier) && simd_distance(PortalMath.translation($0.transform), origin) < 6 }) else {
            // dirty anchors far away: forget them
            let near = Set(meshAnchors.filter { simd_distance(PortalMath.translation($0.transform), origin) < 6 }.map(\.identifier))
            dirty = dirty.intersection(near)
            return
        }
        dirty.remove(anchor.identifier)
        lastBuild = now
        rebuilds += 1
        let oldTris = triCounts[anchor.identifier] ?? 0
        guard let (mesh, tris) = Self.buildMesh(anchor, portalWorld: portalWorld, dims: dims, volume: volume, horizontal: horizontal) else {
            remove(anchor.identifier)
            return
        }
        if let e = entities[anchor.identifier] {
            e.model?.mesh = mesh
        } else {
            let e = ModelEntity(mesh: mesh, materials: [material])
            root.addChild(e)
            entities[anchor.identifier] = e
        }
        triCounts[anchor.identifier] = tris
        triangleCount += tris - oldTris
    }

    static func buildMesh(_ a: ARMeshAnchor, portalWorld: simd_float4x4, dims: PortalDimensions, volume: DoorwayVolume,
                          horizontal: Bool = false) -> (MeshResource, Int)? {
        let g = a.geometry
        let vs = g.vertices
        let vbase = vs.buffer.contents()
        var local = [SIMD3<Float>](repeating: .zero, count: vs.count)
        for i in 0..<vs.count {
            let p = vbase.advanced(by: vs.offset + vs.stride * i).assumingMemoryBound(to: Float.self)
            let w = a.transform * SIMD4<Float>(p[0], p[1], p[2], 1)
            local[i] = PortalMath.toPortalSpace(SIMD3(w.x, w.y, w.z), portal: portalWorld)
        }
        let faces = g.faces
        let fbase = faces.buffer.contents()
        let bpi = faces.bytesPerIndex
        func index(_ k: Int) -> Int {
            bpi == 4 ? Int(fbase.load(fromByteOffset: k * 4, as: UInt32.self)) : Int(fbase.load(fromByteOffset: k * 2, as: UInt16.self))
        }
        // wall: anything behind the aperture plane; floor/ceiling: also the
        // reconstruction noise of the surface the opening is cut into
        let minZ = horizontal ? dims.occluderZ + 0.06 : dims.frameBackZ + 0.02
        var remap = [Int32](repeating: -1, count: vs.count)
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for f in 0..<faces.count {
            let i0 = index(3 * f), i1 = index(3 * f + 1), i2 = index(3 * f + 2)
            let a0 = local[i0], a1 = local[i1], a2 = local[i2]
            if a0.z < minZ || a1.z < minZ || a2.z < minZ { continue }                 // behind the aperture plane
            if !horizontal && a0.y < 0.10 && a1.y < 0.10 && a2.y < 0.10 { continue }  // room floor (wall portals)
            if volume.contains(a0) || volume.contains(a1) || volume.contains(a2) { continue }
            for i in [i0, i1, i2] {
                if remap[i] < 0 { remap[i] = Int32(positions.count); positions.append(local[i]) }
                indices.append(UInt32(remap[i]))
            }
        }
        guard !indices.isEmpty else { return nil }
        var d = MeshDescriptor(name: "occ.\(a.identifier.uuidString.prefix(6))")
        d.positions = MeshBuffers.Positions(positions)
        d.primitives = .triangles(indices)
        guard let mesh = try? MeshResource.generate(from: [d]) else { return nil }
        return (mesh, indices.count / 3)
    }
}
