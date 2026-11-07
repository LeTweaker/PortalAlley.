import Foundation

/// Display parameters for the doorway at one moment of its open/close animation.
public struct PortalLook: Equatable, Sendable {
    public var frameOpacity: Float     // whole doorway (room-side object)
    public var edgeIntensity: Float    // cyan light channel
    public var edgeSweep: Float        // 0..1 travelling highlight along the channel (0 = none)
    public var seamIntensity: Float    // light lines at the aperture leaf edges
    public var apertureOpen: Float     // 0 = leaves closed (room visible), 1 = fully open
    public var veil: Float             // haze in the opened aperture (0 = clear)

    public init(frameOpacity: Float, edgeIntensity: Float, edgeSweep: Float, seamIntensity: Float, apertureOpen: Float, veil: Float) {
        self.frameOpacity = frameOpacity
        self.edgeIntensity = edgeIntensity
        self.edgeSweep = edgeSweep
        self.seamIntensity = seamIntensity
        self.apertureOpen = apertureOpen
        self.veil = veil
    }

    public static let closed = PortalLook(frameOpacity: 1, edgeIntensity: 0.35, edgeSweep: 0, seamIntensity: 0, apertureOpen: 0, veil: 0)
    public static let open = PortalLook(frameOpacity: 1, edgeIntensity: 1, edgeSweep: 0, seamIntensity: 0, apertureOpen: 1, veil: 0)
}

/// Brief, restrained opening: the doorway materialises, its light channel
/// powers up with one travelling highlight, a thin seam appears in the
/// aperture, the leaves part from the centre and the destination's haze clears.
public enum OpeningTimeline {
    public static let duration: Float = 1.9
    public static let closeDuration: Float = 0.6

    static func ease(_ x: Float) -> Float { let t = min(max(x, 0), 1); return t * t * (3 - 2 * t) }
    static func seg(_ t: Float, _ a: Float, _ b: Float) -> Float { min(max((t - a) / (b - a), 0), 1) }

    public static func opening(at t: Float) -> PortalLook {
        let frame = ease(seg(t, 0.0, 0.35))
        let edgeUp = ease(seg(t, 0.25, 0.85))
        let sweep = seg(t, 0.25, 1.05)
        let seamIn = ease(seg(t, 0.70, 0.92))
        let seamOut = ease(seg(t, 1.40, 1.85))
        let open = ease(seg(t, 0.90, 1.75))
        let haze = seg(t, 0.90, 1.90)
        return PortalLook(
            frameOpacity: frame,
            edgeIntensity: 0.35 * frame + 0.65 * edgeUp,
            edgeSweep: (sweep > 0 && sweep < 1) ? sweep : 0,
            seamIntensity: seamIn * (1 - seamOut),
            apertureOpen: open,
            veil: open > 0 ? 0.55 * (1 - ease(haze)) : 0
        )
    }

    public static func closing(at t: Float) -> PortalLook {
        let k = ease(seg(t, 0, closeDuration * 0.75))
        let fade = ease(seg(t, closeDuration * 0.5, closeDuration))
        return PortalLook(frameOpacity: 1 - fade, edgeIntensity: 1 - 0.65 * k, edgeSweep: 0,
                          seamIntensity: k > 0 && k < 1 ? 0.6 : 0, apertureOpen: 1 - k, veil: 0)
    }
}
