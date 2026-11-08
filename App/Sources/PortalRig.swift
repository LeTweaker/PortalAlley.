import Foundation
import PortalCore
import RealityKit
import UIKit

/// Boundary look.  `subtle` (v1.3 default): an opening cut exactly into the
/// surface with a thin trim and a recessed reveal.  `classic`: the v1.0-1.2
/// doorway frame with its light channel (also used for floating doorways,
/// which have no surface to cut into).
enum PortalStyle: String, CaseIterable, Identifiable {
    case subtle, classic
    var id: String { rawValue }
}

/// The doorway and its destination as one entity tree in PORTAL SPACE.
///
///   root ─┬─ apertureRoot          Resize / Rotate (scale x,y + roll about z; z never scaled)
///         │    ├─ frameRoot         classic doorway (PBR), light channel   [OpacityComponent fades]
///         │    ├─ trimRoot          subtle trim + reveal (PBR, lit by the room)
///         │    └─ interiorRoot ─┬─ occluders (classic hole / exact hole; depth only)
///         │                     ├─ leafL / leafR   animated depth-only aperture leaves
///         │                     └─ veil(s), seam   transparent effects in the aperture
///         ├─ destinationRoot ── worldRoot   the alley: per-mode rotation (DestinationMode),
///         │                                  never scaled; identity for wall portals
///         ├─ spill, sceneOcclusion (portal space)
///         └─ ambientEmitter / humEmitter (audio)
///
/// Alley shaders work in alley space via model_to_world, so every alley mesh
/// is a direct child of worldRoot with an identity transform.
@MainActor
final class PortalRig {
    let root = Entity()
    let apertureRoot = Entity()
    let frameRoot = Entity()
    let trimRoot = Entity()
    let interiorRoot = Entity()
    let destinationRoot = Entity()
    let worldRoot = Entity()
    private let insideBackdrop = Entity()
    private var insideFrames: [PortalStyle: Entity] = [:]
    private var occluders: [PortalStyle: ModelEntity] = [:]
    private var veils: [PortalStyle: ModelEntity] = [:]
    private var backCap: Entity?
    private var fullSky: ModelEntity?
    private(set) var style: PortalStyle = .subtle
    private(set) var mode: DestinationMode = .wall
    private var destinationOffset = SIMD3<Float>(repeating: 0)
    private var wasInside = false
    private var spillRequested = false
    let ambientEmitter = Entity()
    let humEmitter = Entity()

