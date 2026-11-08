import Foundation

/// Before placement there is no doorway pose worth restoring. A continuously
/// relocalizing scan gets one automatic fresh start, then manual control.
/// Never reset an existing doorway or loop resets in a hard-to-track room.
public struct ScanRecoveryPolicy: Sendable {
    public var recoveryDelay: TimeInterval = 3
    public private(set) var didAutomaticallyRestart = false
    private var relocalizingSince: TimeInterval?

    public init() {}

    public mutating func shouldRestart(_ quality: TrackingQuality, hasDoorway: Bool, now: TimeInterval) -> Bool {
        guard !hasDoorway, quality == .relocalizing else {
            relocalizingSince = nil
            return false
        }
        guard !didAutomaticallyRestart else { return false }
        if relocalizingSince == nil { relocalizingSince = now }
        guard now - (relocalizingSince ?? now) >= recoveryDelay else { return false }
        didAutomaticallyRestart = true
        relocalizingSince = nil
        return true
    }
}
