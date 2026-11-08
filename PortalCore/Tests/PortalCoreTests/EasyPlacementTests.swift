import XCTest
import simd
@testable import PortalCore

/// v1.2.2 regression coverage: a first-time user must always be able to
/// create a visible portal while tracking works, preferring real walls.
final class EasyPlacementTests: XCTestCase {
    let easy = EasyPlacement()
    let dims = PortalDimensions()
    let cam = SIMD3<Float>(0, 1.45, 0)
    let forward = SIMD3<Float>(0, 0, -1)

    func wall(at z: Float, y: Float = 1.4, normal: SIMD3<Float> = SIMD3(0, 0, 1), extent: SIMD2<Float>? = SIMD2(2, 2)) -> SurfaceHit {
        SurfaceHit(point: SIMD3(0, y, z), normal: normal, extent: extent)
    }

    func assertVisible(_ p: PlacementProposal, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(PlacementSafety.check(portal: p.transform, camera: cam, cameraForward: forward, dims: dims), file: file, line: line)
        XCTAssertEqual(simd_determinant(p.transform), 1, accuracy: 1e-4, "no scaling or mirroring", file: file, line: line)
        XCTAssertEqual(p.transform.columns.1.y, 1, accuracy: 1e-5, "upright", file: file, line: line)
    }

    // MARK: method selection

    func testDetectedWallIsPreferred() {
        let p = easy.resolve(EasyPlacementInput(camera: cam, cameraForward: forward,
                                                detectedWall: wall(at: -2), estimatedWall: wall(at: -2.5), confirmedFloorY: 0))
        XCTAssertEqual(p.method, .wall)
        XCTAssertTrue(p.ready)
        XCTAssertEqual(p.status, "Ready to place on the wall")
        // aperture back flush to the wall, bottom on the floor, facing the user
        XCTAssertEqual(p.position.y, 0, accuracy: 1e-5)
        XCTAssertEqual(p.position.z, -2 + 0.125, accuracy: 1e-4)
        XCTAssertEqual(p.transform.columns.2.z, 1, accuracy: 1e-5)
        assertVisible(p)
    }

    func testEstimatedWallWhenNoPlaneDetectedYet() {
        let p = easy.resolve(EasyPlacementInput(camera: cam, cameraForward: forward, estimatedWall: wall(at: -1.8)))
        XCTAssertEqual(p.method, .estimatedWall)
        XCTAssertTrue(p.ready)
        assertVisible(p)
    }

    func testTinyDetectedPlaneFallsBackToEstimate() {
        let p = easy.resolve(EasyPlacementInput(camera: cam, cameraForward: forward,
                                                detectedWall: wall(at: -2, extent: SIMD2(0.2, 0.1)), estimatedWall: wall(at: -2)))
        XCTAssertEqual(p.method, .estimatedWall)
    }

    func testNonVerticalSurfacesAreNotWalls() {
        let p = easy.resolve(EasyPlacementInput(camera: cam, cameraForward: forward,
                                                estimatedWall: wall(at: -2, normal: SIMD3(0, 1, 0.1))))
        XCTAssertEqual(p.method, .standing)
    }

    // MARK: never stuck

    func testNoWallStillOffersAStandingDoorway() {
        let p = easy.resolve(EasyPlacementInput(camera: cam, cameraForward: forward))
        XCTAssertEqual(p.method, .standing)
        XCTAssertTrue(p.ready, "the user must never be stuck searching while tracking works")
        XCTAssertNotNil(p.hint)
        XCTAssertEqual(simd_distance(p.position, SIMD3(0, 1.45 - 1.4, -2.2)), 0, accuracy: 1e-4)
        XCTAssertEqual(p.transform.columns.2.z, 1, accuracy: 1e-5, "viewing side faces the camera")
        assertVisible(p)
    }

    func testFarWallFallsBackWithAHint() {
        let p = easy.resolve(EasyPlacementInput(camera: cam, cameraForward: forward, detectedWall: wall(at: -7)))
        XCTAssertEqual(p.method, .standing)
        XCTAssertTrue(p.ready)
        XCTAssertEqual(p.hint, "Move closer to a wall to mount it there")
    }

