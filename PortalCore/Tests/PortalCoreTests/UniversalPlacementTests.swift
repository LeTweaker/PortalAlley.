import XCTest
import simd
@testable import PortalCore

/// v1.3 universal placement: wall, floor, ceiling, angled (snapped) and
/// floating; gravity-coherent destination transforms; aperture resize/rotate.
final class UniversalPlacementTests: XCTestCase {
    let dims = PortalDimensions()
    let cam = SIMD3<Float>(0, 1.45, 0)
    let forward = SIMD3<Float>(0, 0, -1)
    let placement = UniversalPlacement()

    func dir(elevationDegrees e: Float, towardCamera: Bool = true) -> SIMD3<Float> {
        // a surface normal tilted from horizontal (+z, toward a camera at +z) by e degrees
        let r = e * .pi / 180
        return SIMD3(0, sin(r), cos(r) * (towardCamera ? 1 : -1))
    }

    func assertRigid(_ m: simd_float4x4, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(simd_determinant(m), 1, accuracy: 1e-4, "no scale or mirror", file: file, line: line)
        let r = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                              SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                              SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        let i = r.transpose * r
        for c in 0..<3 { for k in 0..<3 { XCTAssertEqual(i[c][k], c == k ? 1 : 0, accuracy: 1e-4, file: file, line: line) } }
    }

    // MARK: classification

    func testVerticalSurfaceIsAWall() {
        let c = SurfaceClassifier.classify(point: SIMD3(0, 1.4, -2), normal: SIMD3(0, 0, 1), camera: cam)
        XCTAssertEqual(c?.kind, .wall)
        XCTAssertEqual(c?.normal.z ?? 0, 1, accuracy: 1e-5)
        XCTAssertFalse(c?.wasAngled ?? true)
    }

    func testUpFacingSurfaceBelowCameraIsAFloor() {
        let c = SurfaceClassifier.classify(point: SIMD3(0, 0, -2), normal: SIMD3(0, 1, 0), camera: cam)
        XCTAssertEqual(c?.kind, .floor)
        XCTAssertEqual(c?.normal, SIMD3(0, 1, 0))
    }

    func testDownFacingSurfaceAboveCameraIsACeiling() {
        let c = SurfaceClassifier.classify(point: SIMD3(0, 2.6, -1.5), normal: SIMD3(0, -1, 0), camera: cam)
        XCTAssertEqual(c?.kind, .ceiling)
        XCTAssertEqual(c?.normal, SIMD3(0, -1, 0))
    }

    func testNormalReportedFromTheFarSideIsFlippedTowardTheCamera() {
        // estimated planes can come back with either orientation
        XCTAssertEqual(SurfaceClassifier.classify(point: SIMD3(0, 0, -2), normal: SIMD3(0, -1, 0), camera: cam)?.kind, .floor)
        XCTAssertEqual(SurfaceClassifier.classify(point: SIMD3(0, 2.6, -2), normal: SIMD3(0, 1, 0), camera: cam)?.kind, .ceiling)
        XCTAssertEqual(SurfaceClassifier.classify(point: SIMD3(0, 1.4, -2), normal: SIMD3(0, 0, -1), camera: cam)?.normal.z ?? 0, 1, accuracy: 1e-5)
    }

    func testAngledSurfacesSnapToTheNearestCategory() {
        // a ramp 25 degrees from horizontal (normal 65 degrees above horizontal)
        let ramp = SurfaceClassifier.classify(point: SIMD3(0, 0.2, -2), normal: dir(elevationDegrees: 65), camera: cam)
        XCTAssertEqual(ramp?.kind, .floor)
        XCTAssertEqual(ramp?.snappedDegrees ?? 0, 25, accuracy: 0.01)
        XCTAssertTrue(ramp?.wasAngled ?? false)
        // a wall leaning back 20 degrees
        let lean = SurfaceClassifier.classify(point: SIMD3(0, 1.4, -2), normal: dir(elevationDegrees: 20), camera: cam)
        XCTAssertEqual(lean?.kind, .wall)
        XCTAssertEqual(lean?.normal.y ?? 1, 0, accuracy: 1e-6, "snapped wall normal is horizontal")
        // a sloped ceiling (attic) 30 degrees
        let attic = SurfaceClassifier.classify(point: SIMD3(0, 2.5, -2), normal: dir(elevationDegrees: -60), camera: cam)
        XCTAssertEqual(attic?.kind, .ceiling)
    }

