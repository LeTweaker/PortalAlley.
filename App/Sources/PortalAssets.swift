import CoreGraphics
import Foundation
import ImageIO
import Metal
import PortalCore
import RealityKit
import UIKit
import simd

/// Rendering quality tiers.  Both keep the full geometry, depth, tracking and
/// art direction; the low tier trims per-pixel lighting, transparent rain
/// layers, texture resolution and render resolution.
enum QualityTier: String, CaseIterable, Identifiable {
    case high, low
    var id: String { rawValue }

    /// Baseline device for "high" is an A17 Pro class GPU (Apple GPU family 9:
    /// iPhone 15 Pro and newer).  Older devices start on "low".
    static var deviceDefault: QualityTier {
        guard let dev = MTLCreateSystemDefaultDevice() else { return .low }
        return dev.supportsFamily(.apple9) ? .high : .low
    }

    func lightCount(_ manifest: AssetManifest) -> Int {
        self == .high ? manifest.lights.count : manifest.lowTierLightCount
    }
    var textureScale: CGFloat { self == .high ? 1.0 : 0.5 }
    var keptRainLayers: Set<String> {
        self == .high ? ["rain_0", "rain_1", "rain_2", "rain_3", "rain_4", "rain_5"] : ["rain_0", "rain_2", "rain_4"]
    }
    var steam: Bool { self == .high }
    /// nil = native screen scale
    var contentScale: CGFloat? { self == .high ? nil : 2.0 }
}

enum AssetError: Error, LocalizedError {
    case missingBundle, missingTexture(String), badImage(String), missingMaterial(String), noMetal
    var errorDescription: String? {
        switch self {
        case .missingBundle: return "Portal assets are missing from the app bundle."
        case .missingTexture(let n): return "Missing texture \(n)."
        case .badImage(let n): return "Could not decode \(n)."
        case .missingMaterial(let n): return "Unknown material \(n)."
        case .noMetal: return "Metal is unavailable."
        }
    }
}

/// Loads bundled assets (manifest, meshes, textures) and creates RealityKit
/// materials.  Everything is local to the app bundle; nothing is streamed.
@MainActor
final class PortalAssets {
    let manifest: AssetManifest
    let baseURL: URL
    private(set) var tier: QualityTier
    private let library: MTLLibrary?
    private var textures: [String: TextureResource] = [:]
    private var materials: [String: RealityKit.Material] = [:]
    private(set) var meshes: [String: [MeshPart]] = [:]
    /// Materials whose custom shader failed to compile/load (fell back to unlit).
    private(set) var shaderFallbacks: [String] = []

