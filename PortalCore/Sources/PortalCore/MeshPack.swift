import Foundation

/// Parser for the .pmsh mesh packs written by Tools/assetgen/meshkit.py.
///
///     char[4] 'PMSH', u32 version, u32 partCount
///     per part: u16 len + utf8 chunk name, u16 len + utf8 material,
///               u32 vertexCount, u32 indexCount,
///               f32[3n] positions, f32[3n] normals, f32[2n] uvs, u32[m] indices
public struct MeshPart: Sendable {
    public var chunk: String
    public var material: String
    public var positions: [SIMD3<Float>]
    public var normals: [SIMD3<Float>]
    public var uvs: [SIMD2<Float>]
    public var indices: [UInt32]

    public var triangleCount: Int { indices.count / 3 }
}

public enum MeshPackError: Error, Equatable {
    case badMagic, unsupportedVersion(UInt32), truncated, indexOutOfRange(String)
}

public enum MeshPack {
    public static func parse(_ data: Data) throws -> [MeshPart] {
        var r = Reader(data: data)
        guard try r.bytes(4) == Array("PMSH".utf8) else { throw MeshPackError.badMagic }
        let version: UInt32 = try r.scalar()
        guard version == 1 else { throw MeshPackError.unsupportedVersion(version) }
        let count: UInt32 = try r.scalar()
        var parts: [MeshPart] = []
        parts.reserveCapacity(Int(count))
        for _ in 0..<count {
            let chunk = try r.string()
            let mat = try r.string()
            let vc = Int(try r.scalar() as UInt32)
            let ic = Int(try r.scalar() as UInt32)
            let p: [Float] = try r.array(vc * 3)
            let n: [Float] = try r.array(vc * 3)
            let t: [Float] = try r.array(vc * 2)
            let idx: [UInt32] = try r.array(ic)
            if let m = idx.max(), Int(m) >= vc { throw MeshPackError.indexOutOfRange("\(chunk)/\(mat)") }
            var pos = [SIMD3<Float>](); pos.reserveCapacity(vc)
            var nrm = [SIMD3<Float>](); nrm.reserveCapacity(vc)
            var uv = [SIMD2<Float>](); uv.reserveCapacity(vc)
            for i in 0..<vc {
                pos.append(SIMD3(p[3 * i], p[3 * i + 1], p[3 * i + 2]))
                nrm.append(SIMD3(n[3 * i], n[3 * i + 1], n[3 * i + 2]))
                uv.append(SIMD2(t[2 * i], t[2 * i + 1]))
            }
            parts.append(MeshPart(chunk: chunk, material: mat, positions: pos, normals: nrm, uvs: uv, indices: idx))
        }
        return parts
    }

    struct Reader {
        let data: Data
        var offset = 0

        mutating func bytes(_ n: Int) throws -> [UInt8] {
            guard offset + n <= data.count else { throw MeshPackError.truncated }
            let out = [UInt8](data[data.startIndex + offset ..< data.startIndex + offset + n])
            offset += n
            return out
        }

        mutating func scalar<T: FixedWidthInteger>() throws -> T {
            let b = try bytes(MemoryLayout<T>.size)
            var v: T = 0
            for (i, byte) in b.enumerated() { v |= T(byte) << (8 * i) }
            return v
        }

        mutating func string() throws -> String {
            let n = Int(try scalar() as UInt16)
            return String(decoding: try bytes(n), as: UTF8.self)
        }

        /// Copies little-endian 4-byte elements without assuming alignment.
        mutating func array<T>(_ n: Int) throws -> [T] {
            guard n > 0 else { return [] }
            let size = n * MemoryLayout<T>.stride
            guard offset + size <= data.count else { throw MeshPackError.truncated }
            let start = offset
            let source = data
            let out = [T](unsafeUninitializedCapacity: n) { buf, initialized in
                source.withUnsafeBytes { raw in
                    memcpy(UnsafeMutableRawPointer(buf.baseAddress!), raw.baseAddress!.advanced(by: start), size)
                }
                initialized = n
            }
            offset += size
            return out
        }
    }
}