    func testAmbiguousSlopesAreRejectedUnlessARKitClassifiedThem() {
        let at = SIMD3<Float>(0, 0.5, -2)
        XCTAssertNil(SurfaceClassifier.classify(point: at, normal: dir(elevationDegrees: 45), camera: cam), "45 degrees: neither")
        XCTAssertNil(SurfaceClassifier.classify(point: at, normal: dir(elevationDegrees: 43), camera: cam))
        XCTAssertEqual(SurfaceClassifier.classify(point: at, normal: dir(elevationDegrees: 43), camera: cam, arkit: .wall)?.kind, .wall)
        XCTAssertNil(SurfaceClassifier.classify(point: at, normal: dir(elevationDegrees: 43), camera: cam, arkit: .floor),
                     "a disagreeing classification does not widen the limit")
        XCTAssertEqual(SurfaceClassifier.classify(point: at, normal: dir(elevationDegrees: 47), camera: cam, arkit: .floor)?.kind, .floor)
        XCTAssertNil(SurfaceClassifier.classify(point: at, normal: dir(elevationDegrees: 47), camera: cam, arkit: .table))
    }

    func testUpFacingSurfaceAboveEyeHeightIsNotAFloor() {
        XCTAssertNil(SurfaceClassifier.classify(point: SIMD3(0, 1.6, -1), normal: SIMD3(0, 1, 0), camera: cam))
        XCTAssertNil(SurfaceClassifier.classify(point: SIMD3(0, 1.3, -1), normal: SIMD3(0, -1, 0), camera: cam))
    }

    // MARK: poses

    func testFloorPoseLiesOnTheFloorCentredOnTheAimPoint() throws {
        let aim = SIMD3<Float>(0.3, 0, -2)
        let pose = try XCTUnwrap(PortalPose.make(.floor, point: aim, normal: SIMD3(0, 1, 0), camera: cam, cameraForward: forward, floorY: nil))
        assertRigid(pose)
        XCTAssertEqual(PortalPose.kind(of: pose), .floor)
        XCTAssertEqual(pose.columns.2.y, 1, accuracy: 1e-5, "normal up, toward the user")
        let centre = PortalMath.fromPortalSpace(SIMD3(0, (dims.openY0 + dims.openY1) / 2, dims.occluderZ), portal: pose)
        XCTAssertEqual(simd_distance(centre, aim), 0, accuracy: 1e-4, "occluder plane on the floor, opening centred on the aim point")
        // the opening's "top" points away from the user
        let away = simd_normalize(SIMD3<Float>(aim.x - cam.x, 0, aim.z - cam.z))
        XCTAssertGreaterThan(simd_dot(SIMD3(pose.columns.1.x, pose.columns.1.y, pose.columns.1.z), away), 0.99)
        // the camera is on the viewing side
        XCTAssertGreaterThan(PortalMath.toPortalSpace(cam, portal: pose).z, dims.frameFrontZ)
    }

    func testCeilingPoseFacesDownWithTopTowardTheUser() throws {
        let aim = SIMD3<Float>(0, 2.6, -1.2)
        let pose = try XCTUnwrap(PortalPose.make(.ceiling, point: aim, normal: SIMD3(0, -1, 0), camera: cam, cameraForward: forward, floorY: nil))
        assertRigid(pose)
        XCTAssertEqual(PortalPose.kind(of: pose), .ceiling)
        XCTAssertEqual(pose.columns.2.y, -1, accuracy: 1e-5)
        // tilting the phone up puts the top of the screen toward the user,
        // so portal +y points back toward the camera and +x stays to the right
        XCTAssertGreaterThan(pose.columns.1.z, 0.99)
        XCTAssertEqual(pose.columns.0.x, 1, accuracy: 1e-5)
        XCTAssertGreaterThan(PortalMath.toPortalSpace(cam, portal: pose).z, dims.frameFrontZ)
    }

