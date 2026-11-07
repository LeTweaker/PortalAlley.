import Foundation
import simd

/// What ARKit says about the plane under the placement ray.
public enum PlaneKind: Equatable, Sendable {
    case floor, table, seat, ceiling, wall, door, window
    case unclassified          // classification supported but undetermined
    case classificationUnsupported
}

public struct PlacementInput: Equatable, Sendable {
    public var hitPoint: SIMD3<Float>
    public var cameraPosition: SIMD3<Float>
    public var planeKind: PlaneKind
    /// y of the lowest horizontal plane ARKit currently knows about.
    public var lowestHorizontalPlaneY: Float?
    /// ARPlaneAnchor extent (width, height) in metres.
    public var planeExtent: SIMD2<Float>
    /// LiDAR only: reconstructed points inside the doorway volume (nil = unknown).
    public var obstructionPoints: Int?
    public var trackingNormal: Bool

    public init(hitPoint: SIMD3<Float>, cameraPosition: SIMD3<Float>, planeKind: PlaneKind,
                lowestHorizontalPlaneY: Float?, planeExtent: SIMD2<Float>, obstructionPoints: Int?, trackingNormal: Bool) {
        self.hitPoint = hitPoint
        self.cameraPosition = cameraPosition
        self.planeKind = planeKind
        self.lowestHorizontalPlaneY = lowestHorizontalPlaneY
        self.planeExtent = planeExtent
        self.obstructionPoints = obstructionPoints
        self.trackingNormal = trackingNormal
    }
}

public enum PlacementIssue: Equatable, Sendable {
    case trackingNotReady
    case notAFloor
    case notLowestSurface
    case cameraHeightImplausible
    case tooClose
    case tooFar
    case floorTooSmall
    case areaNotClear

    /// One short plain-language instruction for the user.
    public var message: String {
        switch self {
        case .trackingNotReady: return "Hold steady for a moment"
        case .notAFloor: return "Aim at the floor"
        case .notLowestSurface: return "Aim at the floor, not furniture"
        case .cameraHeightImplausible: return "Aim at the floor in front of you"
        case .tooClose: return "Aim a little farther away"
        case .tooFar: return "Aim closer - within about 4 metres"
        case .floorTooSmall: return "Scan a bit more of the floor"
        case .areaNotClear: return "Choose a clear spot"
        }
    }
}

public struct PlacementRules: Sendable {
    public var minDistance: Float = 1.0        // horizontal, camera -> doorway
    public var maxDistance: Float = 4.5
    public var cameraHeight: ClosedRange<Float> = 0.6...2.4
    public var lowestPlaneTolerance: Float = 0.12
    public var minExtentLong: Float = 0.8
    public var minExtentShort: Float = 0.4
    public var obstructionLimit: Int = 30

    public init() {}

    /// nil means the placement is credible.  Checks run cheapest-first and the
    /// first failing rule is reported, so the instruction is always specific.
    public func evaluate(_ i: PlacementInput) -> PlacementIssue? {
        guard i.trackingNormal else { return .trackingNotReady }
        switch i.planeKind {
        case .table, .seat, .ceiling, .wall, .door, .window: return .notAFloor
        case .floor, .unclassified, .classificationUnsupported: break
        }
        if let low = i.lowestHorizontalPlaneY, i.hitPoint.y > low + lowestPlaneTolerance {
            return .notLowestSurface
        }
        let h = i.cameraPosition.y - i.hitPoint.y
        if !cameraHeight.contains(h) { return .cameraHeightImplausible }
        let d = simd_length(SIMD2(i.cameraPosition.x - i.hitPoint.x, i.cameraPosition.z - i.hitPoint.z))
        if d < minDistance { return .tooClose }
        if d > maxDistance { return .tooFar }
        let longSide = max(i.planeExtent.x, i.planeExtent.y)
        let shortSide = min(i.planeExtent.x, i.planeExtent.y)
        if i.planeKind != .floor && (longSide < minExtentLong || shortSide < minExtentShort) { return .floorTooSmall }
        if let pts = i.obstructionPoints, pts > obstructionLimit { return .areaNotClear }
        return nil
    }
}

/// The doorway's occupied volume in portal space, used for the LiDAR clear-area
/// check and to exclude reconstruction noise from occlusion.
public struct DoorwayVolume: Sendable {
    public var halfWidth: Float = 0.72
    public var halfDepth: Float = 0.30
    public var minY: Float = 0.15
    public var maxY: Float = 2.2
    public init() {}
    public func contains(_ p: SIMD3<Float>) -> Bool {
        abs(p.x) < halfWidth && abs(p.z) < halfDepth && p.y > minY && p.y < maxY
    }
}
