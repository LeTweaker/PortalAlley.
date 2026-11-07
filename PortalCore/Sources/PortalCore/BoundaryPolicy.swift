import Foundation
import simd

public struct BoundaryDecision: Equatable, Sendable {
    /// Whether the destination may render at all.  False behind the aperture
    /// plane: the depth-only occluder only works from the room side.
    public var worldVisible: Bool
    /// 0 = veil fully opaque (too close to the aperture), 1 = clear.
    public var clarity: Float
    public var behind: Bool
    public var message: String?
}

/// Deliberate behaviour near and behind the doorway (look-through portal; no
/// walk-through in this release).
///
/// * In front, inside the doorway's footprint: the view clears fully at
///   `clearDistance` from the aperture plane and is veiled completely at
///   `veilDistance`, so the camera near plane never reaches the occluder and the
///   user is told to step back instead of walking into it.
/// * Behind the aperture plane (with hysteresis) the destination is disabled;
///   the doorway then reads as a finished object from the back.
public struct BoundaryPolicy: Sendable {
    public var veilDistance: Float = 0.30
    public var clearDistance: Float = 0.55
    public var behindEnter: Float = 0.02
    public var behindExit: Float = 0.08
    public private(set) var behind = false

    public init() {}

    public mutating func evaluate(cameraLocal c: SIMD3<Float>, dims: PortalDimensions) -> BoundaryDecision {
        let d = c.z - dims.frameBackZ          // distance in front of the aperture plane
        if behind {
            if d > behindExit { behind = false }
        } else if d < behindEnter {
            behind = true
        }
        if behind {
            return BoundaryDecision(worldVisible: false, clarity: 0, behind: true,
                                    message: "View the doorway from the front")
        }
        let inFootprint = abs(c.x) < dims.outerHalfWidth + 0.25 && c.y < dims.outerTop + 0.3
        guard inFootprint else {
            return BoundaryDecision(worldVisible: true, clarity: 1, behind: false, message: nil)
        }
        let clarity = PortalMath.smoothstep(veilDistance, clearDistance, d)
        return BoundaryDecision(worldVisible: true, clarity: clarity, behind: false,
                                message: clarity < 0.6 ? "Step back - this is as close as the view goes" : nil)
    }
}