    func testFloorPoseRightAxisMatchesTheViewer() throws {
        let pose = try XCTUnwrap(PortalPose.make(.floor, point: SIMD3(0, 0, -2), normal: SIMD3(0, 1, 0), camera: cam, cameraForward: forward, floorY: nil))
        XCTAssertEqual(pose.columns.0.x, 1, accuracy: 1e-5)
    }

    func testWallPoseIsUnchangedFromEasyMode() throws {
        let a = try XCTUnwrap(PortalPose.make(.wall, point: SIMD3(0, 1.4, -2), normal: SIMD3(0, 0, 1), camera: cam, cameraForward: forward, floorY: 0))
        let b = try XCTUnwrap(PortalMath.wallPlacement(hit: SIMD3(0, 1.4, -2), normal: SIMD3(0, 0, 1), camera: cam, floorY: 0, dims: dims))
        XCTAssertEqual(a, b)
        XCTAssertEqual(PortalPose.kind(of: a), .wall)
    }

    // MARK: destination modes

    func testDestinationStaysUprightOnEverySurface() throws {
        let poses: [(DestinationMode, simd_float4x4)] = [
            (.wall, try XCTUnwrap(PortalPose.make(.wall, point: SIMD3(0, 1.4, -2), normal: SIMD3(0, 0, 1), camera: cam, cameraForward: forward, floorY: 0))),
            (.floor, try XCTUnwrap(PortalPose.make(.floor, point: SIMD3(1, 0, -2), normal: SIMD3(0, 1, 0), camera: cam, cameraForward: forward, floorY: nil))),
            (.ceiling, try XCTUnwrap(PortalPose.make(.ceiling, point: SIMD3(-0.5, 2.6, -1), normal: SIMD3(0, -1, 0), camera: cam, cameraForward: forward, floorY: nil))),
        ]
        for (mode, pose) in poses {
            let w = pose * mode.worldTransform(dims: dims)
            assertRigid(w)
            let up = w * SIMD4<Float>(0, 1, 0, 0)
            XCTAssertEqual(up.y, 1, accuracy: 1e-5, "\(mode): alley up is world up")
            // the alley recedes away from the user
            let deep = w * SIMD4<Float>(0, 0, -1, 0)
            let toPortal = simd_normalize(SIMD3(pose.columns.3.x - cam.x, 0, pose.columns.3.z - cam.z))
            XCTAssertGreaterThan(deep.x * toPortal.x + deep.z * toPortal.z, 0.9, "\(mode)")
        }
    }

    func testApertureCentreShowsTheChosenAlleySpot() {
        for mode in [DestinationMode.floor, .ceiling] {
            let w = mode.worldTransform(dims: dims)
            let p = w * SIMD4(mode.aperture, 1)
            XCTAssertEqual(p.x, 0, accuracy: 1e-5)
            XCTAssertEqual(p.y, (dims.openY0 + dims.openY1) / 2, accuracy: 1e-5)
            XCTAssertEqual(p.z, dims.occluderZ, accuracy: 1e-5)
        }
    }

    func testClipKeepsExactlyTheGeometryBehindTheAperturePlane() {
        for mode in [DestinationMode.wall, .floor, .ceiling] {
            let w = mode.worldTransform(dims: dims)
            for y in stride(from: Float(-0.12), through: 14, by: 0.05) {
                let rigZ = (w * SIMD4<Float>(0.1, y, -6, 1)).z
                let kept = DestinationMode.keeps(alleyY: y, code: mode.clipCode)
                if mode == .wall { XCTAssertTrue(kept); continue }
                // anything that survives the clip is on the destination side of the occluder
                if kept { XCTAssertLessThan(rigZ, dims.occluderZ, "\(mode) y=\(y)") }
                // and nothing behind the plane (beyond the margin) is clipped
                if rigZ < dims.occluderZ - 0.01 { XCTAssertTrue(kept, "\(mode) y=\(y)") }
            }
        }
    }

