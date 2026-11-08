import Foundation
import PortalCore
import RealityKit
import UIKit

/// The doorway and its destination as one entity tree in PORTAL SPACE
/// (identity transforms throughout, so shader portal-space maths holds).
///
///   root ─┬─ frameRoot      doorway (PBR, lit by ARKit environment probes),
///         │                 light channel, contact shadow   [OpacityComponent fades]
///         ├─ interiorRoot ─┬─ occluder wall with a hole      (OcclusionMaterial, depth only)
///         │                ├─ leafL / leafR                  (animated depth-only aperture leaves)
///         │                ├─ veil, seam                     (transparent effects in the aperture)
///         │                └─ worldRoot                      (the alley; never moved)
///         ├─ spill           optional floor light spill
///         ├─ sceneOcclusion  LiDAR occluders (portal space)
///         └─ ambientEmitter / humEmitter (audio)
@MainActor
final class PortalRig {
    let root = Entity()
    let frameRoot = Entity()
    let interiorRoot = Entity()
    let worldRoot = Entity()
    private let insideBackdrop = Entity()
    private var apertureMask: ModelEntity!
    private var wasInside = false
    private var spillRequested = false
    let ambientEmitter = Entity()
    let humEmitter = Entity()

    private(set) var frameLight: ModelEntity?
    private(set) var leafL: ModelEntity!
    private(set) var leafR: ModelEntity!
    private(set) var veil: ModelEntity!
    private(set) var seam: ModelEntity!
    private(set) var spill: ModelEntity?
    private(set) var rainLayers: [String: ModelEntity] = [:]
    private(set) var steam: ModelEntity?
    private let dims: PortalDimensions
    private unowned let assets: PortalAssets

    private var lastLook = PortalLook(frameOpacity: -1, edgeIntensity: -1, edgeSweep: -1, seamIntensity: -1, apertureOpen: -1, veil: -1)
    private(set) var triangleCount = 0

    init(assets: PortalAssets) throws {
        self.assets = assets
        self.dims = assets.dims
        root.name = "PortalRoot"
        root.addChild(frameRoot)
        root.addChild(interiorRoot)
        interiorRoot.addChild(worldRoot)
        root.addChild(ambientEmitter)
        root.addChild(humEmitter)
        ambientEmitter.position = SIMD3(0, 1.3, -1.2)     // just behind the opening
        humEmitter.position = SIMD3(0, 1.1, 0)
        try buildFrame()
        try buildInterior()
        try buildWorld()
        try buildInsideEnvironment()
    }

    // MARK: build

    private func buildFrame() throws {
        let parts = assets.parts("frame")
        let lightParts = parts.filter { $0.material == "frame_light" || $0.material == "frame_led" }
        let solid = parts.filter { !lightParts.map(\.material).contains($0.material) }
        let body = try assets.modelEntity(solid, name: "frameBody")
        frameRoot.addChild(body)
        // light channel: its own material instance so intensity/sweep can animate
        let channel = lightParts.filter { $0.material == "frame_light" }
        if !channel.isEmpty {
            let light = try assets.modelEntity(channel, name: "frameLight", materialOverride: try assets.uniqueMaterial("frame_light"))
            frameRoot.addChild(light)
            frameLight = light
        }
        let led = lightParts.filter { $0.material == "frame_led" }
        if !led.isEmpty { frameRoot.addChild(try assets.modelEntity(led, name: "frameLED")) }
        let shadow = try assets.modelEntity(assets.parts("portal_aux", chunk: "shadow"), name: "contactShadow")
        frameRoot.addChild(shadow)
        let spillEntity = try assets.modelEntity(assets.parts("portal_aux", chunk: "spill"), name: "spill")
        spillEntity.isEnabled = false
        root.addChild(spillEntity)
        spill = spillEntity
        triangleCount += parts.reduce(0) { $0 + $1.triangleCount }
    }

    private func buildInterior() throws {
        let occ = try assets.modelEntity(assets.parts("portal_aux", chunk: "occluder"), name: "occluderWall")
        apertureMask = occ
        interiorRoot.addChild(occ)
        let leafParts = assets.parts("portal_aux", chunk: "leaf")
        leafL = try assets.modelEntity(leafParts, name: "leafL")
        leafR = try assets.modelEntity(leafParts, name: "leafR")
        interiorRoot.addChild(leafL)
        interiorRoot.addChild(leafR)
        veil = try assets.modelEntity(assets.parts("portal_aux", chunk: "veil"), name: "veil",
                                      materialOverride: try assets.uniqueMaterial("veil", params: SIMD4(0, 0, 0, 1)))
        seam = try assets.modelEntity(assets.parts("portal_aux", chunk: "seam"), name: "seam",
                                      materialOverride: try assets.uniqueMaterial("seam", params: SIMD4(0, 0.01, 0, 0)))
        interiorRoot.addChild(veil)
        interiorRoot.addChild(seam)
        setLeaves(open: 0)
    }

