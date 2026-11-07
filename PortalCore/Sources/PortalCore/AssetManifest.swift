import Foundation

/// Decoded App/Resources/Portal/manifest.json (written by Tools/assetgen/build.py).
public struct AssetManifest: Decodable, Sendable {
    public struct Texture: Decodable, Sendable {
        public var file: String
        public var semantic: String        // "color" (sRGB) | "raw" (linear)
        public var size: [Int]
    }
    public struct Material: Decodable, Sendable {
        public var shader: String
        public var textures: [String: String]?
        public var tint: [Float]?
        public var params: [Float]?
        public var color: [Float]?
        public var roughness: Float?
        public var metallic: Float?
        public var blend: String?
        public var cull: String?

        public var isTransparent: Bool { blend == "transparent" }
    }
    public struct Mesh: Decodable, Sendable {
        public var file: String
        public var vertices: Int
        public var triangles: Int
    }
    public struct Light: Decodable, Sendable {
        public var name: String
        public var position: [Float]
        public var color: [Float]
        public var intensity: Float
        public var radius: Float
        public var flicker: Int
    }

    public var version: Int
    public var dimensions: PortalDimensions
    public var textures: [String: Texture]
    public var materials: [String: Material]
    public var meshes: [String: Mesh]
    public var lights: [Light]
    public var lowTierLightCount: Int
    public var audio: [String: Double]

    public static func load(from url: URL) throws -> AssetManifest {
        try JSONDecoder().decode(AssetManifest.self, from: Data(contentsOf: url))
    }
}
