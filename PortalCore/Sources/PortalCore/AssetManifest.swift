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
        /// Loaded on demand (destination meshes), not at launch.
        public var lazy: Bool?
    }
    /// v1.4: what can be shown behind the portal.
    public struct Destination: Decodable, Sendable {
        public var kind: DestinationKind
        public var title: String
        public var mesh: String?
        public var meshLow: String?
        public var floorAperture: [Float]?
        public var ceilingAperture: [Float]?
        public var credit: String?
        public var licence: String?
        public var source: String?
        public var location: String?
        /// video: bundled H.264 file and screen placement
        public var file: String?
        public var screenDepth: Float?
        public var aspect: Float?

        public func scene(id: String) -> DestinationScene {
            func v(_ a: [Float]?, _ d: SIMD3<Float>) -> SIMD3<Float> { a.map { SIMD3($0[0], $0[1], $0[2]) } ?? d }
            return DestinationScene(id: id, kind: kind,
                                    floorAperture: v(floorAperture, DestinationScene.illustrated.floorAperture),
                                    ceilingAperture: v(ceilingAperture, DestinationScene.illustrated.ceilingAperture))
        }
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
    public var destinations: [String: Destination]?
    public var defaultDestination: String?

    public static func load(from url: URL) throws -> AssetManifest {
        try JSONDecoder().decode(AssetManifest.self, from: Data(contentsOf: url))
    }
}