    func testClipCodesAreDistinctAndDecodable() {
        XCTAssertEqual(DestinationMode.wall.clipCode, 0)
        XCTAssertGreaterThan(DestinationMode.floor.clipCode, 0)
        XCTAssertLessThanOrEqual(DestinationMode.floor.clipCode, 0.5)
        XCTAssertGreaterThan(DestinationMode.ceiling.clipCode, 0.5)
        XCTAssertLessThanOrEqual(DestinationMode.ceiling.clipCode, 1)
        XCTAssertEqual(DestinationMode.floor.clipCode * 20, DestinationMode.floor.apertureHeight, accuracy: 1e-5)
        XCTAssertEqual((DestinationMode.ceiling.clipCode - 0.5) * 20, DestinationMode.ceiling.apertureHeight, accuracy: 1e-5)
        // street visible from above, hidden from below
        XCTAssertTrue(DestinationMode.keeps(alleyY: -0.12, code: DestinationMode.floor.clipCode))
        XCTAssertFalse(DestinationMode.keeps(alleyY: -0.12, code: DestinationMode.ceiling.clipCode))
    }

    func testOnlyWallPortalsCanBeWalkedThrough() {
        XCTAssertTrue(DestinationMode.wall.allowsCrossing)
        XCTAssertFalse(DestinationMode.floor.allowsCrossing)
        XCTAssertFalse(DestinationMode.ceiling.allowsCrossing)
        XCTAssertEqual(DestinationMode(.floating), .wall)
    }

    // MARK: resize / rotate

    func testResizeIsClampedAndStepped() {
        var a = ApertureAdjustment()
        XCTAssertTrue(a.isIdentity)
        for _ in 0..<20 { a.grow() }
        XCTAssertEqual(a.scale, ApertureAdjustment.scaleRange.upperBound, accuracy: 1e-5)
        XCTAssertFalse(a.canGrow)
        for _ in 0..<30 { a.shrink() }
        XCTAssertEqual(a.scale, ApertureAdjustment.scaleRange.lowerBound, accuracy: 1e-5)
        XCTAssertFalse(a.canShrink)
        a.grow()
        XCTAssertEqual(a.scale, 0.6, accuracy: 1e-5, "no accumulated float drift")
    }

    func testRotateWrapsAround() {
        var a = ApertureAdjustment()
        for _ in 0..<24 { a.rotate(clockwise: true) }
        XCTAssertEqual(a.rotationDegrees, 0, accuracy: 1e-3)
        a.rotate(clockwise: false)
        XCTAssertEqual(a.rotationDegrees, 15, accuracy: 1e-3)
        for _ in 0..<12 { a.rotate(clockwise: false) }
        XCTAssertEqual(a.rotationDegrees, -165, accuracy: 1e-3)
    }

    func testAdjustmentKeepsTheApertureOnItsPlaneAndPivot() {
        let a = ApertureAdjustment(scale: 1.3, rotationDegrees: 30)
        for standing in [true, false] {
            let pivot = ApertureAdjustment.pivot(standingOnFloor: standing, dims: dims)
            let m = a.matrix(pivot: pivot)
            let p = m * SIMD4(pivot, 1)
            XCTAssertEqual(simd_distance(SIMD3(p.x, p.y, p.z), pivot), 0, accuracy: 1e-5, "pivot is fixed")
            let q = m * SIMD4<Float>(0.4, 1.7, dims.occluderZ, 1)
            XCTAssertEqual(q.z, dims.occluderZ, accuracy: 1e-6, "occluder plane unchanged")
            let corner = SIMD3<Float>(dims.openHalfWidth, dims.openY1, 0)
            let moved = m * SIMD4(corner, 1)
            XCTAssertEqual(simd_distance(a.toAperture(SIMD3(moved.x, moved.y, moved.z), pivot: pivot), corner), 0, accuracy: 1e-4)
        }
        XCTAssertEqual(ApertureAdjustment(scale: 9).scale, ApertureAdjustment.scaleRange.upperBound)
    }

