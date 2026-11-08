import Foundation
import simd

// MARK: - Surfaces

/// Where a portal is mounted.  `floating` is the freestanding fallback when
/// no usable surface is under the aim point.
public enum SurfaceKind: String, CaseIterable, Equatable, Sendable {
    case wall, floor, ceiling, floating
}

/// A raycast hit classified for portal mounting.
public struct SurfaceClassification: Equatable, Sendable {
    public var kind: SurfaceKind
    /// Unit normal of the snapped mounting plane, pointing toward the camera.
    public var normal: SIMD3<Float>
    /// Angle (degrees) between the real surface and the plane it was snapped
    /// to; > 0 for sloped surfaces (ramps, roof windows, angled walls).
    public var snappedDegrees: Float
    public var wasAngled: Bool { snappedDegrees > SurfaceClassifier.alignedToleranceDegrees }
}

/// Decides wall / floor / ceiling from the surface normal and where the
/// surface is relative to the camera.  Angled surfaces snap to the nearest
/// category (a portal is always gravity-coherent: its destination keeps
/// world "up"), up to a limit beyond which the surface is ambiguous.
public enum SurfaceClassifier {
    /// Within this many degrees a surface counts as exactly aligned.
    public static let alignedToleranceDegrees: Float = 12
    /// Beyond this deviation from the nearest category the hit is rejected...
    public static let maxSnapDegrees: Float = 40
    /// ...unless ARKit classified the plane as that category.
    public static let agreedSnapDegrees: Float = 45
    /// Floors must be at least this far below the camera, ceilings this far above.
    public static let minVerticalClearance: Float = 0.25

    public static func classify(point: SIMD3<Float>, normal: SIMD3<Float>, camera: SIMD3<Float>,
                                arkit: PlaneKind? = nil) -> SurfaceClassification? {
        let l = simd_length(normal)
        guard l > 1e-4 else { return nil }
        var n = normal / l
        // ARKit may report either side of an estimated plane: face the camera.
        if simd_dot(n, camera - point) < 0 { n = -n }
        let up = max(-1, min(1, n.y))
        let elevation = asin(up) * 180 / .pi            // +90 faces up, -90 faces down
        let below = camera.y - point.y
        var kind: SurfaceKind
        var deviation: Float
        if abs(elevation) < 45 {
            kind = .wall
            deviation = abs(elevation)
        } else if elevation > 0 {
            kind = .floor
            deviation = 90 - elevation
        } else {
            kind = .ceiling
            deviation = 90 + elevation
        }
        // When ARKit's own plane classification agrees, trust slightly
        // steeper surfaces (e.g. a classified wall leaning 43 degrees).
        let agrees: Bool = {
            switch (arkit, kind) {
            case (.wall?, .wall), (.door?, .wall), (.window?, .wall), (.floor?, .floor), (.ceiling?, .ceiling): return true
            default: return false
            }
        }()
        guard deviation <= (agrees ? agreedSnapDegrees : maxSnapDegrees) else { return nil }
        switch kind {
        case .floor:
            guard below >= minVerticalClearance else { return nil }      // a shelf above eye height is not a floor
            return SurfaceClassification(kind: .floor, normal: SIMD3(0, 1, 0), snappedDegrees: deviation)
        case .ceiling:
            guard -below >= minVerticalClearance else { return nil }
            return SurfaceClassification(kind: .ceiling, normal: SIMD3(0, -1, 0), snappedDegrees: deviation)
        default:
            let h = SIMD3<Float>(n.x, 0, n.z)
            guard simd_length(h) > 1e-3 else { return nil }
            return SurfaceClassification(kind: .wall, normal: simd_normalize(h), snappedDegrees: deviation)
        }
    }
}

// MARK: - Destination modes