    private(set) var frameLight: ModelEntity?
    private(set) var leafL: ModelEntity!
    private(set) var leafR: ModelEntity!
    private var veil: ModelEntity { veils[style]! }
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
        root.addChild(apertureRoot)
        apertureRoot.addChild(frameRoot)
        apertureRoot.addChild(trimRoot)
        apertureRoot.addChild(interiorRoot)
        root.addChild(destinationRoot)
        destinationRoot.addChild(worldRoot)
        root.addChild(ambientEmitter)
        root.addChild(humEmitter)
        ambientEmitter.position = SIMD3(0, 1.3, -1.2)     // just behind the opening
        humEmitter.position = SIMD3(0, 1.1, 0)
        try buildFrame()
        try buildTrim()
        try buildInterior()
        try buildWorld()
        try buildModeExtras()
        try buildInsideEnvironment()
        setStyle(.subtle)
    }

    // MARK: build

    private func buildFrame() throws {
        // Remove low floor-support triangles from the original freestanding
        // frame. The recessed surround and sill remain for the wall opening.
        let parts = assets.parts("frame").map { part -> MeshPart in
            var p = part
            p.indices = stride(from: 0, to: part.indices.count, by: 3).flatMap { k -> [UInt32] in
                let ids = Array(part.indices[k..<(k + 3)])
                let v = ids.map { part.positions[Int($0)] }
                let foot = v.allSatisfy { $0.y < 0.08 } && v.contains { abs($0.x) > self.dims.outerHalfWidth || $0.z > 0.125 }
                return foot ? [] : ids
            }
            return p
        }.filter { !$0.indices.isEmpty }
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

    /// v1.3 subtle boundary: thin trim ring + recessed reveal.
    private func buildTrim() throws {
        let trim = try assets.modelEntity(assets.parts("portal_aux", chunk: "trim"), name: "trim")
        let reveal = try assets.modelEntity(assets.parts("portal_aux", chunk: "reveal"), name: "reveal")
        trimRoot.addChild(trim)
        trimRoot.addChild(reveal)
        triangleCount += (assets.parts("portal_aux", chunk: "trim") + assets.parts("portal_aux", chunk: "reveal")).reduce(0) { $0 + $1.triangleCount }
    }

    private func buildInterior() throws {
        // classic: hole slightly larger than the opening, its edge hidden by
        // the frame; subtle: the hole IS the opening
        let classic = try assets.modelEntity(assets.parts("portal_aux", chunk: "occluder"), name: "occluderWall")
        let exact = try assets.modelEntity(assets.parts("portal_aux", chunk: "occluder_exact"), name: "occluderExact")
        occluders = [.classic: classic, .subtle: exact]
        interiorRoot.addChild(classic)
        interiorRoot.addChild(exact)
        let leafParts = assets.parts("portal_aux", chunk: "leaf")
        leafL = try assets.modelEntity(leafParts, name: "leafL")
        leafR = try assets.modelEntity(leafParts, name: "leafR")
        interiorRoot.addChild(leafL)
        interiorRoot.addChild(leafR)
        veils = [
            .classic: try assets.modelEntity(assets.parts("portal_aux", chunk: "veil"), name: "veil",
                                             materialOverride: try assets.uniqueMaterial("veil", params: SIMD4(0, 0, 0, 1))),
            .subtle: try assets.modelEntity(assets.parts("portal_aux", chunk: "veil_exact"), name: "veilExact",
                                            materialOverride: try assets.uniqueMaterial("veil", params: SIMD4(0, 0, 0, 1))),
        ]
        veils.values.forEach { interiorRoot.addChild($0) }
        seam = try assets.modelEntity(assets.parts("portal_aux", chunk: "seam"), name: "seam",
                                      materialOverride: try assets.uniqueMaterial("seam", params: SIMD4(0, 0.01, 0, 0)))
        interiorRoot.addChild(seam)
    }

    private func buildWorld() throws {
        let alley = assets.parts("alley")
        // Opaque geometry: one entity per chunk (near / mid / far / distant / sky)
        // for frustum culling.  Transparent layers: one entity each, so the
        // renderer can sort them and the quality tier can drop some.
        let transparent = Set(assets.manifest.materials.filter { $0.value.isTransparent }.map(\.key))
        let byChunk = Dictionary(grouping: alley.filter { !transparent.contains($0.material) }, by: \.chunk)
        for (chunk, parts) in byChunk.sorted(by: { $0.key < $1.key }) {
            let e = try assets.modelEntity(parts, name: "alley.\(chunk)")
            worldRoot.addChild(e)
            // closes the alley's open end; only seen from floor/ceiling portals
            if chunk == "backcap" { backCap = e; e.isEnabled = false }
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
        spill?.isEnabled = false // a wall opening has no artificial floor spill
    }

    /// Floor / ceiling portals look in every direction: a closed sky sphere
    /// replaces the doorway-facing dome (disabled for wall portals).
    private func buildModeExtras() throws {
        var sky = try assets.uniqueMaterial("sky")
        if var custom = sky as? CustomMaterial { custom.faceCulling = .front; sky = custom }
        let dome = ModelEntity(mesh: .generateSphere(radius: 110), materials: [sky])
        dome.name = "FullSky"
        if !(sky is CustomMaterial) { dome.scale.x = -1 }       // unlit fallback: invert winding instead
        dome.isEnabled = false
        worldRoot.addChild(dome)
        fullSky = dome
    }

    func setDestinationOffset(_ offset: SIMD3<Float>) {
        destinationOffset = offset
        applyWorldTransform()
    }

    private func applyWorldTransform() {
        var t = Transform(matrix: mode.worldTransform(dims: dims))
        t.translation += destinationOffset
        worldRoot.transform = t
    }

    /// Wall, floor or ceiling destination: rotation keeps the alley upright,
    /// shaders clip geometry on the room side of a horizontal aperture.
    func setMode(_ m: DestinationMode) {
        mode = m
        destinationOffset = .zero
        applyWorldTransform()
        assets.applyDestinationClip(m.clipCode, under: worldRoot)
        backCap?.isEnabled = m != .wall
        fullSky?.isEnabled = m != .wall
        // the doorway-facing dome and the inside-view closure belong to walls
        worldRoot.findEntity(named: "alley.sky")?.isEnabled = m == .wall
    }

    func setStyle(_ s: PortalStyle) {
        style = s
        frameRoot.isEnabled = s == .classic
        trimRoot.isEnabled = s == .subtle
        for (k, o) in occluders { o.isEnabled = k == s }
        for (k, v) in veils { v.isEnabled = k == s && v.isEnabled }
        for (k, f) in insideFrames { f.isEnabled = k == s && f.isEnabled }
        // seam: opening-wide warm hairline for subtle, cyan for classic
        seam.scale = SIMD3(s == .subtle ? 2 * dims.openHalfWidth : 1, 1, 1)
        if var m = seam.model?.materials.first as? CustomMaterial {
            let tint: UIColor = s == .subtle ? UIColor(red: 1.0, green: 0.95, blue: 0.88, alpha: 1) : PortalAssets.srgbColor([0.45, 0.92, 1.0])
            m.baseColor = CustomMaterial.BaseColor(tint: tint, texture: m.baseColor.texture)
            seam.model?.materials = [m]
        }
        lastLook = PortalLook(frameOpacity: -1, edgeIntensity: -1, edgeSweep: -1, seamIntensity: -1, apertureOpen: -1, veil: -1)
        setLeaves(open: 0)
    }

    /// Resize / Rotate: only the aperture changes; the alley keeps real scale.
    func setAdjustment(_ a: ApertureAdjustment, standingOnFloor: Bool) {
        apertureRoot.transform = Transform(matrix: a.matrix(pivot: ApertureAdjustment.pivot(standingOnFloor: standingOnFloor, dims: dims)))
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
        let returnFrame = frameRoot.clone(recursive: true)
        returnFrame.findEntity(named: "contactShadow")?.isEnabled = false
        insideBackdrop.addChild(returnFrame)
        let returnTrim = trimRoot.clone(recursive: true)
        insideBackdrop.addChild(returnTrim)
        insideFrames = [.classic: returnFrame, .subtle: returnTrim]
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
        let hw = style == .subtle ? dims.openHalfWidth : dims.holeHalfWidth
        let y0 = style == .subtle ? dims.openY0 : dims.holeY0
        let covered = hw * (1 - min(max(open, 0), 1))
        let h = (style == .subtle ? dims.openY1 : dims.holeY1) - y0
        let visible = covered > 0.0005
        leafL.isEnabled = visible
        leafR.isEnabled = visible
        guard visible else { return }
        leafL.transform = Transform(scale: SIMD3(covered, h, 1), rotation: simd_quatf(), translation: SIMD3(-hw, y0, dims.apertureLeafZ))
        leafR.transform = Transform(scale: SIMD3(covered, h, 1), rotation: simd_quatf(), translation: SIMD3(hw - covered, y0, dims.apertureLeafZ))
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
        destinationRoot.isEnabled = interiorVisible
        worldRoot.isEnabled = worldVisible
        insideBackdrop.isEnabled = insideWorld
        for (k, o) in occluders { o.isEnabled = k == style && !insideWorld }
        spill?.isEnabled = false
        frameRoot.findEntity(named: "contactShadow")?.isEnabled = false
        for (k, f) in insideFrames { f.isEnabled = k == style && insideWorld }
        let l = look
        if sideChanged || abs(l.apertureOpen - lastLook.apertureOpen) > 0.0005 { setLeaves(open: l.apertureOpen) }
        if sideChanged || abs(l.veil - lastLook.veil) > 0.002 {
            setParams(veil, SIMD4(l.veil, 0, 0, 1))
            veil.isEnabled = l.veil > 0.002
        }
        if sideChanged || abs(l.seamIntensity - lastLook.seamIntensity) > 0.002 || abs(l.apertureOpen - lastLook.apertureOpen) > 0.0005 {
            // seam uv spans the (scaled) quad: line offset in uv units
            let half = style == .subtle ? 0.5 : dims.holeHalfWidth
            setParams(seam, SIMD4(l.seamIntensity * (style == .subtle ? 0.5 : 1), half * l.apertureOpen, 0, 0))
            seam.isEnabled = l.seamIntensity > 0.002
        }
        if abs(l.edgeIntensity - lastLook.edgeIntensity) > 0.002 || abs(l.edgeSweep - lastLook.edgeSweep) > 0.002 {
            setParams(frameLight, SIMD4(0.6 * l.edgeIntensity, l.edgeSweep, 0, 0))
        }
        let boundary = style == .classic ? frameRoot : trimRoot
        if abs(l.frameOpacity - lastLook.frameOpacity) > 0.002 {
            // OpacityComponent is iOS 18+. On iOS 17 the boundary shows/hides
            // without the fade (isEnabled below); everything else is identical.
            if #available(iOS 18.0, *) {
                if l.frameOpacity >= 0.999 {
                    boundary.components.remove(OpacityComponent.self)     // opaque fast path
                } else {
                    boundary.components.set(OpacityComponent(opacity: max(0, l.frameOpacity)))
                }
            }
        }
        if insideWorld {
            leafL.isEnabled = false
            leafR.isEnabled = false
            veil.isEnabled = false
            seam.isEnabled = false
        }
        boundary.isEnabled = l.frameOpacity > 0.001 && !insideWorld
        (style == .classic ? trimRoot : frameRoot).isEnabled = false
        lastLook = l
    }
}

