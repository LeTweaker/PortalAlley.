import XCTest
import simd
@testable import PortalCore

/// Validates the assets that actually ship in the app bundle
/// (App/Resources/Portal), using the same parser the app uses.
final class ShippedAssetTests: XCTestCase {
    static let portalDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // PortalCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // PortalCore
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("App/Resources/Portal")

    func manifest() throws -> AssetManifest {
        try AssetManifest.load(from: Self.portalDir.appendingPathComponent("manifest.json"))
    }

    func testManifestDecodesAndDimensionsAreConsistent() throws {
        let m = try manifest()
        XCTAssertEqual(m.version, 1)
        XCTAssertTrue(m.dimensions.isConsistent)
        XCTAssertEqual(m.dimensions.openHalfWidth * 2, 0.96, accuracy: 1e-4)
        XCTAssertEqual(m.dimensions.openY1 - m.dimensions.openY0, 2.02, accuracy: 1e-4)
        XCTAssertEqual(m.lights.count, 16)
        XCTAssertLessThanOrEqual(m.lowTierLightCount, m.lights.count)
    }

    func testEveryTextureFileExists() throws {
        let m = try manifest()
        for (name, t) in m.textures {
            XCTAssertTrue(FileManager.default.fileExists(atPath: Self.portalDir.appendingPathComponent(t.file).path), name)
            XCTAssertTrue(["color", "raw"].contains(t.semantic))
        }
        for (name, mat) in m.materials {
            for (_, tex) in mat.textures ?? [:] { XCTAssertNotNil(m.textures[tex], "\(name) -> \(tex)") }
        }
    }

    func testMeshesParseAndReferenceKnownMaterials() throws {
        let m = try manifest()
        for (name, info) in m.meshes {
            let parts = try MeshPack.parse(Data(contentsOf: Self.portalDir.appendingPathComponent(info.file)))
            XCTAssertFalse(parts.isEmpty, name)
            for p in parts {
                XCTAssertNotNil(m.materials[p.material], "\(name): unknown material \(p.material)")
                XCTAssertEqual(p.positions.count, p.normals.count)
                XCTAssertEqual(p.positions.count, p.uvs.count)
                XCTAssertEqual(p.indices.count % 3, 0)
                for n in p.normals { XCTAssertEqual(simd_length(n), 1, accuracy: 1e-3) }
            }
            // triangles may be fewer than the manifest count (degenerate ones are stripped on export)
            XCTAssertLessThanOrEqual(parts.reduce(0) { $0 + $1.triangleCount }, info.triangles)
        }
    }

    /// The core portal invariant: the doorway lives entirely on the room side of
    /// the depth-only occluder plane, the destination entirely behind it.  If a
    /// destination vertex crossed the plane it would leak into the room; if a
    /// frame vertex crossed it the occluder would clip the doorway.
    func testOccluderPlaneSeparatesDoorwayFromDestination() throws {
        let m = try manifest()
        let zocc = m.dimensions.occluderZ
        let frame = try MeshPack.parse(Data(contentsOf: Self.portalDir.appendingPathComponent(m.meshes["frame"]!.file)))
        let alley = try MeshPack.parse(Data(contentsOf: Self.portalDir.appendingPathComponent(m.meshes["alley"]!.file)))
        let frameMinZ = frame.flatMap { $0.positions }.map(\.z).min()!
        let alleyMaxZ = alley.flatMap { $0.positions }.map(\.z).max()!
        XCTAssertGreaterThan(frameMinZ, zocc)
        XCTAssertLessThan(alleyMaxZ, zocc - 0.004)
    }

    func testRequiredDepthBands() throws {
        // near geometry 1-3 m behind the opening, midground 4-12 m, continuation beyond
        let m = try manifest()
        let alley = try MeshPack.parse(Data(contentsOf: Self.portalDir.appendingPathComponent(m.meshes["alley"]!.file)))
        let solid = alley.filter { !$0.material.hasPrefix("rain_") && $0.material != "sky" }
        func trianglesIn(_ range: ClosedRange<Float>) -> Int {
            solid.reduce(0) { acc, p in
                acc + stride(from: 0, to: p.indices.count, by: 3).filter { k in
                    let c = (p.positions[Int(p.indices[k])] + p.positions[Int(p.indices[k + 1])] + p.positions[Int(p.indices[k + 2])]) / 3
                    return range.contains(-c.z)
                }.count
            }
        }
        XCTAssertGreaterThan(trianglesIn(1...3), 500, "near detail")
        XCTAssertGreaterThan(trianglesIn(4...12), 3000, "midground architecture")
        XCTAssertGreaterThan(trianglesIn(12...30), 3000, "farther continuation")
    }

