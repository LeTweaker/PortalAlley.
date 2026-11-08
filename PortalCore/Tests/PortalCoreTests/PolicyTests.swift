import XCTest
import simd
@testable import PortalCore

final class PlacementRulesTests: XCTestCase {
    let rules = PlacementRules()
    func input(_ mutate: (inout PlacementInput) -> Void = { _ in }) -> PlacementInput {
        var i = PlacementInput(hitPoint: SIMD3(0, 0, -2), cameraPosition: SIMD3(0, 1.45, 0), planeKind: .floor,
                               lowestHorizontalPlaneY: 0, planeExtent: SIMD2(2, 1.5), obstructionPoints: 0, trackingNormal: true)
        mutate(&i)
        return i
    }

    func testCredibleFloorPasses() { XCTAssertNil(rules.evaluate(input())) }
    func testTrackingMustBeNormal() { XCTAssertEqual(rules.evaluate(input { $0.trackingNormal = false }), .trackingNotReady) }
    func testFurnitureRejected() {
        XCTAssertEqual(rules.evaluate(input { $0.planeKind = .table }), .notAFloor)
        XCTAssertEqual(rules.evaluate(input { $0.planeKind = .seat }), .notAFloor)
    }
    func testUnclassifiedRaisedSurfaceRejected() {
        XCTAssertEqual(rules.evaluate(input { $0.planeKind = .unclassified; $0.hitPoint.y = 0.72 }), .notLowestSurface)
    }
    func testCameraHeight() {
        XCTAssertNil(rules.evaluate(input { $0.cameraPosition.y = 0.3 }), "a low-held phone can still place a portal on a detected floor")
        XCTAssertEqual(rules.evaluate(input { $0.cameraPosition.y = 0.05; $0.lowestHorizontalPlaneY = nil }), .cameraHeightImplausible)
        XCTAssertEqual(rules.evaluate(input { $0.cameraPosition.y = -0.1 }), .cameraHeightImplausible)
        XCTAssertEqual(rules.evaluate(input { $0.cameraPosition.y = 3.0 }), .cameraHeightImplausible)
    }
    func testClassifiedFloorNotRejectedByUnrelatedLowerPlane() {
        XCTAssertNil(rules.evaluate(input { $0.lowestHorizontalPlaneY = -0.5 }), "a lower estimate must not override ARKit's floor classification")
    }
    func testRaisedUnclassifiedSurfaceStillRejectedWithLowHeldPhone() {
        XCTAssertEqual(rules.evaluate(input {
            $0.planeKind = .unclassified
            $0.hitPoint.y = 0.72
            $0.cameraPosition.y = 1.0
        }), .notLowestSurface)
    }
    func testDistanceLimits() {
        XCTAssertEqual(rules.evaluate(input { $0.hitPoint = SIMD3(0, 0, -0.6) }), .tooClose)
        XCTAssertEqual(rules.evaluate(input { $0.hitPoint = SIMD3(0, 0, -6) }), .tooFar)
    }
    func testSmallUnclassifiedPlaneNeedsMoreScanning() {
        XCTAssertEqual(rules.evaluate(input { $0.planeKind = .classificationUnsupported; $0.planeExtent = SIMD2(0.5, 0.3) }), .floorTooSmall)
        XCTAssertNil(rules.evaluate(input { $0.planeExtent = SIMD2(0.5, 0.3) }), "a classified floor is trusted while it grows")
    }
    func testObstruction() {
        XCTAssertEqual(rules.evaluate(input { $0.obstructionPoints = 200 }), .areaNotClear)
        XCTAssertNil(rules.evaluate(input { $0.obstructionPoints = nil }), "no LiDAR: cannot judge, do not block")
    }
    func testDoorwayVolume() {
        let v = DoorwayVolume()
        XCTAssertTrue(v.contains(SIMD3(0.2, 1.0, 0.1)))
        XCTAssertFalse(v.contains(SIMD3(0.2, 0.05, 0.1)), "floor noise is ignored")
        XCTAssertFalse(v.contains(SIMD3(1.5, 1.0, 0)))
    }
}

final class TrackingPolicyTests: XCTestCase {
    func testRequiresStableNormalBeforeShowing() {
        var p = TrackingPolicy()
        XCTAssertFalse(p.update(.initializing, lowLight: false, now: 0).apertureVisible)
        XCTAssertFalse(p.update(.normal, lowLight: false, now: 1.0).apertureVisible)
        XCTAssertFalse(p.update(.normal, lowLight: false, now: 1.4).apertureVisible)
        let d = p.update(.normal, lowLight: false, now: 1.7)
        XCTAssertTrue(d.apertureVisible)
        XCTAssertTrue(d.trustworthy)
        XCTAssertNil(d.message)
    }