    private func buildWorld() throws {
        let alley = assets.parts("alley")
        // Opaque geometry: one entity per chunk (near / mid / far / distant / sky)
        // for frustum culling.  Transparent layers: one entity each, so the
        // renderer can sort them and the quality tier can drop some.
        let transparent = Set(assets.manifest.materials.filter { $0.value.isTransparent }.map(\.key))
        let byChunk = Dictionary(grouping: alley.filter { !transparent.contains($0.material) }, by: \.chunk)
        for (chunk, parts) in byChunk.sorted(by: { $0.key < $1.key }) {
            worldRoot.addChild(try assets.modelEntity(parts, name: "alley.\(chunk)"))
        }
        for p in alley where transparent.contains(p.material) {
            let e = try assets.modelEntity([p], name: "alley.\(p.material)")
            worldRoot.addChild(e)
            if p.material.hasPrefix("rain_") { rainLayers[p.material] = e }
            if p.material == "steam" { steam = e }
        }
        triangleCount += alley.reduce(0) { $0 + $1.triangleCount }
    }

    // MARK: runtime

    func applyTier(_ tier: QualityTier) {
        for (name, e) in rainLayers { e.isEnabled = tier.keptRainLayers.contains(name) }
        steam?.isEnabled = tier.steam
        assets.applyLightBudget(tier, under: root)
    }

    func setSpill(_ on: Bool) {
        spillRequested = on
        spill?.isEnabled = on && !wasInside
    }

    /// Inside-only closure: the original alley was authored for a front view.
    /// A surrounding sky and textured return wall prevent the live room leaking
    /// around the destination when the camera turns sideways, upwards or back.
    /// A depth-only rectangle in the return opening reveals the live camera
    /// image there, in front of the enclosing sky but behind the frame.
    private func buildInsideEnvironment() throws {
        worldRoot.addChild(insideBackdrop)
        insideBackdrop.name = "InsideEnvironment"
        insideBackdrop.isEnabled = false
        var sky = try assets.uniqueMaterial("sky")
        var mirrorDome = false
        if var custom = sky as? CustomMaterial {
            custom.faceCulling = .front
            sky = custom
        } else if var fallback = sky as? UnlitMaterial {
            if #available(iOS 18.0, *) {
                fallback.faceCulling = .front
            } else {
                // Reverse winding for an inward sky on the older unlit API.
                mirrorDome = true
            }
            sky = fallback
        }
        let dome = ModelEntity(mesh: .generateSphere(radius: 120), materials: [sky])
        if mirrorDome { dome.scale.x = -1 }
        dome.name = "InsideSky"
        insideBackdrop.addChild(dome)