    func testOcclusionAndAuxChunksPresent() throws {
        let m = try manifest()
        let aux = try MeshPack.parse(Data(contentsOf: Self.portalDir.appendingPathComponent(m.meshes["portal_aux"]!.file)))
        let chunks = Set(aux.map(\.chunk))
        for c in ["occluder", "leaf", "shadow", "spill", "veil", "seam", "footprint"] { XCTAssertTrue(chunks.contains(c), c) }
        // occluder wall lies exactly on the documented plane
        let occ = aux.filter { $0.chunk == "occluder" }.flatMap(\.positions)
        for p in occ { XCTAssertEqual(p.z, m.dimensions.occluderZ, accuracy: 1e-5) }
    }

    /// v1.3: the subtle boundary ships with an exact-size occluder whose hole
    /// is the clear opening, plus trim and reveal; the alley carries baked
    /// lighting in uv1 with values in the documented ranges.
    func testSubtleBoundaryAndBakedLightingShip() throws {
        let m = try manifest()
        let aux = try MeshPack.parse(Data(contentsOf: Self.portalDir.appendingPathComponent(m.meshes["portal_aux"]!.file)))
        let chunks = Set(aux.map(\.chunk))
        for c in ["occluder_exact", "veil_exact", "trim", "reveal"] { XCTAssertTrue(chunks.contains(c), c) }
        let exact = aux.filter { $0.chunk == "occluder_exact" }
        for p in exact.flatMap(\.positions) { XCTAssertEqual(p.z, m.dimensions.occluderZ, accuracy: 1e-5) }
        // no occluder triangle covers the opening's centre
        let centre = SIMD2<Float>(0, (m.dimensions.openY0 + m.dimensions.openY1) / 2)
        for p in exact {
            for k in stride(from: 0, to: p.indices.count, by: 3) {
                let a = p.positions[Int(p.indices[k])], b = p.positions[Int(p.indices[k + 1])], c = p.positions[Int(p.indices[k + 2])]
                func side(_ u: SIMD3<Float>, _ v: SIMD3<Float>) -> Float { (v.x - u.x) * (centre.y - u.y) - (v.y - u.y) * (centre.x - u.x) }
                let s0 = side(a, b), s1 = side(b, c), s2 = side(c, a)
                XCTAssertFalse((s0 > 0 && s1 > 0 && s2 > 0) || (s0 < 0 && s1 < 0 && s2 < 0), "occluder covers the opening")
            }
        }
        // the reveal lies behind the aperture plane, the trim in front of it
        for p in aux where p.chunk == "reveal" { for q in p.positions { XCTAssertLessThanOrEqual(q.z, m.dimensions.occluderZ + 1e-5) } }
        for p in aux where p.chunk == "trim" { for q in p.positions { XCTAssertGreaterThanOrEqual(q.z, m.dimensions.occluderZ - 1e-5) } }
        let alley = try MeshPack.parse(Data(contentsOf: Self.portalDir.appendingPathComponent(m.meshes["alley"]!.file)))
        let baked = alley.filter { $0.uv1 != nil }
        XCTAssertGreaterThan(baked.count, 20, "lit surfaces carry baked lighting")
        for p in baked {
            for i in 0..<p.positions.count {
                let l = try XCTUnwrap(p.bakedLighting(at: i))
                XCTAssertTrue((0...1).contains(l.x) && (0...1).contains(l.y), "\(p.material) \(l)")
            }
        }
        XCTAssertTrue(alley.contains { $0.chunk == "backcap" }, "floor/ceiling closure present")
    }

    /// Every material sampled with a normal map must have one that exists.
    func testPhotographedMaterialsReferenceTheirMaps() throws {
        let m = try manifest()
        let photographed = m.materials.filter { ($0.value.textures ?? [:])["normal"] != nil }
        XCTAssertGreaterThan(photographed.count, 15)
        for (name, mat) in photographed { XCTAssertNotNil(m.textures[mat.textures!["normal"]!], name) }
    }

    func testMeshPackRejectsCorruptData() {
        XCTAssertThrowsError(try MeshPack.parse(Data("NOPE".utf8))) { XCTAssertEqual($0 as? MeshPackError, .badMagic) }
        var d = Data("PMSH".utf8)
        d.append(contentsOf: [1, 0, 0, 0, 1, 0, 0, 0, 3, 0])
        XCTAssertThrowsError(try MeshPack.parse(d)) { XCTAssertEqual($0 as? MeshPackError, .truncated) }
    }
}
