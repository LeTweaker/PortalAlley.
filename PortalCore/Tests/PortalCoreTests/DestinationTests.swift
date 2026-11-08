import XCTest
import simd
@testable import PortalCore

/// v1.4: captured (Spatial) and footage (Cinematic) destinations.
final class DestinationTests: XCTestCase {
    let dims = PortalDimensions()
    static let portalDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/Portal")

    func manifest() throws -> AssetManifest {
        try AssetManifest.load(from: Self.portalDir.appendingPathComponent("manifest.json"))
    }

    // MARK: destination scenes

    func testIllustratedSceneMatchesTheV13Transforms() {
        for mode in DestinationMode.allCases {
            let a = mode.worldTransform(dims: dims)
            let b = mode.worldTransform(dims: dims, scene: .illustrated)
            for c in 0..<4 { for r in 0..<4 { XCTAssertEqual(a[c][r], b[c][r], accuracy: 1e-6) } }
            XCTAssertEqual(mode.clipCode, mode.clipCode(scene: .illustrated), accuracy: 1e-6)
        }
    }

    func testEveryShippedSceneStaysUprightAndCentredOnEverySurface() throws {
        let m = try manifest()
        let dests = try XCTUnwrap(m.destinations)
        for (id, d) in dests where d.kind != .video {
            let scene = d.scene(id: id)
            for mode in [DestinationMode.floor, .ceiling] {
                let w = mode.worldTransform(dims: dims, scene: scene)
                let p: SIMD4<Float> = simd_mul(w, SIMD4<Float>(scene.aperture(mode), 1))
                XCTAssertEqual(p.y, (dims.openY0 + dims.openY1) / 2, accuracy: 1e-4, id)
                XCTAssertEqual(p.z, dims.occluderZ, accuracy: 1e-4, id)
                // composed with any floor/ceiling pose the destination's up is world up
                let pose: simd_float4x4
                if mode == .floor {
                    pose = try XCTUnwrap(PortalPose.make(.floor, point: SIMD3<Float>(0, 0, -2), normal: SIMD3<Float>(0, 1, 0),
                                                         camera: SIMD3<Float>(0, 1.5, 0), cameraForward: SIMD3<Float>(0, 0, -1), floorY: nil))
                } else {
                    pose = try XCTUnwrap(PortalPose.make(.ceiling, point: SIMD3<Float>(0, 2.6, -1), normal: SIMD3<Float>(0, -1, 0),
                                                         camera: SIMD3<Float>(0, 1.5, 0), cameraForward: SIMD3<Float>(0, 0, -1), floorY: nil))
                }
                let composed: simd_float4x4 = simd_mul(pose, w)
                let up: SIMD4<Float> = simd_mul(composed, SIMD4<Float>(0, 1, 0, 0))
                XCTAssertEqual(up.y, 1, accuracy: 1e-5, id)
                XCTAssertTrue(DestinationMode.keeps(alleyY: scene.aperture(mode).y + (mode == .floor ? -0.5 : 0.5), code: mode.clipCode(scene: scene)))
            }
        }
    }

    func testFootageOnlyOnWallLikeOpenings() {
        let v = DestinationScene(id: "v", kind: .video, floorAperture: .zero, ceilingAperture: .zero)
        XCTAssertTrue(v.supports(.wall))
        XCTAssertFalse(v.supports(.floor))
        XCTAssertFalse(v.supports(.ceiling))
        XCTAssertTrue(DestinationScene.illustrated.supports(.floor))
    }

    // MARK: cinematic screen

    func testCinematicScreenCoversTheWholeViewingZone() {
        let zone = CinematicScreen.Zone()
        let s = CinematicScreen.fit(depth: 2.5, aspect: 16.0 / 9.0, zone: zone, dims: dims)
        XCTAssertEqual(s.width / s.height, 16.0 / 9.0, accuracy: 1e-3)
        XCTAssertEqual(s.centre.z, dims.occluderZ - 2.5, accuracy: 1e-5)
        let a = zone.maxAngleDegrees * .pi / 180
        for d in stride(from: zone.minDistance, through: zone.maxDistance, by: 0.4) {
            for ang in stride(from: -a, through: a, by: a / 4) {
                for h in stride(from: zone.heights.lowerBound, through: zone.heights.upperBound, by: 0.275) {
                    XCTAssertTrue(s.covers(from: SIMD3(sin(ang) * d, h, cos(ang) * d), dims: dims), "d \(d) a \(ang) h \(h)")
                }
            }
        }
    }

    func testLeaningInBeyondTheZoneShowsTheEdgeInsteadOfPretending() {
        let s = CinematicScreen.fit(depth: 2.5, aspect: 16.0 / 9.0, dims: dims)
        // pressed against the opening, looking sideways: flat footage cannot fill it
        XCTAssertFalse(s.covers(from: SIMD3(0.45, 1.5, 0.15), dims: dims))
        XCTAssertFalse(s.covers(from: SIMD3(0, 1.5, -0.5), dims: dims), "behind the opening")
        // farther away you see less of the frame (it is a picture at a fixed depth)
        XCTAssertGreaterThan(s.visibleFraction(from: SIMD3(0, 1.5, 1.2), dims: dims), s.visibleFraction(from: SIMD3(0, 1.5, 4.0), dims: dims))
    }

    // MARK: shipped capture

    func testCapturedDestinationShipsWithProvenanceAndLiesBehindTheOpening() throws {
        let m = try manifest()
        let dests = try XCTUnwrap(m.destinations)
        let id = try XCTUnwrap(m.defaultDestination)
        let d = try XCTUnwrap(dests[id])
        XCTAssertEqual(d.kind, .capture)
        XCTAssertFalse((d.credit ?? "").isEmpty)
        XCTAssertTrue((d.licence ?? "").hasPrefix("CC BY"), "licence must be redistributable")
        for name in [d.mesh, d.meshLow].compactMap({ $0 }) {
            let info = try XCTUnwrap(m.meshes[name])
            XCTAssertEqual(info.lazy, true, "destination meshes load on demand")
            let parts = try MeshPack.parse(Data(contentsOf: Self.portalDir.appendingPathComponent(info.file)))
            for p in parts where p.chunk != "skyfull" {
                XCTAssertNotNil(m.materials[p.material], p.material)
                XCTAssertLessThan(p.positions.map(\.z).max()!, dims.occluderZ - 0.0035, "\(name)/\(p.chunk) in front of the occluder")
            }
            // metric sanity: the captured ground near the opening is at the room floor,
            // and the alley 3-8 m in is a narrow walkable passage (0.8-4 m wide)
            let cap = parts.filter { $0.chunk == "capture" }
            var ground: [Float] = []
            var walk: [Float] = []
            for p in cap {
                for i in 0..<min(p.positions.count, p.normals.count) {
                    let q: SIMD3<Float> = p.positions[i]
                    guard p.normals[i].y > 0.9 else { continue }
                    if q.z < -1 && q.z > -4 && abs(q.x) < 0.5 { ground.append(q.y) }
                    if q.z < -3 && q.z > -8 && abs(q.y) < 0.3 { walk.append(q.x) }
                }
            }
            ground.sort()
            walk.sort()
            guard ground.count > 30, walk.count > 30 else {
                XCTFail("\(name): too few ground samples (\(ground.count), \(walk.count))"); continue
            }
            XCTAssertEqual(ground[ground.count / 2], 0, accuracy: 0.15, "\(name): ground height")
            let width = walk[walk.count * 95 / 100] - walk[walk.count * 5 / 100]
            XCTAssertTrue((0.8...4.0).contains(width), "\(name): passage width \(width) m")
        }
    }
}
