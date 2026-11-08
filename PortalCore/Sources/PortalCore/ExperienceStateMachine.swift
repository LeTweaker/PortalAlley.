import Foundation

/// Open app -> scan -> preview placement -> tap -> adjust -> confirm -> portal
/// opens -> explore.  Pure state; the AR controller feeds events and renders.
public enum ExperiencePhase: String, Equatable, Sendable {
    case idle          // start screen
    case scanning      // waiting for usable tracking + a floor
    case aiming        // preview follows the floor under the screen centre
    case adjusting     // preview pinned; drag / twist to adjust, confirm to open
    case opening       // doorway anchored and locked; opening animation
    case open          // exploring
    case closing       // closing animation, then idle
}

public enum ExperienceEvent: Equatable, Sendable {
    case start
    case trackingUsable(Bool)
    case placementValid(Bool)
    case tap
    /// Easy Mode: CREATE PORTAL places straight from the live preview.
    case create
    case confirm
    case back
    case openingFinished
    case reposition
    case close
    case closingFinished
}

public struct ExperienceStateMachine: Sendable {
    public private(set) var phase: ExperiencePhase = .idle
    public private(set) var placementValid = false
    public private(set) var trackingUsable = false

    public init() {}

    /// Applies an event; returns true when the phase changed.
    @discardableResult
    public mutating func handle(_ e: ExperienceEvent) -> Bool {
        let before = phase
        switch (phase, e) {
        case (_, .placementValid(let v)):
            placementValid = v
        case (_, .trackingUsable(let u)):
            trackingUsable = u
            if phase == .scanning && u { phase = .aiming }
            if phase == .aiming && !u { phase = .scanning }
        case (.idle, .start):
            phase = trackingUsable ? .aiming : .scanning
        case (.aiming, .tap) where placementValid:
            phase = .adjusting
        case (.adjusting, .back):
            phase = trackingUsable ? .aiming : .scanning
        case (.aiming, .create) where placementValid && trackingUsable:
            phase = .opening
        case (.adjusting, .confirm) where placementValid:
            phase = .opening
        case (.opening, .openingFinished):
            phase = .open
        case (.opening, .reposition), (.open, .reposition):
            phase = trackingUsable ? .aiming : .scanning
        case (.opening, .close), (.open, .close):
            phase = .closing
        case (.scanning, .close), (.aiming, .close), (.adjusting, .close):
            phase = .idle
        case (.closing, .closingFinished):
            phase = .idle
        default:
            break
        }
        return phase != before
    }

    /// True while a doorway is anchored in the world (its pose is locked).
    public var doorwayAnchored: Bool {
        phase == .opening || phase == .open || phase == .closing
    }

    public var showsPreview: Bool { phase == .aiming || phase == .adjusting }
}
