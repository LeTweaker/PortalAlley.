import XCTest
import simd
@testable import PortalCore

final class PortalGeometryTests: XCTestCase {
    func approx(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-4, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_length(a - b), eps, "\(a) != \(b)", file: file, line: line)
    }

    func testFacingYawPointsViewingSideAtCamera() {
        let floor = SIMD3<Float>(1, 0, -2)
        for cam in [SIMD3<Float>(1, 1.5, 0), SIMD3<Float>(3, 1.4, -2), SIMD3<Float>(-1, 1.6, -4), SIMD3<Float>(0.2, 1.5, -0.5)] {
            let yaw = PortalMath.facingYaw(floorPoint: floor, camera: cam)
            let m = PortalMath.transform(position: floor, yaw: yaw)
            // portal +z (viewing side) in world, horizontal
            let z = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
            let toCam = simd_normalize(SIMD3<Float>(cam.x - floor.x, 0, cam.z - floor.z))
            approx(z, toCam)
            // the camera is on the viewing side, in front of the aperture plane
            let local = PortalMath.toPortalSpace(cam, portal: m)
            XCTAssertGreaterThan(local.z, 0)
            XCTAssertEqual(local.x, 0, accuracy: 1e-4, "camera should be centred on the doorway it faces")
        }
    }

    func testTransformIsRigidAndGravityAligned() {
        let m = PortalMath.transform(position: SIMD3(0.3, -1.2, 2.0), yaw: 1.1)
        let c0 = SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let c1 = SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let c2 = SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        XCTAssertEqual(simd_length(c0), 1, accuracy: 1e-6)
        XCTAssertEqual(simd_length(c2), 1, accuracy: 1e-6)
        XCTAssertEqual(simd_dot(c0, c2), 0, accuracy: 1e-6)
        approx(c1, SIMD3(0, 1, 0), 1e-6)
        XCTAssertEqual(simd_determinant(m), 1, accuracy: 1e-5, "no mirroring")
        XCTAssertEqual(PortalMath.yaw(of: m), 1.1, accuracy: 1e-5)
    }

    func testPortalSpaceRoundTrip() {
        let m = PortalMath.transform(position: SIMD3(-2, 0.01, 3), yaw: -2.4)
        for p in [SIMD3<Float>(0, 0, 0), SIMD3(1, 2, 3), SIMD3(-4.2, 0.3, 9)] {
            approx(PortalMath.fromPortalSpace(PortalMath.toPortalSpace(p, portal: m), portal: m), p)
        }
        // destination points (z < 0) map behind the doorway, away from the viewer
        let behind = PortalMath.fromPortalSpace(SIMD3(0, 1, -5), portal: m)
        let camLocal = SIMD3<Float>(0, 1.5, 2)
        let cam = PortalMath.fromPortalSpace(camLocal, portal: m)
        let doorway = PortalMath.translation(m)
        XCTAssertGreaterThan(simd_distance(cam, behind), simd_distance(cam, doorway), "alley depth must recede from the viewer")
    }

    func testLeftRightAreNotMirrored() {
        // Viewer in front, facing the doorway: portal +x must be the viewer's right.
        let floor = SIMD3<Float>(0, 0, 0)
        let cam = SIMD3<Float>(0, 1.5, 2)
        let m = PortalMath.transform(position: floor, yaw: PortalMath.facingYaw(floorPoint: floor, camera: cam))
        let forward = simd_normalize(floor - cam * SIMD3(1, 0, 1))          // viewer looks toward the doorway
        let right = simd_cross(forward, SIMD3<Float>(0, 1, 0))
        let px = SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        XCTAssertGreaterThan(simd_dot(px, right), 0.99)
    }

    func testParallaxDirection() {
        // Moving the camera left must reveal more of the alley's right side:
        // project a deep point through the aperture plane and check it shifts.
        func apertureCrossing(cam: SIMD3<Float>, target: SIMD3<Float>, planeZ: Float) -> Float {
            let t = (planeZ - cam.z) / (target.z - cam.z)
            return cam.x + (target.x - cam.x) * t
        }
        let deepRight = SIMD3<Float>(1.5, 1.5, -10)
        let fromCentre = apertureCrossing(cam: SIMD3(0, 1.5, 2), target: deepRight, planeZ: -0.12)
        let fromLeft = apertureCrossing(cam: SIMD3(-1, 1.5, 2), target: deepRight, planeZ: -0.12)
        XCTAssertGreaterThan(fromCentre, 0.48 - 0.25, "sanity")
        XCTAssertLessThan(fromLeft, fromCentre, "from the left, deep right-side content moves toward the opening's centre")
    }

    func testRayPlaneIntersection() {
        let hit = PortalMath.intersectHorizontalPlane(origin: SIMD3(0, 1.5, 0), direction: simd_normalize(SIMD3(0, -1, -1)), planeY: 0)
        XCTAssertNotNil(hit)
        approx(hit!, SIMD3(0, 0, -1.5))
        XCTAssertNil(PortalMath.intersectHorizontalPlane(origin: SIMD3(0, 1.5, 0), direction: SIMD3(0, 1, 0), planeY: 0))
        XCTAssertNil(PortalMath.intersectHorizontalPlane(origin: SIMD3(0, 1.5, 0), direction: SIMD3(1, 0, 0), planeY: 0))
    }

    func testApproachIsFrameRateIndependent() {
        var a: Float = 0, b: Float = 0
        for _ in 0..<60 { a = PortalMath.approach(a, 1, rate: 5, dt: 1.0 / 60) }
        for _ in 0..<120 { b = PortalMath.approach(b, 1, rate: 5, dt: 1.0 / 120) }
        XCTAssertEqual(a, b, accuracy: 1e-3)
        XCTAssertEqual(PortalMath.wrapAngle(3 * .pi), .pi, accuracy: 1e-4)
    }

    func testDefaultDimensionsConsistent() {
        XCTAssertTrue(PortalDimensions().isConsistent)
    }
}