        // Vertices are baked in portal space, preserving the custom shader's
        // identity-transform convention. Winding faces the destination (-z).
        func rectangle(_ name: String, x0: Float, x1: Float, y0: Float, y1: Float,
                       z: Float, material: RealityKit.Material) throws {
            var d = MeshDescriptor(name: name)
            d.positions = MeshBuffers.Positions([SIMD3(x0, y0, z), SIMD3(x1, y0, z),
                                                SIMD3(x1, y1, z), SIMD3(x0, y1, z)])
            d.normals = MeshBuffers.Normals(Array(repeating: SIMD3<Float>(0, 0, -1), count: 4))
            d.textureCoordinates = MeshBuffers.TextureCoordinates([
                SIMD2(x0, y0), SIMD2(x1, y0), SIMD2(x1, y1), SIMD2(x0, y1)])
            d.primitives = .triangles([0, 2, 1, 0, 3, 2])
            let e = ModelEntity(mesh: try MeshResource.generate(from: [d]), materials: [material])
            e.name = name
            insideBackdrop.addChild(e)
        }
        let wall = try assets.material("concrete_dark")
        let hw = dims.openHalfWidth
        let wallZ = dims.frameFrontZ + 0.025
        try rectangle("ReturnWallLeft", x0: -120, x1: -hw, y0: -120, y1: 120, z: wallZ, material: wall)
        try rectangle("ReturnWallRight", x0: hw, x1: 120, y0: -120, y1: 120, z: wallZ, material: wall)
        try rectangle("ReturnWallTop", x0: -hw, x1: hw, y0: dims.openY1, y1: 120, z: wallZ, material: wall)
        try rectangle("ReturnWallBottom", x0: -hw, x1: hw, y0: -120, y1: dims.openY0, z: wallZ, material: wall)
        try rectangle("ReturnToRoom", x0: -hw, x1: hw, y0: dims.openY0, y1: dims.openY1,
                      z: wallZ + 0.005, material: OcclusionMaterial())
        triangleCount += 10
    }

    /// Leaves are unit quads (x 0..1, y 0..1) scaled to cover the hole from the
    /// sides toward the centre.  open = 1 disables them entirely.
    private func setLeaves(open: Float) {
        let hw = dims.holeHalfWidth
        let covered = hw * (1 - min(max(open, 0), 1))
        let h = dims.holeY1 - dims.holeY0
        let visible = covered > 0.0005
        leafL.isEnabled = visible
        leafR.isEnabled = visible
        guard visible else { return }
        leafL.transform = Transform(scale: SIMD3(covered, h, 1), rotation: simd_quatf(), translation: SIMD3(-hw, dims.holeY0, dims.apertureLeafZ))
        leafR.transform = Transform(scale: SIMD3(covered, h, 1), rotation: simd_quatf(), translation: SIMD3(hw - covered, dims.holeY0, dims.apertureLeafZ))
    }

    private func setParams(_ e: ModelEntity?, _ v: SIMD4<Float>) {
        guard let e, var model = e.model, var m = model.materials.first as? CustomMaterial else { return }
        m.custom.value = v
        model.materials = [m]
        e.model = model
    }

    /// Applies one display state.  Only changed values are pushed to RealityKit.
    func apply(_ look: PortalLook, worldVisible: Bool, interiorVisible: Bool, insideWorld: Bool = false) {
        let sideChanged = wasInside != insideWorld
        wasInside = insideWorld
        interiorRoot.isEnabled = interiorVisible
        worldRoot.isEnabled = worldVisible
        insideBackdrop.isEnabled = insideWorld
        apertureMask.isEnabled = !insideWorld
        spill?.isEnabled = spillRequested && !insideWorld
        frameRoot.findEntity(named: "contactShadow")?.isEnabled = !insideWorld
        let l = look
        if sideChanged || abs(l.apertureOpen - lastLook.apertureOpen) > 0.0005 { setLeaves(open: l.apertureOpen) }
        if sideChanged || abs(l.veil - lastLook.veil) > 0.002 {
            setParams(veil, SIMD4(l.veil, 0, 0, 1))
            veil.isEnabled = l.veil > 0.002
        }
        if sideChanged || abs(l.seamIntensity - lastLook.seamIntensity) > 0.002 || abs(l.apertureOpen - lastLook.apertureOpen) > 0.0005 {
            setParams(seam, SIMD4(l.seamIntensity, dims.holeHalfWidth * l.apertureOpen, 0, 0))
            seam.isEnabled = l.seamIntensity > 0.002
        }
        if abs(l.edgeIntensity - lastLook.edgeIntensity) > 0.002 || abs(l.edgeSweep - lastLook.edgeSweep) > 0.002 {
            setParams(frameLight, SIMD4(0.6 * l.edgeIntensity, l.edgeSweep, 0, 0))
        }
        if abs(l.frameOpacity - lastLook.frameOpacity) > 0.002 {
            // OpacityComponent is iOS 18+. On iOS 17 the doorway shows/hides
            // without the fade (isEnabled below); everything else is identical.
            if #available(iOS 18.0, *) {
                if l.frameOpacity >= 0.999 {
                    frameRoot.components.remove(OpacityComponent.self)     // opaque fast path
                } else {
                    frameRoot.components.set(OpacityComponent(opacity: max(0, l.frameOpacity)))
                }
            }
            frameRoot.isEnabled = l.frameOpacity > 0.001
        }
        if insideWorld {
            leafL.isEnabled = false
            leafR.isEnabled = false
            veil.isEnabled = false
            seam.isEnabled = false
        }
        lastLook = l
    }
}

/// A thin floor outline for placement, rather than a life-size translucent
/// doorway that can fill the camera view when the phone is aimed down.
/// Uses built-in unlit materials so scanning never depends on custom shaders.
@MainActor
final class PreviewRig {
    let anchor = AnchorEntity(world: matrix_identity_float4x4)
    let root = Entity()
    private var markers: [ModelEntity] = []
    private let validMat = UnlitMaterial(color: UIColor(red: 0.2, green: 0.9, blue: 0.95, alpha: 1))
    private let invalidMat = UnlitMaterial(color: UIColor(red: 1, green: 0.65, blue: 0.2, alpha: 1))
    private var lastValid: Bool?

    init(assets: PortalAssets) throws {
        let halfWidth = assets.dims.outerHalfWidth
        let halfDepth: Float = 0.30
        // Eight short corner strokes show the full footprint without covering
        // the real floor. One small centre stroke marks the threshold.
        func stroke(size: SIMD3<Float>, at position: SIMD3<Float>) {
            let e = ModelEntity(mesh: .generateBox(size: size), materials: [validMat])
            e.position = position
            markers.append(e)
            root.addChild(e)
        }
        for x in [Float(-1), Float(1)] {
            for z in [Float(-1), Float(1)] {
                stroke(size: SIMD3(0.18, 0.006, 0.012),
                       at: SIMD3(x * (halfWidth - 0.09), 0.015, z * halfDepth))
                stroke(size: SIMD3(0.012, 0.006, 0.18),
                       at: SIMD3(x * halfWidth, 0.015, z * (halfDepth - 0.09)))
            }
        }
        stroke(size: SIMD3(0.16, 0.006, 0.012), at: SIMD3(0, 0.015, 0))
        anchor.addChild(root)
        root.isEnabled = false
    }

    func show(_ transform: simd_float4x4, valid: Bool) {
        root.isEnabled = true
        root.setTransformMatrix(transform, relativeTo: nil)
        if lastValid != valid {
            for marker in markers {
                marker.model?.materials = [valid ? validMat : invalidMat]
            }
            lastValid = valid
        }
    }

    func hide() { root.isEnabled = false }
}