    func testBriefHiccupDoesNotFlicker() {
        var p = TrackingPolicy()
        _ = p.update(.normal, lowLight: false, now: 0)
        XCTAssertTrue(p.update(.normal, lowLight: false, now: 1).apertureVisible)
        XCTAssertTrue(p.update(.excessiveMotion, lowLight: false, now: 1.1).apertureVisible, "within grace")
        XCTAssertTrue(p.update(.normal, lowLight: false, now: 1.3).apertureVisible, "recovered instantly after a short hiccup")
    }

    func testSustainedLimitedTrackingClosesApertureButKeepsFrame() {
        var p = TrackingPolicy()
        _ = p.update(.normal, lowLight: false, now: 0)
        _ = p.update(.normal, lowLight: false, now: 1)
        _ = p.update(.insufficientFeatures, lowLight: false, now: 2)
        let d = p.update(.insufficientFeatures, lowLight: false, now: 3)
        XCTAssertFalse(d.apertureVisible)
        XCTAssertTrue(d.frameVisible, "pose is still trusted; only the illusion is paused")
        XCTAssertEqual(d.message, "Point at a more detailed area")
        XCTAssertEqual(p.update(.insufficientFeatures, lowLight: true, now: 3.1).message, "Too dark - add some light")
        XCTAssertFalse(p.update(.normal, lowLight: false, now: 3.2).apertureVisible, "restore waits for stability")
        XCTAssertTrue(p.update(.normal, lowLight: false, now: 3.9).apertureVisible)
    }

    func testRelocalizationHidesEverythingAndOffersReplacement() {
        var p = TrackingPolicy()
        _ = p.update(.normal, lowLight: false, now: 0)
        _ = p.update(.normal, lowLight: false, now: 1)
        var d = p.update(.relocalizing, lowLight: false, now: 2)
        XCTAssertFalse(d.apertureVisible)
        XCTAssertFalse(d.frameVisible)
        XCTAssertFalse(d.offerReplacement)
        d = p.update(.relocalizing, lowLight: false, now: 10.5)
        XCTAssertTrue(d.offerReplacement)
        // ARKit relocalizes: content returns only after stable normal tracking
        XCTAssertFalse(p.update(.normal, lowLight: false, now: 11).frameVisible)
        let back = p.update(.normal, lowLight: false, now: 11.7)
        XCTAssertTrue(back.frameVisible && back.apertureVisible && !back.offerReplacement)
    }

    func testInterruptionPutsPoseInDoubt() {
        var p = TrackingPolicy()
        _ = p.update(.normal, lowLight: false, now: 0)
        _ = p.update(.normal, lowLight: false, now: 1)
        p.noteInterruption(now: 5)
        XCTAssertFalse(p.update(.normal, lowLight: false, now: 5.1).apertureVisible)
        XCTAssertTrue(p.update(.normal, lowLight: false, now: 5.8).apertureVisible)
    }
}

final class BoundaryPolicyTests: XCTestCase {
    let dims = PortalDimensions()
    func camera(_ distance: Float, x: Float = 0, y: Float = 1.3) -> SIMD3<Float> {
        SIMD3(x, y, dims.occluderZ + distance)
    }

    func enter(_ p: inout BoundaryPolicy) {
        _ = p.evaluate(cameraLocal: camera(0.3), dims: dims)
        _ = p.evaluate(cameraLocal: camera(-0.3), dims: dims)
    }

    func testApproachStaysClearWithoutOldThirtyCentimetreVeil() {
        var p = BoundaryPolicy()
        for d in [Float(0.6), 0.3, 0.1, 0.01] {
            let v = p.evaluate(cameraLocal: camera(d), dims: dims)
            XCTAssertTrue(v.worldVisible)
            XCTAssertFalse(v.insideWorld)
            XCTAssertEqual(v.clarity, 1)
        }
    }

    func testCrossOpeningEntersAndPullingBackReturns() {
        var p = BoundaryPolicy()
        enter(&p)
        XCTAssertTrue(p.insideWorld)
        let inside = p.evaluate(cameraLocal: camera(-0.35), dims: dims)
        XCTAssertTrue(inside.worldVisible && inside.insideWorld)
        XCTAssertEqual(inside.clarity, 1)
        let outside = p.evaluate(cameraLocal: camera(0.25), dims: dims)
        XCTAssertFalse(p.insideWorld || outside.insideWorld)
        XCTAssertTrue(outside.worldVisible)
    }