    // MARK: resolver

    func testAimAtTheFloorGivesAFloorPortal() {
        let r = placement.resolve(UniversalPlacementInput(camera: cam, cameraForward: simd_normalize(SIMD3(0, -0.6, -1)),
                                                          aim: SurfaceHit(point: SIMD3(0, 0, -2), normal: SIMD3(0, 1, 0)), aimDetected: true))
        XCTAssertEqual(r.proposal.method, .floor)
        XCTAssertTrue(r.proposal.ready, r.proposal.status)
        XCTAssertEqual(r.surface?.kind, .floor)
    }

    func testFloorRightAtYourFeetIsRefused() {
        let r = placement.resolve(UniversalPlacementInput(camera: cam, cameraForward: simd_normalize(SIMD3(0, -1, -0.2)),
                                                          aim: SurfaceHit(point: SIMD3(0, 0, -0.3), normal: SIMD3(0, 1, 0))))
        XCTAssertEqual(r.proposal.method, .floor)
        XCTAssertFalse(r.proposal.ready)
        XCTAssertTrue(r.proposal.status.contains("farther"))
    }

    func testAimAtTheCeilingGivesACeilingPortal() {
        let r = placement.resolve(UniversalPlacementInput(camera: cam, cameraForward: simd_normalize(SIMD3(0, 1, -0.5)),
                                                          aim: SurfaceHit(point: SIMD3(0, 2.6, -0.9), normal: SIMD3(0, -1, 0))))
        XCTAssertEqual(r.proposal.method, .ceiling)
        XCTAssertTrue(r.proposal.ready, r.proposal.status)
    }

    func testAimAtAWallStillUsesEasyModeWallRules() {
        let r = placement.resolve(UniversalPlacementInput(camera: cam, cameraForward: forward,
                                                          aim: SurfaceHit(point: SIMD3(0, 1.4, -2), normal: SIMD3(0, 0, 1), extent: SIMD2(2, 2)),
                                                          aimDetected: true, confirmedFloorY: 0))
        XCTAssertEqual(r.proposal.method, .wall)
        XCTAssertEqual(r.proposal.position.y, 0, accuracy: 1e-5)
    }

    func testAngledSurfaceExplainsTheLevelling() {
        let r = placement.resolve(UniversalPlacementInput(camera: cam, cameraForward: simd_normalize(SIMD3(0, -0.6, -1)),
                                                          aim: SurfaceHit(point: SIMD3(0, 0.3, -2), normal: dir(elevationDegrees: 65))))
        XCTAssertEqual(r.proposal.method, .floor)
        XCTAssertNotNil(r.proposal.hint)
    }

    func testNothingUnderTheAimStillOffersAFloatingDoorway() {
        let r = placement.resolve(UniversalPlacementInput(camera: cam, cameraForward: forward))
        XCTAssertEqual(r.proposal.method, .standing)
        XCTAssertTrue(r.proposal.ready)
        XCTAssertNil(r.surface)
    }

    func testOffCentreFloorSpotIsNotReady() {
        // camera looks ahead; the floor hit is far off to the side
        let r = placement.resolve(UniversalPlacementInput(camera: cam, cameraForward: forward,
                                                          aim: SurfaceHit(point: SIMD3(2.5, 0, -0.7), normal: SIMD3(0, 1, 0))))
        XCTAssertFalse(r.proposal.ready)
    }

    // MARK: floor safety

