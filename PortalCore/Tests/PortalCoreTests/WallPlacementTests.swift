import XCTest
import simd
@testable import PortalCore

final class WallPlacementTests: XCTestCase {
    let dims = PortalDimensions()

    func wallInput() -> PlacementInput {
        PlacementInput(hitPoint: SIMD3(0, 0, -2), cameraPosition: SIMD3(0, 1.4, 0),
                       planeKind: .wall, lowestHorizontalPlaneY: -0.6,
                       planeExtent: SIMD2(2, 2), obstructionPoints: 500, trackingNormal: true)
    }

    func testWallOpeningDoesNotUseFloorAndClearVolumeRules() {
        XCTAssertNil(PlacementRules().evaluate(wallInput()), "the intentionally intersected wall is not an obstruction")
    }

    func testWallStillRequiresTrackingAndUsefulDistance() {
        let rules = PlacementRules()
        var i = wallInput()
        i.trackingNormal = false
        XCTAssertEqual(rules.evaluate(i), .trackingNotReady)
        i.trackingNormal = true
        i.hitPoint.z = -0.2
        XCTAssertEqual(rules.evaluate(i), .tooClose)
        i.hitPoint.z = -6
        XCTAssertEqual(rules.evaluate(i), .tooFar)
        i.hitPoint.z = -2
        i.planeExtent = SIMD2(0.2, 0.2)
        XCTAssertEqual(rules.evaluate(i), .wallTooSmall)
    }

    func testApertureIsFlushToWallAndNormalFacesRoom() throws {
        let hit = SIMD3<Float>(0.4, 1.3, -2)
        for normal in [SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 0, -1)] {
            let pose = try XCTUnwrap(PortalMath.wallPlacement(hit: hit, normal: normal, camera: SIMD3(0, 1.4, 0), floorY: 0, dims: dims))
            let point = PortalMath.fromPortalSpace(SIMD3(0, hit.y, dims.occluderZ), portal: pose)
            XCTAssertEqual(simd_distance(point, hit), 0, accuracy: 1e-5)
            XCTAssertEqual(pose.columns.2.z, 1, accuracy: 1e-5)
            XCTAssertEqual(pose.columns.3.y, 0, accuracy: 1e-5)
        }
    }

    func testObliqueWallUsesItsNormalNotCameraFacingYaw() throws {
        let n = simd_normalize(SIMD3<Float>(1, 0, 1))
        let hit = SIMD3<Float>(0, 1.3, -2)
        let pose = try XCTUnwrap(PortalMath.wallPlacement(hit: hit, normal: n, camera: hit + SIMD3(-1, 0.2, 3), floorY: nil, dims: dims))
        XCTAssertEqual(pose.columns.2.x, n.x, accuracy: 1e-5)
        XCTAssertEqual(pose.columns.2.z, n.z, accuracy: 1e-5)
    }

    func testWallCanBePlacedWithoutSeeingFloor() throws {
        let hit = SIMD3<Float>(0, 1.6, -2)
        let pose = try XCTUnwrap(PortalMath.wallPlacement(hit: hit, normal: SIMD3(0, 0, 1), camera: SIMD3(0, 1.5, 0), floorY: nil, dims: dims))
        let centre = PortalMath.fromPortalSpace(SIMD3(0, (dims.openY0 + dims.openY1) / 2, dims.occluderZ), portal: pose)
        XCTAssertEqual(simd_distance(centre, hit), 0, accuracy: 1e-5)
        XCTAssertNil(PortalMath.wallPlacement(hit: hit, normal: SIMD3(0, 1, 0), camera: .zero, floorY: nil, dims: dims))
    }

    func testDraggingStaysOnWallPlane() throws {
        let point = SIMD3<Float>(0, 0, -2)
        let normal = SIMD3<Float>(0, 0, 1)
        let hit = try XCTUnwrap(PortalMath.intersectPlane(origin: SIMD3(0, 1, 0), direction: SIMD3(0.2, 0.3, -1), point: point, normal: normal))
        XCTAssertEqual(simd_dot(hit - point, normal), 0, accuracy: 1e-5)
        XCTAssertNil(PortalMath.intersectPlane(origin: .zero, direction: SIMD3(1, 0, 0), point: point, normal: normal))
        XCTAssertNil(PortalMath.intersectPlane(origin: .zero, direction: SIMD3(0, 0, 1), point: point, normal: normal))
    }

    func testInsideViewTranslationKeepsTrackedMotionOneToOne() {
        let physical = SIMD3<Float>(0.4, 1.4, 2)
        let offset = PortalMath.interiorViewOffset(cameraLocal: physical)
        let virtual = physical - offset
        XCTAssertEqual(virtual.x, 0, accuracy: 1e-5)
        XCTAssertEqual(virtual.y, 1.4, accuracy: 1e-5)
        XCTAssertEqual(virtual.z, -0.8, accuracy: 1e-5)
        let delta = SIMD3<Float>(0.2, 0.1, -0.1)
        XCTAssertEqual(simd_distance((physical + delta - offset) - virtual, delta), 0, accuracy: 1e-5)
    }

    func testExplicitInsideViewDoesNotNeedPhysicalWallCrossing() {
        var p = BoundaryPolicy()
        p.enterInside(cameraLocal: SIMD3(0, 1.3, -0.8))
        XCTAssertTrue(p.evaluate(cameraLocal: SIMD3(0.1, 1.3, -0.8), dims: dims, allowCrossing: false).insideWorld)
        p = BoundaryPolicy()
        XCTAssertFalse(p.evaluate(cameraLocal: SIMD3(0, 1.3, 1), dims: dims, allowCrossing: false).insideWorld)
    }
}
