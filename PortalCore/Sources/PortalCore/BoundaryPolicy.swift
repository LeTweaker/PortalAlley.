import Foundation
import simd

public struct BoundaryDecision: Equatable, Sendable {
    public var worldVisible: Bool
    /// Opening animations may still use a veil; approaching the portal does not.
    public var clarity: Float
    public var behind: Bool
    /// Render the destination around the camera, with a return aperture.
    public var insideWorld: Bool
    public var message: String?
}

/// Tracks the camera passing THROUGH the doorway, not simply being behind it.
/// Camera positions are always in the existing anchored portal coordinate space.
public struct BoundaryPolicy: Sendable {
    public var crossingHysteresis: Float = 0.02
    public var edgeMargin: Float = 0.02
    /// Discontinuous tracking poses must not become apparent door crossings.
    public var maxSampleTravel: Float = 0.75
    public private(set) var insideWorld = false
    private var previousCamera: SIMD3<Float>?
    private var pendingInside: Bool?

    public init() {}

    /// Do not infer a crossing over a tracking interruption or relocalization.
    /// Preserve the last confirmed side, but discard the discontinuous segment.
    public mutating func suspendCrossing() {
        previousCamera = nil
        pendingInside = nil
    }

    public mutating func evaluate(cameraLocal c: SIMD3<Float>, dims: PortalDimensions,
                                  allowCrossing: Bool = true) -> BoundaryDecision {
        let d = c.z - dims.occluderZ
        if allowCrossing {
            if let p = previousCamera {
                if simd_distance(p, c) <= maxSampleTravel {
                    let pd = p.z - dims.occluderZ
                    if (pd >= 0 && d < 0) || (pd <= 0 && d > 0) {
                        let dz = d - pd
                        if abs(dz) > 1e-6 {
                            let t = -pd / dz
                            let hit = p + (c - p) * t
                            if t >= 0 && t <= 1 &&
                               abs(hit.x) < dims.openHalfWidth - edgeMargin &&
                               hit.y > dims.openY0 + edgeMargin &&
                               hit.y < dims.openY1 - edgeMargin {
                                pendingInside = d < 0
                            } else {
                                // Going around the frame is not entering it.
                                pendingInside = nil
                            }
                        }
                    }
                    if pendingInside == true && d <= -crossingHysteresis {
                        insideWorld = true
                        pendingInside = nil
                    } else if pendingInside == false && d >= crossingHysteresis {
                        insideWorld = false
                        pendingInside = nil
                    }
                } else {
                    pendingInside = nil
                }
            }
            previousCamera = c
        } else {
            suspendCrossing()
        }
        // Within the 2 cm hysteresis band, render the side the camera physically
        // occupies for an eligible crossing. This avoids a flash of camera feed
        // between crossing the aperture and committing the new stable side.
        var renderInside = insideWorld
        if let pending = pendingInside {
            if pending && d < 0 { renderInside = true }
            if !pending && d > 0 { renderInside = false }
        }
        let visible = renderInside || d >= 0
        return BoundaryDecision(worldVisible: visible, clarity: visible ? 1 : 0,
                                behind: d < 0, insideWorld: renderInside,
                                message: renderInside ? "Pull your phone back through the doorway to return"
                                    : (d < 0 ? "Enter through the opening, or return to the front" : nil))
    }
}