/// How the alley is attached behind the aperture.  The alley is authored for
/// a doorway (alley +y up, -z deep).  For floor and ceiling portals it is
/// rotated so its +y stays world-up (gravity-coherent) and placed so the
/// aperture opens above the street (floor) or just above head height in the
/// alley (ceiling).  Geometry on the room side of the aperture plane is
/// clipped in the shaders (see `clipCode`).
public enum DestinationMode: String, CaseIterable, Equatable, Sendable {
    case wall, floor, ceiling

    public init(_ kind: SurfaceKind) {
        switch kind {
        case .floor: self = .floor
        case .ceiling: self = .ceiling
        case .wall, .floating: self = .wall
        }
    }

    /// Alley-space point that appears at the centre of the aperture.
    public var aperture: SIMD3<Float> {
        switch self {
        case .wall: return SIMD3(0, (PortalDimensions().openY0 + PortalDimensions().openY1) / 2, PortalDimensions().occluderZ)
        case .floor: return SIMD3(0.1, 7.0, -8.0)      // 7.1 m above the street, between the cafe and the bookshop
        case .ceiling: return SIMD3(0.1, 2.5, -5.2)    // just above head height, under the arch sign
        }
    }

    /// Rotation taking alley axes to rig (portal) axes.  Rig axes per surface:
    /// wall  x right, y up, z out of the wall;  floor  x right, y forward
    /// (away from the user), z up;  ceiling  x right, y toward the user, z down.
    public var rotation: simd_float3x3 {
        switch self {
        case .wall: return matrix_identity_float3x3
        case .floor:   // alley up -> rig +z (world up), alley +z (toward viewer) -> rig -y
            return simd_float3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, -1, 0)))
        case .ceiling: // alley up -> rig -z (world up), alley +z -> rig +y (toward the user)
            return simd_float3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, 1, 0)))
        }
    }

    /// worldRoot transform (alley space -> rig space).
    public func worldTransform(dims: PortalDimensions = PortalDimensions()) -> simd_float4x4 {
        guard self != .wall else { return matrix_identity_float4x4 }
        let r = rotation
        let centre = SIMD3<Float>(0, (dims.openY0 + dims.openY1) / 2, dims.occluderZ)
        let t = centre - r * aperture
        return simd_float4x4(columns: (SIMD4(r.columns.0, 0), SIMD4(r.columns.1, 0), SIMD4(r.columns.2, 0), SIMD4(t, 1)))
    }

    /// Alley-space height of the aperture plane (floor / ceiling modes).
    public var apertureHeight: Float { aperture.y }

    /// Clip code for the shaders (material roughness scale, 0...1):
    ///   0            no clip (wall portal; the alley is authored behind the plane)
    ///   (0, 0.5]     floor:   discard alley y > h,  h = code * 20
    ///   (0.5, 1]     ceiling: discard alley y < h,  h = (code - 0.5) * 20
    public var clipCode: Float {
        switch self {
        case .wall: return 0
        case .floor: return apertureHeight / 20
        case .ceiling: return 0.5 + apertureHeight / 20
        }
    }

    /// Mirror of `a_clip_keep` in AlleyShadingCore.h (for tests and diagnostics).
    public static func keeps(alleyY y: Float, code: Float) -> Bool {
        if code < 0.0005 { return true }
        if code <= 0.5 { return y < code * 20 - ClipMargin.metres }
        return y > (code - 0.5) * 20 + ClipMargin.metres
    }

    /// Where fog distance is measured from (a typical viewer), alley space.
    public var fogReference: SIMD3<Float> {
        switch self {
        case .wall: return SIMD3(0, 1.3, 1.6)
        case .floor: return aperture + SIMD3(0, 1.3, 0.9)
        case .ceiling: return aperture + SIMD3(0, -1.5, 0.6)
        }
    }

    /// Whether walking through the aperture into the alley is supported.
    public var allowsCrossing: Bool { self == .wall }
}

public enum ClipMargin {
    /// Matches the build invariant: destination geometry stays >= 4 mm behind the occluder.
    public static let metres: Float = 0.004
}

// MARK: - Poses