    func testStartingBehindDoorwayDoesNotEnter() {
        var p = BoundaryPolicy()
        let v = p.evaluate(cameraLocal: camera(-0.3), dims: dims)
        XCTAssertFalse(v.insideWorld || v.worldVisible)
    }

    func testGoingAroundEitherJambDoesNotEnter() {
        for x in [Float(-1), 1] {
            var p = BoundaryPolicy()
            _ = p.evaluate(cameraLocal: camera(0.2, x: x), dims: dims)
            let v = p.evaluate(cameraLocal: camera(-0.2, x: x), dims: dims)
            XCTAssertFalse(v.insideWorld || v.worldVisible)
        }
    }

    func testCrossingAboveOrBelowOpeningDoesNotEnter() {
        for y in [Float(0), 2.2] {
            var p = BoundaryPolicy()
            _ = p.evaluate(cameraLocal: camera(0.2, y: y), dims: dims)
            XCTAssertFalse(p.evaluate(cameraLocal: camera(-0.2, y: y), dims: dims).insideWorld)
        }
    }

    func testCrossingIntersectionMustBeInsideEvenIfEndpointIsInside() {
        var p = BoundaryPolicy()
        // End inside the rectangle but cross the plane outside the right jamb.
        // Use a larger sample budget to isolate the intersection test.
        p.maxSampleTravel = 3
        _ = p.evaluate(cameraLocal: camera(0.2, x: 1.2), dims: dims)
        XCTAssertFalse(p.evaluate(cameraLocal: camera(-0.2), dims: dims).insideWorld)
    }

    func testHysteresisDoesNotFlashCameraFeedAtThreshold() {
        var p = BoundaryPolicy()
        _ = p.evaluate(cameraLocal: camera(0.1), dims: dims)
        let near = p.evaluate(cameraLocal: camera(-0.005), dims: dims)
        XCTAssertFalse(p.insideWorld, "stable side not committed inside the hysteresis band")
        XCTAssertTrue(near.worldVisible && near.insideWorld, "render the eligible side without a camera-feed flash")
        _ = p.evaluate(cameraLocal: camera(-0.04), dims: dims)
        XCTAssertTrue(p.insideWorld)
        _ = p.evaluate(cameraLocal: camera(0.005), dims: dims)
        XCTAssertTrue(p.insideWorld, "stable side is retained until clearly outside")
        _ = p.evaluate(cameraLocal: camera(0.04), dims: dims)
        XCTAssertFalse(p.insideWorld)
    }

    func testInsideDoesNotExitThroughSolidWall() {
        var p = BoundaryPolicy()
        enter(&p)
        _ = p.evaluate(cameraLocal: camera(-0.3, x: 0.7), dims: dims)
        let v = p.evaluate(cameraLocal: camera(0.2, x: 0.7), dims: dims)
        XCTAssertTrue(p.insideWorld && v.insideWorld)
    }

    func testTrackingGapCannotCreateCrossing() {
        var p = BoundaryPolicy()
        _ = p.evaluate(cameraLocal: camera(0.2), dims: dims)
        _ = p.evaluate(cameraLocal: camera(-0.2), dims: dims, allowCrossing: false)
        XCTAssertFalse(p.evaluate(cameraLocal: camera(-0.3), dims: dims).insideWorld)
    }

    func testSuspendPreservesInsideButDiscardsCrossingSegment() {
        var p = BoundaryPolicy()
        enter(&p)
        p.suspendCrossing()
        let v = p.evaluate(cameraLocal: camera(0.2), dims: dims)
        XCTAssertTrue(p.insideWorld && v.insideWorld)
    }

    func testLargePoseJumpDoesNotEnter() {
        var p = BoundaryPolicy()
        _ = p.evaluate(cameraLocal: camera(1), dims: dims)
        XCTAssertFalse(p.evaluate(cameraLocal: camera(-1), dims: dims).insideWorld)
    }

    func testSideViewNearThresholdDoesNotEnterOrVeil() {
        var p = BoundaryPolicy()
        let v = p.evaluate(cameraLocal: camera(0.05, x: 2), dims: dims)
        XCTAssertTrue(v.worldVisible)
        XCTAssertFalse(v.insideWorld)
        XCTAssertEqual(v.clarity, 1)
    }
}