    func testTooCloseToAWallAsksToStepBackInsteadOfSpawningInsideIt() {
        let p = easy.resolve(EasyPlacementInput(camera: cam, cameraForward: forward, detectedWall: wall(at: -0.4)))
        XCTAssertFalse(p.ready)
        XCTAssertEqual(p.status, "Step back about a metre from the wall")
    }

    func testNotReadyWithoutTracking() {
        let p = easy.resolve(EasyPlacementInput(camera: cam, cameraForward: forward, detectedWall: wall(at: -2), trackingNormal: false))
        XCTAssertFalse(p.ready)
        XCTAssertEqual(p.status, "Hold steady for a moment")
        XCTAssertFalse(easy.resolve(EasyPlacementInput(camera: cam, cameraForward: forward, trackingNormal: false)).ready)
    }

    func testLookingStraightDownIsNotReady() {
        let p = easy.resolve(EasyPlacementInput(camera: cam, cameraForward: SIMD3(0, -1, 0.01)))
        XCTAssertFalse(p.ready)
        XCTAssertEqual(p.status, "Raise the phone to look ahead")
    }

    // MARK: positioning

    func testFloorEstimates() {
        XCTAssertEqual(easy.floorY(EasyPlacementInput(camera: cam, cameraForward: forward, confirmedFloorY: 0.02)), 0.02)
        XCTAssertEqual(easy.floorY(EasyPlacementInput(camera: cam, cameraForward: forward, confirmedFloorY: 1.44, lowestPlaneY: -0.01)), -0.01,
                       "an implausible floor right under the lens is ignored")
        XCTAssertEqual(easy.floorY(EasyPlacementInput(camera: cam, cameraForward: forward)), 0.05, accuracy: 1e-5)
    }

    func testWallDoorStandsOnEstimatedFloorWhenAimingAtEyeLevel() {
        // v1.2.1 centred the opening on the aim point without a classified floor,
        // so aiming at eye level gave a door floating ~0.4 m above the floor.
        let p = easy.resolve(EasyPlacementInput(camera: cam, cameraForward: forward, detectedWall: wall(at: -2, y: 1.45)))
        XCTAssertEqual(p.position.y, 1.45 - 1.4, accuracy: 1e-5)
    }

    /// Sweep headings, wall angles and distances: every ready proposal is in
    /// front of the camera, facing it, at a sensible distance, upright.
    func testEveryReadyProposalIsVisible() {
        var checked = 0
        for heading in stride(from: Float(-180), to: 180, by: 30) {
            let h = heading * .pi / 180
            let f = SIMD3<Float>(sin(h), -0.15, -cos(h))
            for d in [Float(0.8), 1.5, 3, 4.4] {
                for tilt in [Float(-35), 0, 35] {
                    let t = (heading + tilt) * .pi / 180
                    let hitPoint = cam + SIMD3(sin(h), 0, -cos(h)) * d + SIMD3(0, -0.2, 0)
                    let n = SIMD3<Float>(-sin(t), 0, cos(t))      // roughly facing the camera
                    for input in [EasyPlacementInput(camera: cam, cameraForward: f, detectedWall: SurfaceHit(point: hitPoint, normal: n, extent: SIMD2(2, 2))),
                                  EasyPlacementInput(camera: cam, cameraForward: f, estimatedWall: SurfaceHit(point: hitPoint, normal: -n)),
                                  EasyPlacementInput(camera: cam, cameraForward: f)] {
                        let p = easy.resolve(input)
                        XCTAssertTrue(p.ready, "heading \(heading) d \(d) tilt \(tilt) \(p.method)")
                        XCTAssertNil(PlacementSafety.check(portal: p.transform, camera: cam, cameraForward: f, dims: dims))
                        checked += 1
                    }
                }
            }
        }
        XCTAssertEqual(checked, 12 * 4 * 3 * 3)
    }

    // MARK: safety