public enum PortalPose {
    /// Rig pose (portal space -> world) for a mounting surface.
    ///  * wall: gravity-aligned, back of the aperture flush with the wall
    ///    (delegates to `PortalMath.wallPlacement`).
    ///  * floor / ceiling: aperture plane on the surface, opening centred on
    ///    the aim point, "top" of the opening pointing away from (floor) or
    ///    toward (ceiling) the user, so it appears upright on screen whichever
    ///    way the phone is tilted to look at it.
    public static func make(_ kind: SurfaceKind, point: SIMD3<Float>, normal: SIMD3<Float>, camera: SIMD3<Float>,
                            cameraForward: SIMD3<Float>, floorY: Float?, dims: PortalDimensions = PortalDimensions()) -> simd_float4x4? {
        switch kind {
        case .wall:
            return PortalMath.wallPlacement(hit: point, normal: normal, camera: camera, floorY: floorY, dims: dims)
        case .floating:
            return nil
        case .floor, .ceiling:
            var f = SIMD3<Float>(point.x - camera.x, 0, point.z - camera.z)
            if simd_length(f) < 0.05 { f = SIMD3(cameraForward.x, 0, cameraForward.z) }
            guard simd_length(f) > 1e-4 else { return nil }
            f = simd_normalize(f)
            let z: SIMD3<Float> = kind == .floor ? SIMD3(0, 1, 0) : SIMD3(0, -1, 0)
            let y: SIMD3<Float> = kind == .floor ? f : -f
            let x = simd_cross(y, z)
            let centreLocal = (dims.openY0 + dims.openY1) / 2
            // occluder plane on the surface; opening centred on the aim point
            let origin = point - z * dims.occluderZ - y * centreLocal
            return simd_float4x4(columns: (SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(origin, 1)))
        }
    }

    /// The surface a rig pose is mounted on.
    public static func kind(of pose: simd_float4x4) -> SurfaceKind {
        let zy = pose.columns.2.y
        if zy > 0.7 { return .floor }
        if zy < -0.7 { return .ceiling }
        return .wall
    }
}

// MARK: - Aperture adjustments (Resize / Rotate)

/// Scale and in-plane rotation of the aperture (opening, occluder, trim).
/// The destination is NOT scaled or rotated: real and virtual metres stay
/// equal and the alley stays upright; a bigger opening simply shows more.
public struct ApertureAdjustment: Equatable, Sendable {
    public static let scaleRange: ClosedRange<Float> = 0.5...1.6
    public static let scaleStep: Float = 0.1
    public static let rotationStepDegrees: Float = 15

    public private(set) var scale: Float = 1
    public private(set) var rotationDegrees: Float = 0