    init(tier: QualityTier) throws {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "Portal") else {
            throw AssetError.missingBundle
        }
        baseURL = url.deletingLastPathComponent()
        manifest = try AssetManifest.load(from: url)
        self.tier = tier
        library = MTLCreateSystemDefaultDevice()?.makeDefaultLibrary()
    }

    var dims: PortalDimensions { manifest.dimensions }

    /// Parse mesh packs off the main thread.
    func loadMeshes() async throws {
        let base = baseURL
        let entries = manifest.meshes.map { ($0.key, $0.value.file) }
        let parsed: [(String, [MeshPart])] = try await Task.detached(priority: .userInitiated) {
            try entries.map { name, file in (name, try MeshPack.parse(Data(contentsOf: base.appendingPathComponent(file)))) }
        }.value
        for (k, v) in parsed { meshes[k] = v }
    }

    func parts(_ mesh: String, chunk: String? = nil) -> [MeshPart] {
        let all = meshes[mesh] ?? []
        guard let chunk else { return all }
        return all.filter { $0.chunk == chunk }
    }

    // MARK: textures

    func texture(_ name: String) throws -> TextureResource {
        if let t = textures[name] { return t }
        guard let info = manifest.textures[name] else { throw AssetError.missingTexture(name) }
        let url = baseURL.appendingPathComponent(info.file)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              var image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw AssetError.badImage(name) }
        if tier.textureScale < 1, image.width > 64, let scaled = Self.scale(image, by: tier.textureScale) {
            image = scaled
        }
        let semantic: TextureResource.Semantic = info.semantic == "color" ? .color : .raw
        let tex = try TextureResource.generate(from: image, options: .init(semantic: semantic))
        textures[name] = tex
        return tex
    }

    private static func scale(_ img: CGImage, by s: CGFloat) -> CGImage? {
        let w = max(4, Int(CGFloat(img.width) * s)), h = max(4, Int(CGFloat(img.height) * s))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: img.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Preload every texture referenced by a material (called before the portal
    /// can open, spread over run-loop turns to keep the camera view smooth).
    func preloadTextures() async throws {
        let needed = Set(manifest.materials.values.flatMap { ($0.textures ?? [:]).values })
        for name in needed.sorted() {
            _ = try texture(name)
            await Task.yield()
        }
    }

    // MARK: materials

    static func srgbColor(_ c: [Float]?) -> UIColor {
        let v = (c ?? [1, 1, 1]) + [1, 1, 1]
        func enc(_ x: Float) -> CGFloat {
            let l = max(0, min(1, x))
            return CGFloat(l <= 0.0031308 ? 12.92 * l : 1.055 * pow(l, 1 / 2.4) - 0.055)
        }
        return UIColor(red: enc(v[0]), green: enc(v[1]), blue: enc(v[2]), alpha: 1)
    }

    func material(_ name: String) throws -> RealityKit.Material {
        if let m = materials[name] { return m }
        let m = try makeMaterial(name, override: nil)
        materials[name] = m
        return m
    }

    /// A fresh (uncached) copy for entities whose parameters animate.
    func uniqueMaterial(_ name: String, params: SIMD4<Float>? = nil) throws -> RealityKit.Material {
        try makeMaterial(name, override: params)
    }

    private func makeMaterial(_ name: String, override: SIMD4<Float>?) throws -> RealityKit.Material {
        guard let def = manifest.materials[name] else { throw AssetError.missingMaterial(name) }
        let tex = def.textures ?? [:]
        switch def.shader {
        case "occlusion":
            return OcclusionMaterial()
        case "pbr":
            var m = PhysicallyBasedMaterial()
            if let b = tex["baseColor"] {
                m.baseColor = .init(tint: .white, texture: .init(try texture(b)))
            } else {
                m.baseColor = .init(tint: Self.srgbColor(def.color))
            }
            if let r = tex["roughness"] {
                m.roughness = .init(scale: 1.0, texture: .init(try texture(r)))
            } else {
                m.roughness = .init(floatLiteral: def.roughness ?? 0.5)
            }
            m.metallic = .init(floatLiteral: def.metallic ?? 0)
            return m
        default:
            let p = def.params ?? [0, 0, 0, 1]
            let value = override ?? SIMD4<Float>(p[0], p[1], p[2], p[3])
            do {
                guard let library else { throw AssetError.noMetal }
                let shader = CustomMaterial.SurfaceShader(named: def.shader, in: library)
                var m = try CustomMaterial(surfaceShader: shader, lightingModel: .unlit)
                if let b = tex["baseColor"] {
                    m.baseColor = CustomMaterial.BaseColor(tint: Self.srgbColor(def.tint), texture: CustomMaterial.Texture(try texture(b)))
                }
                m.custom = CustomMaterial.Custom(value: value, texture: try tex["custom"].map { CustomMaterial.Texture(try texture($0)) })
                // The unlit shader evaluates its own photographed normal map.
                // specular_scale is an otherwise unused flag in this pipeline.
                m.specular = CustomMaterial.Specular(floatLiteral: tex["normal"] == nil ? 0 : 1)
                if let normal = tex["normal"] {
                    m.normal = CustomMaterial.Normal(texture: CustomMaterial.Texture(try texture(normal)))
                }
                if let aux = tex["emissiveColor"] {
                    m.emissiveColor = CustomMaterial.EmissiveColor(color: .white, texture: CustomMaterial.Texture(try texture(aux)))
                }
                // metallic scale carries the per-pixel light budget (see AlleyShaders.metal)
                m.metallic = CustomMaterial.Metallic(floatLiteral: Float(tier.lightCount(manifest)) / 16)
                // roughness scale carries the destination clip code (0 = wall portal, no clip)
                m.roughness = CustomMaterial.Roughness(floatLiteral: 0)
                if def.isTransparent {
                    m.blending = .transparent(opacity: .init(floatLiteral: 1.0))
                }
                if def.shader == "alleyLitCutout" {
                    // alpha-tested, still depth-writing and sorted as opaque
                    m.blending = .transparent(opacity: .init(floatLiteral: 1.0))
                    m.opacityThreshold = 0.5
                }
                if def.cull == "none" {
                    m.faceCulling = .none
                }
                return m
            } catch {
                // Never ship a missing/black surface: fall back to the albedo
                // unlit, and report it in the developer panel.
                shaderFallbacks.append("\(name): \(error.localizedDescription)")
                var u = UnlitMaterial(color: Self.srgbColor(def.tint))
                if let b = tex["baseColor"] { u.color = .init(tint: Self.srgbColor(def.tint), texture: .init(try texture(b))) }
                if def.isTransparent { u.blending = .transparent(opacity: .init(floatLiteral: 0.4)) }
                return u
            }
        }
    }

    /// Writes the destination clip code (PortalCore DestinationMode.clipCode)
    /// into every custom material under `root` (the alley).
    func applyDestinationClip(_ code: Float, under root: Entity) {
        root.visit { e in
            guard let me = e as? ModelEntity, var model = me.model else { return }
            var changed = false
            model.materials = model.materials.map { mat in
                guard var c = mat as? CustomMaterial else { return mat }
                c.roughness = CustomMaterial.Roughness(floatLiteral: code)
                changed = true
                return c
            }
            if changed { me.model = model }
        }
    }

    /// Re-applies the per-pixel light budget to every custom material under `root`.
    func applyLightBudget(_ tier: QualityTier, under root: Entity) {
        self.tier = tier
        let scale = Float(tier.lightCount(manifest)) / 16
        root.visit { e in
            guard let me = e as? ModelEntity, var model = me.model else { return }
            model.materials = model.materials.map { mat in
                guard var c = mat as? CustomMaterial else { return mat }
                c.metallic = CustomMaterial.Metallic(floatLiteral: scale)
                return c
            }
            me.model = model
        }
    }

    // MARK: meshes -> entities

    /// One ModelEntity holding several parts (one material per part).
    /// Parts carrying baked lighting (uv1) are uploaded through LowLevelMesh on
    /// iOS 18+, the only RealityKit mesh path that exposes a second UV set to
    /// CustomMaterial shaders.  Without it (iOS 17) the shaders read uv1 = 0 and
    /// fall back to the unbaked approximation.
    func modelEntity(_ parts: [MeshPart], name: String, materialOverride: RealityKit.Material? = nil) throws -> ModelEntity {
        var mats: [RealityKit.Material] = []
        if materialOverride == nil {
            for p in parts { mats.append(try material(p.material)) }
        }
        let mesh: MeshResource
        if #available(iOS 18.0, *), parts.contains(where: { $0.uv1 != nil }) {
            mesh = try Self.bakedMesh(parts, perPartMaterials: materialOverride == nil)
            bakedMeshCount += 1
        } else {
            var descriptors: [MeshDescriptor] = []
            for (i, p) in parts.enumerated() {
                var d = MeshDescriptor(name: "\(name).\(p.material).\(i)")
                d.positions = MeshBuffers.Positions(p.positions)
                d.normals = MeshBuffers.Normals(p.normals)
                d.textureCoordinates = MeshBuffers.TextureCoordinates(p.uvs)
                d.primitives = .triangles(p.indices)
                d.materials = .allFaces(UInt32(materialOverride == nil ? i : 0))
                descriptors.append(d)
            }
            mesh = try MeshResource.generate(from: descriptors)
        }
        let e = ModelEntity(mesh: mesh, materials: materialOverride.map { [$0] } ?? mats)
        e.name = name
        return e
    }

    /// Number of entities built with baked lighting (developer diagnostics).
    private(set) var bakedMeshCount = 0

    private struct BakedVertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
        var uv0: SIMD2<Float>
        var uv1: SIMD2<Float>
    }

    @available(iOS 18.0, *)
    private static func bakedMesh(_ parts: [MeshPart], perPartMaterials: Bool) throws -> MeshResource {
        let vertexCount = parts.reduce(0) { $0 + $1.positions.count }
        let indexCount = parts.reduce(0) { $0 + $1.indices.count }
        var desc = LowLevelMesh.Descriptor()
        desc.vertexCapacity = vertexCount
        desc.indexCapacity = indexCount
        desc.indexType = .uint32
        desc.vertexAttributes = [
            .init(semantic: .position, format: .float3, offset: MemoryLayout<BakedVertex>.offset(of: \.position)!),
            .init(semantic: .normal, format: .float3, offset: MemoryLayout<BakedVertex>.offset(of: \.normal)!),
            .init(semantic: .uv0, format: .float2, offset: MemoryLayout<BakedVertex>.offset(of: \.uv0)!),
            .init(semantic: .uv1, format: .float2, offset: MemoryLayout<BakedVertex>.offset(of: \.uv1)!),
        ]
        desc.vertexLayouts = [.init(bufferIndex: 0, bufferStride: MemoryLayout<BakedVertex>.stride)]
        let mesh = try LowLevelMesh(descriptor: desc)
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let v = raw.bindMemory(to: BakedVertex.self)
            var o = 0
            for p in parts {
                for i in 0..<p.positions.count {
                    v[o + i] = BakedVertex(position: p.positions[i], normal: p.normals[i], uv0: p.uvs[i],
                                           uv1: p.uv1?[i] ?? .zero)
                }
                o += p.positions.count
            }
        }
        var lowParts: [LowLevelMesh.Part] = []
        mesh.withUnsafeMutableIndices { raw in
            let ix = raw.bindMemory(to: UInt32.self)
            var vo: UInt32 = 0
            var io = 0
            for (k, p) in parts.enumerated() {
                for (j, idx) in p.indices.enumerated() { ix[io + j] = idx + vo }
                var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
                var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
                for q in p.positions { lo = simd_min(lo, q); hi = simd_max(hi, q) }
                lowParts.append(LowLevelMesh.Part(indexOffset: io * MemoryLayout<UInt32>.size, indexCount: p.indices.count,
                                                  topology: .triangle, materialIndex: perPartMaterials ? k : 0,
                                                  bounds: BoundingBox(min: lo, max: hi)))
                io += p.indices.count
                vo += UInt32(p.positions.count)
            }
        }
        mesh.parts.replaceAll(lowParts)
        return try MeshResource(from: mesh)
    }
}

extension Entity {
    func visit(_ body: (Entity) -> Void) {
        body(self)
        for c in children { c.visit(body) }
    }
}

