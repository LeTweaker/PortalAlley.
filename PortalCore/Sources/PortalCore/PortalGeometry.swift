import Foundation
import simd

/// Doorway dimensions in portal space (metres).  Portal space: origin on the
/// floor at the centre of the opening, +y up, +z toward the room (the viewing
/// side), the destination extends toward -z.  Values are written by the asset
/// build into manifest.json; the defaults mirror Tools/assetgen/frame.py.
public struct PortalDimensions: Codable, Equatable, Sendable {
    public var openHalfWidth: Float = 0.48
    public var openY0: Float = 0.03
    public var openY1: Float = 2.05
    public var outerHalfWidth: Float = 0.65
    public var outerTop: Float = 2.22
    public var frameBackZ: Float = -0.12
    public var frameFrontZ: Float = 0.12
    public var apertureLeafZ: Float = -0.1225
    public var occluderZ: Float = -0.125
    public var holeHalfWidth: Float = 0.515
    public var holeY0: Float = -0.05
    public var holeY1: Float = 2.085
    public var veilZ: Float = -0.1235
    public var seamZ: Float = -0.121

    public init() {}

    /// Invariants the renderer relies on (checked by tests against the shipped manifest).
    public var isConsistent: Bool {
        frameBackZ > apertureLeafZ && apertureLeafZ > veilZ && veilZ > occluderZ &&
        seamZ > apertureLeafZ && seamZ < frameBackZ &&
        holeHalfWidth > openHalfWidth && holeHalfWidth < outerHalfWidth &&
        holeY0 < openY0 && holeY1 > openY1 && holeY1 < outerTop
    }
}

public enum PortalMath {
    /// Yaw about +y that turns portal +z toward `camera` (horizontal only), so
    /// the viewing side of the doorway faces the user when it is placed.
    public static func facingYaw(floorPoint: SIMD3<Float>, camera: SIMD3<Float>) -> Float {
        let d = SIMD2<Float>(camera.x - floorPoint.x, camera.z - floorPoint.z)
        guard simd_length(d) > 1e-4 else { return 0 }
        return atan2(d.x, d.y)
    }

    /// Rigid, gravity-aligned transform: rotation `yaw` about +y, then translation.
    public static func transform(position: SIMD3<Float>, yaw: Float) -> simd_float4x4 {
        let c = cos(yaw), s = sin(yaw)
        return simd_float4x4(columns: (
            SIMD4<Float>(c, 0, -s, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(s, 0, c, 0),
            SIMD4<Float>(position.x, position.y, position.z, 1)
        ))
    }

    /// Yaw of a gravity-aligned transform (inverse of `transform`).
    public static func yaw(of m: simd_float4x4) -> Float {
        atan2(m.columns.2.x, m.columns.2.z)
    }

    /// World point -> portal space.  Uses the rigid inverse (R^T, -R^T t), which
    /// stays exact even if the anchor carries tiny numerical non-orthogonality.
    public static func toPortalSpace(_ world: SIMD3<Float>, portal: simd_float4x4) -> SIMD3<Float> {
        let r = simd_float3x3(SIMD3(portal.columns.0.x, portal.columns.0.y, portal.columns.0.z),
                              SIMD3(portal.columns.1.x, portal.columns.1.y, portal.columns.1.z),
                              SIMD3(portal.columns.2.x, portal.columns.2.y, portal.columns.2.z))
        let t = SIMD3(portal.columns.3.x, portal.columns.3.y, portal.columns.3.z)
        return r.transpose * (world - t)
    }

    public static func fromPortalSpace(_ local: SIMD3<Float>, portal: simd_float4x4) -> SIMD3<Float> {
        let p = portal * SIMD4<Float>(local.x, local.y, local.z, 1)
        return SIMD3(p.x, p.y, p.z)
    }

    public static func translation(_ m: simd_float4x4) -> SIMD3<Float> {
        SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    /// Intersection of a ray with the horizontal plane y = planeY (in front of the origin).
    public static func intersectHorizontalPlane(origin: SIMD3<Float>, direction: SIMD3<Float>, planeY: Float) -> SIMD3<Float>? {
        guard abs(direction.y) > 1e-5 else { return nil }
        let t = (planeY - origin.y) / direction.y
        guard t > 0 else { return nil }
        return origin + direction * t
    }

    public static func wrapAngle(_ a: Float) -> Float {
        var x = fmodf(a + .pi, 2 * .pi)
        if x < 0 { x += 2 * .pi }
        return x - .pi
    }

    public static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Frame-rate independent exponential approach (used for display values only,
    /// never for tracked poses).
    public static func approach(_ current: Float, _ target: Float, rate: Float, dt: Float) -> Float {
        let k = 1 - exp(-rate * max(dt, 0))
        let v = current + (target - current) * k
        return abs(v - target) < 0.0005 ? target : v
    }
}