/// Placement preview: a glowing outline of the doorway where it will appear.
@MainActor
final class PreviewRig {
    let anchor = AnchorEntity(world: matrix_identity_float4x4)
    let root = Entity()
    private var strokes: [ModelEntity] = []
    private var outerStrokes: [ModelEntity] = []
    private var fill: ModelEntity?
    /// Aiming indicator: a small crosshair lying on the aimed surface.
    private let reticle = Entity()
    // Unlit, slightly over-bright colours read as a glow on the camera image.
    private let validMat = UnlitMaterial(color: UIColor(red: 0.35, green: 0.95, blue: 1.0, alpha: 1))
    private let invalidMat = UnlitMaterial(color: UIColor(red: 1.0, green: 0.68, blue: 0.22, alpha: 1))
    private var validFill = UnlitMaterial(color: UIColor(red: 0.3, green: 0.9, blue: 1.0, alpha: 1))
    private var invalidFill = UnlitMaterial(color: UIColor(red: 1.0, green: 0.65, blue: 0.2, alpha: 1))
    private var lastValid: Bool?

    /// v1.2.2: the whole doorway is outlined (opening + outer frame, 2.5 cm
    /// strokes) with a translucent fill, so the preview is obvious at 1-4 m.
    /// v1.2.1 drew eight 9 mm corner ticks, which were easy to miss.
    init(assets: PortalAssets) throws {
        let dims = assets.dims
        validFill.blending = .transparent(opacity: .init(floatLiteral: 0.22))
        invalidFill.blending = .transparent(opacity: .init(floatLiteral: 0.16))
        let z = dims.frameFrontZ + 0.012
        func bar(_ size: SIMD3<Float>, _ position: SIMD3<Float>, outer: Bool) {
            let e = ModelEntity(mesh: .generateBox(size: size, cornerRadius: min(size.x, size.y) * 0.4), materials: [validMat])
            e.position = position
            strokes.append(e)
            if outer { outerStrokes.append(e) }
            root.addChild(e)
        }
        func rectangle(halfWidth hw: Float, y0: Float, y1: Float, thickness t: Float, outer: Bool) {
            let h = y1 - y0
            bar(SIMD3(2 * hw + t, t, t), SIMD3(0, y0, z), outer: outer)
            bar(SIMD3(2 * hw + t, t, t), SIMD3(0, y1, z), outer: outer)
            bar(SIMD3(t, h, t), SIMD3(-hw, y0 + h / 2, z), outer: outer)
            bar(SIMD3(t, h, t), SIMD3(hw, y0 + h / 2, z), outer: outer)
        }
        rectangle(halfWidth: dims.openHalfWidth, y0: dims.openY0, y1: dims.openY1, thickness: 0.025, outer: false)
        rectangle(halfWidth: dims.outerHalfWidth, y0: 0.0, y1: dims.outerTop, thickness: 0.012, outer: true)
        for size in [SIMD3<Float>(0.14, 0.008, 0.002), SIMD3<Float>(0.008, 0.14, 0.002)] {
            let e = ModelEntity(mesh: .generateBox(size: size, cornerRadius: 0.001), materials: [validMat])
            reticle.addChild(e)
            strokes.append(e)
        }
        anchor.addChild(reticle)
        reticle.isEnabled = false
        let f = ModelEntity(mesh: .generatePlane(width: 2 * dims.openHalfWidth, height: dims.openY1 - dims.openY0),
                            materials: [validFill])
        f.position = SIMD3(0, (dims.openY0 + dims.openY1) / 2, z - 0.004)
        root.addChild(f)
        fill = f
        anchor.addChild(root)
        root.isEnabled = false
    }

    /// transform: portal pose (smoothed).  outerFrame: classic outline.
    /// aim: surface point + normal under the screen centre (aiming indicator).
    func show(_ transform: simd_float4x4, valid: Bool, outerFrame: Bool = true, aim: (point: SIMD3<Float>, normal: SIMD3<Float>)? = nil) {
        root.isEnabled = true
        root.setTransformMatrix(transform, relativeTo: nil)
        for s in outerStrokes { s.isEnabled = outerFrame }
        if let aim, simd_length(aim.normal) > 0.5 {
            let n = simd_normalize(aim.normal)
            reticle.isEnabled = true
            reticle.setTransformMatrix(Transform(rotation: simd_quatf(from: SIMD3<Float>(0, 0, 1), to: n),
                                                 translation: aim.point + n * 0.006).matrix, relativeTo: nil)
        } else {
            reticle.isEnabled = false
        }
        if lastValid != valid {
            for s in strokes { s.model?.materials = [valid ? validMat : invalidMat] }
            fill?.model?.materials = [valid ? validFill : invalidFill]
            lastValid = valid
        }
    }
    func hide() { root.isEnabled = false; reticle.isEnabled = false }
}



