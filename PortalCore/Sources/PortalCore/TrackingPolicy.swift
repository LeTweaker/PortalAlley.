import Foundation

/// ARKit tracking state, reduced to what matters here.
public enum TrackingQuality: Equatable, Sendable {
    case normal
    case initializing
    case relocalizing
    case excessiveMotion
    case insufficientFeatures
    case notAvailable
}

public struct TrackingDecision: Equatable, Sendable {
    /// Show the destination through the aperture.
    public var apertureVisible: Bool
    /// Show the doorway frame itself (hidden while its pose cannot be trusted).
    public var frameVisible: Bool
    /// Tracking has been continuously normal long enough to trust poses.
    public var trustworthy: Bool
    /// Ask the user whether to place the doorway again.
    public var offerReplacement: Bool
    public var message: String?
}

/// Decides how the portal reacts to tracking quality.  It never touches the
/// doorway's pose: it only hides/fades content and offers an explicit
/// "place again" when recovery takes too long.
public struct TrackingPolicy: Sendable {
    /// Short hiccups (one-off excessive motion) are tolerated for this long.
    public var limitedGrace: TimeInterval = 0.35
    /// Tracking must be normal for this long before content is restored.
    public var restoreAfterStable: TimeInterval = 0.6
    /// After this long without trustworthy tracking, offer to place again.
    public var offerReplacementAfter: TimeInterval = 8.0

    public private(set) var normalSince: TimeInterval?
    public private(set) var degradedSince: TimeInterval?
    public private(set) var poseInDoubt = false        // relocalizing / interruption happened

    public init() {}

    /// Call after an interruption (app backgrounded, camera taken) ends.
    public mutating func noteInterruption(now: TimeInterval) {
        poseInDoubt = true
        normalSince = nil
        if degradedSince == nil { degradedSince = now }
    }

    public mutating func update(_ q: TrackingQuality, lowLight: Bool, now: TimeInterval) -> TrackingDecision {
        switch q {
        case .normal:
            // A hiccup shorter than the grace period never closed the aperture,
            // so it must not trigger the restore delay either.
            if let ds = degradedSince, !poseInDoubt, normalSince == nil, now - ds <= limitedGrace {
                degradedSince = nil
            }
            if normalSince == nil { normalSince = now }
            let stable = now - (normalSince ?? now) >= restoreAfterStable
            if stable {
                degradedSince = nil
                poseInDoubt = false
            }
            let trusted = stable || (degradedSince == nil && !poseInDoubt)
            return TrackingDecision(apertureVisible: trusted, frameVisible: trusted || !poseInDoubt,
                                    trustworthy: trusted, offerReplacement: false,
                                    message: trusted ? (lowLight ? "More light would help" : nil) : "Hold steady…")

        case .excessiveMotion, .insufficientFeatures:
            normalSince = nil
            if degradedSince == nil { degradedSince = now }
            let since = now - (degradedSince ?? now)
            let tolerated = since < limitedGrace && !poseInDoubt
            let msg: String
            if q == .excessiveMotion {
                msg = "Move the phone more slowly"
            } else {
                msg = lowLight ? "Too dark - add some light" : "Point at a more detailed area"
            }
            return TrackingDecision(apertureVisible: tolerated, frameVisible: !poseInDoubt,
                                    trustworthy: false, offerReplacement: poseInDoubt && since > offerReplacementAfter,
                                    message: tolerated ? nil : msg)

        case .relocalizing, .initializing, .notAvailable:
            normalSince = nil
            if degradedSince == nil { degradedSince = now }
            if q == .relocalizing { poseInDoubt = true }
            let since = now - (degradedSince ?? now)
            let msg = q == .relocalizing ? "Look around where you placed the doorway"
                                         : (q == .initializing ? "Move the phone slowly to start" : "Tracking unavailable")
            return TrackingDecision(apertureVisible: false, frameVisible: false, trustworthy: false,
                                    offerReplacement: since > offerReplacementAfter, message: msg)
        }
    }
}
