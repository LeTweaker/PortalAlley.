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

    func setSpill(_ on: Bool) { spill?.isEnabled = on }

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
    func apply(_ look: PortalLook, worldVisible: Bool, interiorVisible: Bool) {
        interiorRoot.isEnabled = interiorVisible
        worldRoot.isEnabled = worldVisible
        let l = look
        if abs(l.apertureOpen - lastLook.apertureOpen) > 0.0005 { setLeaves(open: l.apertureOpen) }
        if abs(l.veil - lastLook.veil) > 0.002 {
            setParams(veil, SIMD4(l.veil, 0, 0, 1))
            veil.isEnabled = l.veil > 0.002
        }
        if abs(l.seamIntensity - lastLook.seamIntensity) > 0.002 || abs(l.apertureOpen - lastLook.apertureOpen) > 0.0005 {
            setParams(seam, SIMD4(l.seamIntensity, dims.holeHalfWidth * l.apertureOpen, 0, 0))
            seam.isEnabled = l.seamIntensity > 0.002
        }
        if abs(l.edgeIntensity - lastLook.edgeIntensity) > 0.002 || abs(l.edgeSweep - lastLook.edgeSweep) > 0.002 {
            setParams(frameLight, SIMD4(0.6 * l.edgeIntensity, l.edgeSweep, 0, 0))
        }
        if abs(l.frameOpacity - lastLook.frameOpacity) > 0.002 {
            if l.frameOpacity >= 0.999 {
                frameRoot.components.remove(OpacityComponent.self)     // opaque fast path
            } else {
                frameRoot.components.set(OpacityComponent(opacity: max(0, l.frameOpacity)))
            }
            frameRoot.isEnabled = l.frameOpacity > 0.001
        }
        lastLook = l
    }
}

/// Placement preview: translucent ghost of the real doorway + floor footprint.
@MainActor
final class PreviewRig {
    let anchor = AnchorEntity(world: matrix_identity_float4x4)
    let root = Entity()
    private let ghost: ModelEntity
    private let footprint: ModelEntity
    private let validMat: RealityKit.Material
    private let invalidMat: RealityKit.Material
    private var lastValid: Bool?

    init(assets: PortalAssets) throws {
        validMat = try assets.uniqueMaterial("footprint", params: SIMD4(0.75, 0, 0, 0))
        var bad = try assets.uniqueMaterial("footprint", params: SIMD4(0.75, 0, 0, 0))
        if var c = bad as? CustomMaterial {
            c.baseColor = CustomMaterial.BaseColor(tint: PortalAssets.srgbColor([1.0, 0.62, 0.18]), texture: c.baseColor.texture)
            bad = c
        }
        invalidMat = bad
        let frameParts = assets.parts("frame").filter { $0.material != "frame_bolt" }
        ghost = try assets.modelEntity(frameParts, name: "ghost", materialOverride: validMat)
        footprint = try assets.modelEntity(assets.parts("portal_aux", chunk: "footprint"), name: "footprint", materialOverride: validMat)
        root.addChild(ghost)
        root.addChild(footprint)
        anchor.addChild(root)
        root.isEnabled = false
    }

    func show(_ transform: simd_float4x4, valid: Bool) {
        root.isEnabled = true
        root.setTransformMatrix(transform, relativeTo: nil)
        if lastValid != valid {
            ghost.model?.materials = [valid ? validMat : invalidMat]
            footprint.model?.materials = [valid ? validMat : invalidMat]
            lastValid = valid
        }
    }

    func hide() { root.isEnabled = false }
}