    func testFloorSafetyWarnsWhenTheUserIsOverTheOpening() throws {
        let pose = try XCTUnwrap(PortalPose.make(.floor, point: SIMD3(0, 0, -2), normal: SIMD3(0, 1, 0), camera: cam, cameraForward: forward, floorY: nil))
        XCTAssertFalse(FloorPortalSafety.isOver(camera: cam, portal: pose))
        XCTAssertTrue(FloorPortalSafety.isOver(camera: SIMD3(0.1, 1.5, -2.2), portal: pose))
        XCTAssertTrue(FloorPortalSafety.isOver(camera: SIMD3(0.7, 1.5, -2.0), portal: pose), "edge margin")
        // a smaller, rotated opening: 0.8 m to the side is now clear of it
        XCTAssertFalse(FloorPortalSafety.isOver(camera: SIMD3(0.8, 1.5, -2.0), portal: pose,
                                                adjustment: ApertureAdjustment(scale: 0.5, rotationDegrees: 0)))
        let wall = try XCTUnwrap(PortalPose.make(.wall, point: SIMD3(0, 1.4, -2), normal: SIMD3(0, 0, 1), camera: cam, cameraForward: forward, floorY: 0))
        XCTAssertFalse(FloorPortalSafety.isOver(camera: SIMD3(0, 1.5, -1.9), portal: wall))
    }

    // MARK: preview smoothing

    func testPreviewSmoothingStaysRigidAndConverges() throws {
        let a = try XCTUnwrap(PortalPose.make(.wall, point: SIMD3(0, 1.4, -2), normal: SIMD3(0, 0, 1), camera: cam, cameraForward: forward, floorY: 0))
        let b = try XCTUnwrap(PortalPose.make(.floor, point: SIMD3(0.5, 0, -2), normal: SIMD3(0, 1, 0), camera: cam, cameraForward: forward, floorY: nil))
        var m = a
        for _ in 0..<60 {
            m = PoseSmoothing.blend(m, b, 0.35)
            assertRigid(m)
        }
        for c in 0..<4 { for r in 0..<4 { XCTAssertEqual(m[c][r], b[c][r], accuracy: 1e-3) } }
        let same = PoseSmoothing.blend(a, b, 0)
        for c in 0..<4 { for r in 0..<4 { XCTAssertEqual(same[c][r], a[c][r], accuracy: 1e-5) } }
    }

    // MARK: mesh pack v2 (baked lighting)

    func testMeshPackVersion2CarriesBakedLighting() throws {
        var d = Data("PMSH".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func f32(_ v: Float) { withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        u32(2); u32(1)
        u16(4); d.append(contentsOf: Array("near".utf8))
        u16(4); d.append(contentsOf: Array("mat1".utf8))
        u32(3); u32(3); u32(1)
        for v: Float in [0, 0, 0, 1, 0, 0, 0, 1, 0] { f32(v) }
        for v: Float in [0, 0, 1, 0, 0, 1, 0, 0, 1] { f32(v) }
        for v: Float in [0, 0, 1, 0, 0, 1] { f32(v) }
        for v: Float in [2.25, 0.4, 3, 0, 0, 0] { f32(v) }      // ao 0.75 vis 0.6 | ao 0 vis 1 | absent
        for v: UInt32 in [0, 1, 2] { u32(v) }
        let parts = try MeshPack.parse(d)
        XCTAssertEqual(parts.count, 1)
        let p = parts[0]
        XCTAssertEqual(p.uv1?.count, 3)
        XCTAssertEqual(p.bakedLighting(at: 0)?.x ?? -1, 0.75, accuracy: 1e-6)
        XCTAssertEqual(p.bakedLighting(at: 0)?.y ?? -1, 0.6, accuracy: 1e-6)
        XCTAssertEqual(p.bakedLighting(at: 1)?.x ?? -1, 0, accuracy: 1e-6)
        XCTAssertNil(p.bakedLighting(at: 2), "uv1 = 0 means no bake data")
    }
}
