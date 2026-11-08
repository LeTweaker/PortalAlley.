import Foundation
import simd

/// How the doorway will be placed.  Easy Mode tries them in this order.
public enum PlacementMethod: String, Equatable, Sendable {
    /// ARKit has detected a vertical plane under the aim point: mount on it.
    case wall
    /// No detected plane yet, but ARKit's estimated-plane raycast (feature
    /// points / LiDAR depth) finds a vertical surface: mount on that.
    case estimatedWall
    /// No usable wall: a freestanding doorway on the floor, ahead of the
    /// camera and facing it (manual fallback; nothing is behind it).
    case standing
    /// v1.3: an opening in the floor (look down into the alley).
    case floor
    /// v1.3: an opening in the ceiling (look up into the alley).
    case ceiling
}

/// One raycast result against a (detected or estimated) vertical surface.
public struct SurfaceHit: Equatable, Sendable {
    public var point: SIMD3<Float>
    public var normal: SIMD3<Float>
    /// Plane extent (width, height) when it comes from a detected plane anchor.
    public var extent: SIMD2<Float>?

    public init(point: SIMD3<Float>, normal: SIMD3<Float>, extent: SIMD2<Float>? = nil) {
        self.point = point
        self.normal = normal
        self.extent = extent
    }
}

public struct EasyPlacementInput: Equatable, Sendable {
    public var camera: SIMD3<Float>
    /// Direction the camera looks (world space, need not be normalised).
    public var cameraForward: SIMD3<Float>
    public var detectedWall: SurfaceHit?
    public var estimatedWall: SurfaceHit?
    /// Height of an ARKit-classified floor, if any.
    public var confirmedFloorY: Float?
    /// Lowest horizontal plane of any classification, if any.
    public var lowestPlaneY: Float?
    public var trackingNormal: Bool

    public init(camera: SIMD3<Float>, cameraForward: SIMD3<Float>, detectedWall: SurfaceHit? = nil,
                estimatedWall: SurfaceHit? = nil, confirmedFloorY: Float? = nil, lowestPlaneY: Float? = nil,
                trackingNormal: Bool = true) {
        self.camera = camera
        self.cameraForward = cameraForward
        self.detectedWall = detectedWall
        self.estimatedWall = estimatedWall
        self.confirmedFloorY = confirmedFloorY
        self.lowestPlaneY = lowestPlaneY
        self.trackingNormal = trackingNormal
    }
}

/// What the preview shows and what CREATE PORTAL would do right now.
public struct PlacementProposal: Equatable, Sendable {
    public var method: PlacementMethod
    /// Gravity-aligned doorway pose (portal space -> world).
    public var transform: simd_float4x4
    /// CREATE PORTAL is allowed.
    public var ready: Bool
    /// Short status for the user ("Ready to place", "Step back from the wall"...).
    public var status: String
    /// Optional second line, e.g. how to get a wall-mounted doorway instead.
    public var hint: String?

    public var position: SIMD3<Float> { PortalMath.translation(transform) }
    public var yaw: Float { PortalMath.yaw(of: transform) }
}

/// Reasons a doorway pose would not be clearly visible to the user.
public enum SpawnIssue: Equatable, Sendable {
    case behindCamera          // doorway centre is not in front of the camera
    case outsideView           // too far off to the side to be in view
    case cameraOnWrongSide     // camera is behind / inside the doorway
    case tooCloseToCamera      // camera within the frame's depth: doorway overfills the view
    case tooFar
}

/// Checks that a doorway pose will appear in front of the user, facing them,
/// at a sensible distance.  Applied to every proposal before it is "ready".
public enum PlacementSafety {
    public static let minViewingDistance: Float = 0.35   // camera to the frame's front face
    public static let maxDistance: Float = 6.0
    /// Maximum horizontal angle between the camera's heading and the doorway.
    public static let maxHeadingAngle: Float = 40 * .pi / 180

    public static func check(portal: simd_float4x4, camera: SIMD3<Float>, cameraForward: SIMD3<Float>,
                             dims: PortalDimensions = PortalDimensions()) -> SpawnIssue? {
        let local = PortalMath.toPortalSpace(camera, portal: portal)
        if local.z <= dims.frameFrontZ { return .cameraOnWrongSide }
        if local.z < dims.frameFrontZ + minViewingDistance { return .tooCloseToCamera }
        let centre = PortalMath.fromPortalSpace(SIMD3(0, (dims.openY0 + dims.openY1) / 2, 0), portal: portal)
        let toDoor = SIMD2<Float>(centre.x - camera.x, centre.z - camera.z)
        let dist = simd_length(toDoor)
        if dist > maxDistance { return .tooFar }
        let f = SIMD2<Float>(cameraForward.x, cameraForward.z)
        guard simd_length(f) > 1e-4, dist > 1e-4 else { return .behindCamera }
        let cosA = simd_dot(simd_normalize(f), toDoor / dist)
        if cosA <= 0 { return .behindCamera }
        if cosA < cos(maxHeadingAngle) { return .outsideView }
        return nil
    }
}

/// Easy Mode placement: always produces a proposal, prefers real walls, and
/// never leaves the user without a way to create a portal while tracking works.
public struct EasyPlacement: Sendable {
    public var dims = PortalDimensions()
    public var wallMinDistance: Float = 0.7       // camera to wall (horizontal)
    public var wallMaxDistance: Float = 4.5
    public var standingDistance: Float = 2.2      // freestanding fallback ahead of the camera
    /// Typical height of a hand-held phone above the floor, used only when
    /// ARKit has not found any floor yet.
    public var assumedCameraHeight: Float = 1.4
    /// A wall plane needs this much detected extent to be trusted for mounting.
    public var minWallExtent = SIMD2<Float>(0.35, 0.25)