    func testSafetyRejectsBadSpawns() {
        let facing = PortalMath.transform(position: SIMD3(0, 0, -2), yaw: 0)
        XCTAssertNil(PlacementSafety.check(portal: facing, camera: cam, cameraForward: forward))
        XCTAssertEqual(PlacementSafety.check(portal: facing, camera: cam, cameraForward: SIMD3(0, 0, 1)), .behindCamera)
        XCTAssertEqual(PlacementSafety.check(portal: facing, camera: cam, cameraForward: SIMD3(1, 0, -0.2)), .outsideView)
        let backwards = PortalMath.transform(position: SIMD3(0, 0, -2), yaw: .pi)
        XCTAssertEqual(PlacementSafety.check(portal: backwards, camera: cam, cameraForward: forward), .cameraOnWrongSide)
        let close = PortalMath.transform(position: SIMD3(0, 0, -0.3), yaw: 0)
        XCTAssertEqual(PlacementSafety.check(portal: close, camera: cam, cameraForward: forward), .tooCloseToCamera)
        let far = PortalMath.transform(position: SIMD3(0, 0, -9), yaw: 0)
        XCTAssertEqual(PlacementSafety.check(portal: far, camera: cam, cameraForward: forward), .tooFar)
    }

    // MARK: find portal

    func testFindPortalDirections() {
        let ahead = FindPortal.hint(camera: cam, cameraForward: forward, target: SIMD3(0, 1, -3))
        XCTAssertEqual(ahead.turnDegrees, 0, accuracy: 0.01)
        XCTAssertEqual(ahead.message, "The portal is ahead (3 m away)")
        let right = FindPortal.hint(camera: cam, cameraForward: forward, target: SIMD3(2, 1, 0))
        XCTAssertEqual(right.turnDegrees, 90, accuracy: 0.01)
        XCTAssertTrue(right.message.hasPrefix("Turn right about 90°"))
        let left = FindPortal.hint(camera: cam, cameraForward: forward, target: SIMD3(-2, 1, -2))
        XCTAssertEqual(left.turnDegrees, -45, accuracy: 0.01)
        XCTAssertTrue(left.message.hasPrefix("Turn left"))
        let behind = FindPortal.hint(camera: cam, cameraForward: forward, target: SIMD3(0.1, 1, 3))
        XCTAssertTrue(behind.message.hasPrefix("The portal is behind you"))
    }

    // MARK: flow

    func testCreatePortalGoesStraightToOpening() {
        var m = ExperienceStateMachine()
        m.handle(.trackingUsable(true))
        m.handle(.start)
        XCTAssertEqual(m.phase, .aiming)
        XCTAssertFalse(m.handle(.create), "not ready yet")
        m.handle(.placementValid(true))
        XCTAssertTrue(m.handle(.create))
        XCTAssertEqual(m.phase, .opening)
        XCTAssertTrue(m.doorwayAnchored)
    }

    func testCreateNeedsTracking() {
        var m = ExperienceStateMachine()
        m.handle(.start)
        m.handle(.placementValid(true))
        XCTAssertEqual(m.phase, .scanning)
        XCTAssertFalse(m.handle(.create))
    }

    func testMovePortalReturnsToLivePreviewAndCanCreateAgain() {
        var m = ExperienceStateMachine()
        m.handle(.trackingUsable(true)); m.handle(.start); m.handle(.placementValid(true)); m.handle(.create)
        m.handle(.openingFinished)
        XCTAssertEqual(m.phase, .open)
        m.handle(.reposition)
        XCTAssertEqual(m.phase, .aiming)
        XCTAssertFalse(m.doorwayAnchored)
        XCTAssertTrue(m.handle(.create))
    }

    func testRestartScanAfterTrackingLossRecovers() {
        var m = ExperienceStateMachine()
        m.handle(.trackingUsable(true)); m.handle(.start)
        m.handle(.trackingUsable(false))
        XCTAssertEqual(m.phase, .scanning)
        m.handle(.trackingUsable(true))
        XCTAssertEqual(m.phase, .aiming, "recovers to the live preview without user action")
        var r = ScanRecoveryPolicy()
        XCTAssertFalse(r.shouldRestart(.relocalizing, hasDoorway: false, now: 0))
        XCTAssertTrue(r.shouldRestart(.relocalizing, hasDoorway: false, now: 3.1), "unplaced scans never wait forever")
    }
}