    public init(scale: Float = 1, rotationDegrees: Float = 0) {
        self.scale = min(max(scale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        self.rotationDegrees = Self.wrap(rotationDegrees)
    }

    public mutating func grow() { self = ApertureAdjustment(scale: ((scale + Self.scaleStep) * 100).rounded() / 100, rotationDegrees: rotationDegrees) }
    public mutating func shrink() { self = ApertureAdjustment(scale: ((scale - Self.scaleStep) * 100).rounded() / 100, rotationDegrees: rotationDegrees) }
    public mutating func rotate(clockwise: Bool) {
        self = ApertureAdjustment(scale: scale, rotationDegrees: rotationDegrees + (clockwise ? -1 : 1) * Self.rotationStepDegrees)
    }
    public var canGrow: Bool { scale < Self.scaleRange.upperBound - 1e-4 }
    public var canShrink: Bool { scale > Self.scaleRange.lowerBound + 1e-4 }
    public var isIdentity: Bool { abs(scale - 1) < 1e-4 && abs(rotationDegrees) < 1e-3 }

    private static func wrap(_ d: Float) -> Float {
        var x = fmodf(d + 180, 360)
        if x < 0 { x += 360 }
        return x - 180
    }

    /// Pivot of the adjustment in portal space: the bottom centre of the
    /// opening for a doorway standing on a floor (it stays on the floor), the
    /// centre of the opening otherwise.
    public static func pivot(standingOnFloor: Bool, dims: PortalDimensions = PortalDimensions()) -> SIMD3<Float> {
        SIMD3(0, standingOnFloor ? 0 : (dims.openY0 + dims.openY1) / 2, 0)
    }

    /// Aperture transform in portal space: about `pivot`, rotate about the
    /// portal normal (z), scale x/y only (the occluder plane stays at its z).
    public func matrix(pivot: SIMD3<Float>) -> simd_float4x4 {
        let a = rotationDegrees * .pi / 180
        let c = cos(a), s = sin(a)
        var m = simd_float4x4(columns: (SIMD4(c * scale, s * scale, 0, 0), SIMD4(-s * scale, c * scale, 0, 0),
                                        SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
        let p = m * SIMD4(pivot, 1)
        m.columns.3 = SIMD4(pivot.x - p.x, pivot.y - p.y, 0, 1)
        return m
    }

    /// Portal-space point -> unadjusted aperture space (for boundary checks
    /// written against the nominal opening).
    public func toAperture(_ p: SIMD3<Float>, pivot: SIMD3<Float>) -> SIMD3<Float> {
        let q = matrix(pivot: pivot).inverse * SIMD4(p, 1)
        return SIMD3(q.x, q.y, q.z)
    }
}

// MARK: - Universal resolver

public struct UniversalPlacementInput: Equatable, Sendable {
    public var camera: SIMD3<Float>
    public var cameraForward: SIMD3<Float>
    /// Surface under the aim point (detected plane first, else estimated).
    public var aim: SurfaceHit?
    /// ARKit classification of that surface, when it comes from a plane anchor.
    public var aimKind: PlaneKind?
    /// Whether `aim` comes from a detected (vs estimated) plane.
    public var aimDetected: Bool
    public var confirmedFloorY: Float?
    public var lowestPlaneY: Float?
    public var trackingNormal: Bool

    public init(camera: SIMD3<Float>, cameraForward: SIMD3<Float>, aim: SurfaceHit? = nil, aimKind: PlaneKind? = nil,
                aimDetected: Bool = false, confirmedFloorY: Float? = nil, lowestPlaneY: Float? = nil, trackingNormal: Bool = true) {
        self.camera = camera
        self.cameraForward = cameraForward
        self.aim = aim
        self.aimKind = aimKind
        self.aimDetected = aimDetected
        self.confirmedFloorY = confirmedFloorY
        self.lowestPlaneY = lowestPlaneY
        self.trackingNormal = trackingNormal
    }
}

/// Wall, floor, ceiling, angled (snapped) and floating placement.  Walls use
/// the v1.2.2 Easy Mode rules unchanged; floors and ceilings add their own
/// distance and visibility rules; anything else falls back to the standing
/// doorway so CREATE PORTAL always has something to place.
public struct UniversalPlacement: Sendable {
    public var easy: EasyPlacement
    public var dims: PortalDimensions
    /// Floor portal: horizontal distance from the camera to the opening centre.
    public var floorDistance: ClosedRange<Float> = 0.6...4.5
    /// Ceiling portal: height of the ceiling above the camera.
    public var ceilingClearance: ClosedRange<Float> = 0.25...4.0
    /// The opening centre must be within this angle of the camera's view direction.
    public var maxViewAngle: Float = 50 * .pi / 180

    public init(dims: PortalDimensions = PortalDimensions()) {
        self.dims = dims
        self.easy = EasyPlacement(dims: dims)
    }

    public func resolve(_ i: UniversalPlacementInput) -> (proposal: PlacementProposal, surface: SurfaceClassification?) {
        let easyInput = EasyPlacementInput(camera: i.camera, cameraForward: i.cameraForward, confirmedFloorY: i.confirmedFloorY,
                                           lowestPlaneY: i.lowestPlaneY, trackingNormal: i.trackingNormal)
        guard let hit = i.aim,
              let cls = SurfaceClassifier.classify(point: hit.point, normal: hit.normal, camera: i.camera, arkit: i.aimKind) else {
            return (easy.resolve(easyInput), nil)
        }
        let angledNote: String? = cls.wasAngled ? "Sloped surface - the portal is levelled to the nearest \(cls.kind.rawValue)" : nil
        switch cls.kind {
        case .wall:
            var e = easyInput
            let snapped = SurfaceHit(point: hit.point, normal: cls.normal, extent: hit.extent)
            if i.aimDetected { e.detectedWall = snapped } else { e.estimatedWall = snapped }
            var p = easy.resolve(e)
            if p.method != .standing, let angledNote { p.hint = angledNote }
            return (p, p.method == .standing ? nil : cls)
        case .floor, .ceiling:
            if let p = horizontalProposal(cls, hit: hit, i, note: angledNote) { return (p, cls) }
            var fallback = easy.resolve(easyInput)
            if fallback.ready { fallback.hint = cls.kind == .floor ? "Aim at open floor 1-4 m away for a floor portal" : "Aim straight up at the ceiling for a ceiling portal" }
            return (fallback, nil)
        case .floating:
            return (easy.resolve(easyInput), nil)
        }
    }

    private func horizontalProposal(_ cls: SurfaceClassification, hit: SurfaceHit, _ i: UniversalPlacementInput, note: String?) -> PlacementProposal? {
        let method: PlacementMethod = cls.kind == .floor ? .floor : .ceiling
        guard let pose = PortalPose.make(cls.kind, point: hit.point, normal: cls.normal, camera: i.camera,
                                         cameraForward: i.cameraForward, floorY: nil, dims: dims) else { return nil }
        let centre = PortalMath.fromPortalSpace(SIMD3(0, (dims.openY0 + dims.openY1) / 2, dims.occluderZ), portal: pose)
        let horizontal = simd_length(SIMD2(centre.x - i.camera.x, centre.z - i.camera.z))
        var status = cls.kind == .floor ? "Ready to open a portal in the floor" : "Ready to open a portal in the ceiling"
        var ready = i.trackingNormal
        if cls.kind == .floor {
            if horizontal < floorDistance.lowerBound { ready = false; status = "Aim a little farther ahead - not at your feet" }
            if horizontal > floorDistance.upperBound { ready = false; status = "Aim closer - within about 4 metres" }
        } else {
            let up = centre.y - i.camera.y
            if !ceilingClearance.contains(up) { ready = false; status = "Ceiling out of reach - aim at a nearer ceiling" }
        }
        let dir = centre - i.camera
        let f = simd_length(i.cameraForward) > 1e-4 ? simd_normalize(i.cameraForward) : SIMD3(0, 0, -1)
        if simd_length(dir) > 1e-4, acos(max(-1, min(1, simd_dot(simd_normalize(dir), f)))) > maxViewAngle {
            ready = false
            status = "Keep the spot in the middle of the screen"
        }
        if !i.trackingNormal { status = "Hold steady for a moment" }
        return PlacementProposal(method: method, transform: pose, ready: ready, status: status, hint: note)
    }
}

/// Floor-portal safety: the opening is virtual, the floor is solid, but a
/// user looking at the phone may still walk onto or trip at its edge.
public enum FloorPortalSafety {
    /// Margin around the opening that counts as "on the portal".
    public static let margin: Float = 0.35

    /// True when the camera (the user) is horizontally over or at the edge of
    /// a floor portal's opening.
    public static func isOver(camera: SIMD3<Float>, portal: simd_float4x4, adjustment: ApertureAdjustment = ApertureAdjustment(),
                              dims: PortalDimensions = PortalDimensions()) -> Bool {
        guard PortalPose.kind(of: portal) == .floor else { return false }
        let local = PortalMath.toPortalSpace(camera, portal: portal)
        let a = adjustment.toAperture(SIMD3(local.x, local.y, 0), pivot: ApertureAdjustment.pivot(standingOnFloor: false, dims: dims))
        let m = margin / adjustment.scale
        return abs(a.x) < dims.openHalfWidth + m && a.y > dims.openY0 - m && a.y < dims.openY1 + m
    }
}

// MARK: - Preview smoothing

public enum PoseSmoothing {
    /// Display-only smoothing of the placement preview: position lerp and
    /// rotation slerp (the result stays rigid).  Never used for anchored poses.
    public static func blend(_ a: simd_float4x4, _ b: simd_float4x4, _ t: Float) -> simd_float4x4 {
        func rot(_ m: simd_float4x4) -> simd_quatf {
            simd_quatf(simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                     SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                     SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)))
        }
        let k = min(max(t, 0), 1)
        var qa = rot(a)
        let qb = rot(b)
        if simd_dot(qa.vector, qb.vector) < 0 { qa = simd_quatf(vector: -qa.vector) }   // shortest arc
        var m = simd_float4x4(simd_slerp(qa, qb, k))
        let pa = PortalMath.translation(a), pb = PortalMath.translation(b)
        let p = pa + (pb - pa) * k
        m.columns.3 = SIMD4(p, 1)
        return m
    }
}

// MARK: - Destinations (v1.4)

/// What is behind the portal.
public enum DestinationKind: String, Codable, CaseIterable, Sendable {
    /// Authored, illustrated alley (v1.0-1.3), kept as a fallback.
    case illustrated
    /// Genuinely captured photogrammetry scene: true 3D, responds to movement.
    case capture
    /// Genuine flat footage on a screen behind the opening (Cinematic Mode).
    case video
}

/// Per-destination placement data for floor / ceiling portals: where in the
/// destination (its own metres, +y up, alley toward -z) the opening appears.
public struct DestinationScene: Equatable, Sendable {
    public var id: String
    public var kind: DestinationKind
    public var floorAperture: SIMD3<Float>
    public var ceilingAperture: SIMD3<Float>

    public init(id: String, kind: DestinationKind, floorAperture: SIMD3<Float>, ceilingAperture: SIMD3<Float>) {
        self.id = id
        self.kind = kind
        self.floorAperture = floorAperture
        self.ceilingAperture = ceilingAperture
    }

    public static let illustrated = DestinationScene(id: "illustrated", kind: .illustrated,
                                                     floorAperture: SIMD3(0.1, 7.0, -8.0), ceilingAperture: SIMD3(0.1, 2.5, -5.2))

    /// Which surfaces this destination can be shown on.  Flat footage only
    /// makes sense in a wall-like window (a floor or ceiling hole would demand
    /// views the footage never contained).
    public func supports(_ mode: DestinationMode) -> Bool {
        kind != .video || mode == .wall
    }

    public func aperture(_ mode: DestinationMode) -> SIMD3<Float> {
        switch mode {
        case .wall: return mode.aperture
        case .floor: return floorAperture
        case .ceiling: return ceilingAperture
        }
    }
}

extension DestinationMode {
    /// worldRoot transform for a given destination (alley space -> rig space).
    public func worldTransform(dims: PortalDimensions = PortalDimensions(), scene: DestinationScene) -> simd_float4x4 {
        guard self != .wall else { return matrix_identity_float4x4 }
        let r = rotation
        let centre = SIMD3<Float>(0, (dims.openY0 + dims.openY1) / 2, dims.occluderZ)
        let t = centre - r * scene.aperture(self)
        return simd_float4x4(columns: (SIMD4(r.columns.0, 0), SIMD4(r.columns.1, 0), SIMD4(r.columns.2, 0), SIMD4(t, 1)))
    }

    public func clipCode(scene: DestinationScene) -> Float {
        switch self {
        case .wall: return 0
        case .floor: return scene.aperture(self).y / 20
        case .ceiling: return 0.5 + scene.aperture(self).y / 20
        }
    }
}

// MARK: - Cinematic Mode screen

/// Flat footage is shown on a screen at a fixed depth behind the opening:
/// exactly the perspective of a picture standing in the alley.  The screen is
/// sized so that, from every viewpoint in the supported viewing zone, the
/// opening shows only footage; outside the zone a dark matte surround shows
/// instead of the room.  Nothing pretends the footage is 3D.
public struct CinematicScreen: Equatable, Sendable {
    /// Screen centre and size in portal space (the plane z = centre.z).
    public var centre: SIMD3<Float>
    public var width: Float
    public var height: Float

    /// Viewing zone the screen must cover: at least `minDistance` in front of
    /// the opening and within `maxAngleDegrees` of its axis, at heights `heights`.
    public struct Zone: Equatable, Sendable {
        public var minDistance: Float = 1.2
        public var maxDistance: Float = 4.0
        public var maxAngleDegrees: Float = 35
        public var heights: ClosedRange<Float> = 0.9...2.0
        public init() {}
    }

    /// Smallest screen at `depth` (metres behind the opening) of aspect
    /// `aspect` (width / height) that covers the opening from every zone viewpoint.
    public static func fit(depth: Float, aspect: Float, zone: Zone = Zone(), dims: PortalDimensions = PortalDimensions()) -> CinematicScreen {
        let zPlane = dims.occluderZ - depth
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        let a = zone.maxAngleDegrees * .pi / 180
        let corners: [SIMD3<Float>] = [SIMD3(-dims.openHalfWidth, dims.openY0, dims.occluderZ), SIMD3(dims.openHalfWidth, dims.openY0, dims.occluderZ),
                                       SIMD3(-dims.openHalfWidth, dims.openY1, dims.occluderZ), SIMD3(dims.openHalfWidth, dims.openY1, dims.occluderZ)]
        for d in [zone.minDistance, zone.maxDistance] {
            for ang in [-a, 0, a] {
                for h in [zone.heights.lowerBound, zone.heights.upperBound] {
                    let v = SIMD3<Float>(sin(ang) * d, h, cos(ang) * d)
                    for c in corners {
                        let k = (zPlane - v.z) / (c.z - v.z)
                        let p = v + (c - v) * k
                        lo = simd_min(lo, SIMD2(p.x, p.y)); hi = simd_max(hi, SIMD2(p.x, p.y))
                    }
                }
            }
        }
        var w = hi.x - lo.x, h = hi.y - lo.y
        if w / h < aspect { w = h * aspect } else { h = w / aspect }
        let c = SIMD3<Float>((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, zPlane)
        return CinematicScreen(centre: c, width: w, height: h)
    }

    /// Whether the opening, seen from `camera` (portal space), shows only the screen.
    public func covers(from camera: SIMD3<Float>, dims: PortalDimensions = PortalDimensions()) -> Bool {
        guard camera.z > dims.occluderZ + 0.01 else { return false }
        for x in [-dims.openHalfWidth, dims.openHalfWidth] {
            for y in [dims.openY0, dims.openY1] {
                let c = SIMD3<Float>(x, y, dims.occluderZ)
                let k = (centre.z - camera.z) / (c.z - camera.z)
                let p = camera + (c - camera) * k
                if abs(p.x - centre.x) > width / 2 + 1e-4 || abs(p.y - centre.y) > height / 2 + 1e-4 { return false }
            }
        }
        return true
    }

    /// Fraction of the footage width visible through the opening from `camera`
    /// (how much it is magnified; 1 = the whole frame).
    public func visibleFraction(from camera: SIMD3<Float>, dims: PortalDimensions = PortalDimensions()) -> Float {
        let k = (centre.z - camera.z) / (dims.occluderZ - camera.z)
        return min(1, 2 * dims.openHalfWidth * k / width)
    }
}