    public init(dims: PortalDimensions = PortalDimensions()) { self.dims = dims }

    /// Best floor height available: a classified floor, else the lowest plane,
    /// else an estimate from the camera height (all sanity-checked).
    public func floorY(_ i: EasyPlacementInput) -> Float {
        if let f = i.confirmedFloorY, (0.15...2.6).contains(i.camera.y - f) { return f }
        if let f = i.lowestPlaneY, (0.5...2.6).contains(i.camera.y - f) { return f }
        return i.camera.y - assumedCameraHeight
    }

    private func horizontalDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        simd_length(SIMD2(a.x - b.x, a.z - b.z))
    }

    private func isVertical(_ n: SIMD3<Float>) -> Bool {
        let l = simd_length(n)
        return l > 1e-4 && abs(n.y / l) < 0.35
    }

    public func resolve(_ i: EasyPlacementInput) -> PlacementProposal {
        let floor = floorY(i)
        var wallTooClose = false
        var wallTooFar = false

        func wallProposal(_ hit: SurfaceHit?, method: PlacementMethod) -> PlacementProposal? {
            guard let hit, isVertical(hit.normal) else { return nil }
            if method == .wall, let e = hit.extent,
               max(e.x, e.y) < minWallExtent.x || min(e.x, e.y) < minWallExtent.y { return nil }
            let d = horizontalDistance(hit.point, i.camera)
            if d < wallMinDistance { wallTooClose = true; return nil }
            if d > wallMaxDistance { wallTooFar = true; return nil }
            // Use the floor if the aim point is at a plausible height above it;
            // wallPlacement otherwise centres the opening on the aim point.
            let usableFloor: Float? = (0.3...2.5).contains(hit.point.y - floor) ? floor : nil
            guard let pose = PortalMath.wallPlacement(hit: hit.point, normal: hit.normal, camera: i.camera,
                                                      floorY: usableFloor, dims: dims) else { return nil }
            guard PlacementSafety.check(portal: pose, camera: i.camera, cameraForward: i.cameraForward, dims: dims) == nil else { return nil }
            let status = method == .wall ? "Ready to place on the wall" : "Ready to place on this wall"
            return PlacementProposal(method: method, transform: pose, ready: i.trackingNormal,
                                     status: i.trackingNormal ? status : "Hold steady for a moment", hint: nil)
        }

        if let p = wallProposal(i.detectedWall, method: .wall) { return p }
        if let p = wallProposal(i.estimatedWall, method: .estimatedWall) { return p }

        // Freestanding fallback straight ahead, facing the camera.
        var f = SIMD3<Float>(i.cameraForward.x, 0, i.cameraForward.z)
        let flat = simd_length(f) > 0.15
        f = flat ? simd_normalize(f) : SIMD3(0, 0, -1)
        let pos = SIMD3<Float>(i.camera.x + f.x * standingDistance, floor, i.camera.z + f.z * standingDistance)
        let pose = PortalMath.transform(position: pos, yaw: PortalMath.facingYaw(floorPoint: pos, camera: i.camera))
        var ready = i.trackingNormal && flat && !wallTooClose
        var status = "Ready - no wall found, places a standing doorway"
        var hint: String? = wallTooFar ? "Move closer to a wall to mount it there" : "Point at a wall to mount it there instead"
        if !i.trackingNormal {
            status = "Hold steady for a moment"
        } else if wallTooClose {
            status = "Step back about a metre from the wall"
            hint = nil
        } else if !flat {
            status = "Raise the phone to look ahead"
            hint = nil
        }
        if ready, PlacementSafety.check(portal: pose, camera: i.camera, cameraForward: i.cameraForward, dims: dims) != nil {
            ready = false
            status = "Raise the phone to look ahead"
        }
        return PlacementProposal(method: .standing, transform: pose, ready: ready, status: status, hint: hint)
    }
}

/// Directions back to a placed portal that has left the screen.
public struct FindPortalHint: Equatable, Sendable {
    /// Horizontal turn needed, degrees; positive = turn right.
    public var turnDegrees: Float
    public var distance: Float
    public var message: String
}

public enum FindPortal {
    public static func hint(camera: SIMD3<Float>, cameraForward: SIMD3<Float>, target: SIMD3<Float>) -> FindPortalHint {
        let to = SIMD2<Float>(target.x - camera.x, target.z - camera.z)
        let dist = simd_length(to)
        var f = SIMD2<Float>(cameraForward.x, cameraForward.z)
        if simd_length(f) < 1e-4 { f = SIMD2(0, -1) }
        f = simd_normalize(f)
        guard dist > 1e-3 else { return FindPortalHint(turnDegrees: 0, distance: 0, message: "The portal is right here") }
        let t = to / dist
        // Signed angle from forward to target in the x/z plane, positive = clockwise
        // seen from above = to the user's right (x right, -z forward).
        let cross = f.x * t.y - f.y * t.x
        let angle = atan2(cross, simd_dot(f, t)) * 180 / .pi
        let metres = dist < 1 ? "nearby" : String(format: "%.0f m away", dist)
        let message: String
        if abs(angle) > 150 {
            message = "The portal is behind you - turn around (\(metres))"
        } else if abs(angle) < 20 {
            let up = target.y - camera.y
            message = up > 0.8 ? "The portal is ahead - tilt up" : (up < -1.2 ? "The portal is ahead - tilt down" : "The portal is ahead (\(metres))")
        } else {
            message = "Turn \(angle > 0 ? "right" : "left") about \(Int((abs(angle) / 10).rounded() * 10))° (\(metres))"
        }
        return FindPortalHint(turnDegrees: angle, distance: dist, message: message)
    }
}