final class ExperienceStateMachineTests: XCTestCase {
    func testHappyPath() {
        var m = ExperienceStateMachine()
        XCTAssertEqual(m.phase, .idle)
        m.handle(.start)
        XCTAssertEqual(m.phase, .scanning)
        m.handle(.trackingUsable(true))
        XCTAssertEqual(m.phase, .aiming)
        m.handle(.tap)
        XCTAssertEqual(m.phase, .aiming, "cannot pin an invalid placement")
        m.handle(.placementValid(true))
        m.handle(.tap)
        XCTAssertEqual(m.phase, .adjusting)
        m.handle(.confirm)
        XCTAssertEqual(m.phase, .opening)
        XCTAssertTrue(m.doorwayAnchored)
        m.handle(.openingFinished)
        XCTAssertEqual(m.phase, .open)
        m.handle(.close)
        XCTAssertEqual(m.phase, .closing)
        m.handle(.closingFinished)
        XCTAssertEqual(m.phase, .idle)
    }

    func testConfirmRequiresValidPlacement() {
        var m = ExperienceStateMachine()
        m.handle(.trackingUsable(true)); m.handle(.start); m.handle(.placementValid(true)); m.handle(.tap)
        m.handle(.placementValid(false))
        m.handle(.confirm)
        XCTAssertEqual(m.phase, .adjusting)
        m.handle(.back)
        XCTAssertEqual(m.phase, .aiming)
    }

    func testRepositionReturnsToAimingAndTrackingLossToScanning() {
        var m = ExperienceStateMachine()
        m.handle(.trackingUsable(true)); m.handle(.start); m.handle(.placementValid(true)); m.handle(.tap); m.handle(.confirm)
        m.handle(.openingFinished)
        m.handle(.reposition)
        XCTAssertEqual(m.phase, .aiming)
        XCTAssertFalse(m.doorwayAnchored)
        m.handle(.trackingUsable(false))
        XCTAssertEqual(m.phase, .scanning)
        XCTAssertFalse(m.handle(.openingFinished), "stray events are ignored")
    }
}

final class OpeningTimelineTests: XCTestCase {
    func testOpeningStartsClosedAndEndsFullyOpen() {
        let s = OpeningTimeline.opening(at: 0)
        XCTAssertEqual(s.apertureOpen, 0)
        XCTAssertEqual(s.frameOpacity, 0)
        XCTAssertEqual(s.veil, 0, "no haze over the closed doorway (room stays visible)")
        let e = OpeningTimeline.opening(at: OpeningTimeline.duration)
        let o = PortalLook.open
        XCTAssertEqual(e.frameOpacity, o.frameOpacity, accuracy: 1e-5)
        XCTAssertEqual(e.edgeIntensity, o.edgeIntensity, accuracy: 1e-5)
        XCTAssertEqual(e.edgeSweep, 0)
        XCTAssertEqual(e.seamIntensity, 0, accuracy: 1e-6)
        XCTAssertEqual(e.apertureOpen, 1, accuracy: 1e-6)
        XCTAssertEqual(e.veil, 0, accuracy: 1e-6)
    }

    func testApertureOpensMonotonically() {
        var last: Float = -1
        for i in 0...200 {
            let t = Float(i) / 200 * OpeningTimeline.duration
            let s = OpeningTimeline.opening(at: t)
            XCTAssertGreaterThanOrEqual(s.apertureOpen, last)
            XCTAssertTrue((0...1).contains(s.veil) && (0...1).contains(s.seamIntensity))
            last = s.apertureOpen
        }
    }

    func testClosingEndsClosedAndHidden() {
        let e = OpeningTimeline.closing(at: OpeningTimeline.closeDuration)
        XCTAssertEqual(e.apertureOpen, 0)
        XCTAssertEqual(e.frameOpacity, 0)
    }
}

final class FrameStatsTests: XCTestCase {
    func testSummary() {
        var s = FrameStats(capacity: 100)
        for _ in 0..<90 { s.add(intervalMs: 16.67) }
        for _ in 0..<10 { s.add(intervalMs: 33.3) }
        let r = s.summary()
        XCTAssertEqual(r.count, 100)
        XCTAssertEqual(r.maxMs, 33.3, accuracy: 1e-6)
        XCTAssertEqual(r.overBudget, 0.10, accuracy: 1e-6)
        XCTAssertEqual(r.p95Ms, 33.3, accuracy: 1e-6)
        s.add(intervalMs: .nan)
        XCTAssertEqual(s.summary().count, 100, "invalid samples rejected")
    }
}



