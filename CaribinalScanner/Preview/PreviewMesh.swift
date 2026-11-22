import SceneKit
import simd

/// Triangles with normals and texture coordinates measured in metres.
///
/// Texture coordinates are distances, not 0 to 1 fractions, so a finish
/// sets its own repeat size on the material and tile or plank stays at
/// true scale on any surface without touching the geometry.
struct PreviewMesh {
    typealias V3 = SIMD3<Float>
    typealias V2 = SIMD2<Float>

    private var positions: [V3] = []
    private var normals: [V3] = []
    private var uvs: [V2] = []
    private var indices: [UInt32] = []

    var isEmpty: Bool { indices.isEmpty }
    var triangleCount: Int { indices.count / 3 }
    var bounds: (min: V3, max: V3)? {
        guard var low = positions.first else { return nil }
        var high = low
        for p in positions {
            low = simd_min(low, p)
            high = simd_max(high, p)
        }
        return (low, high)
    }

    @discardableResult
    mutating func vertex(_ p: V3, _ n: V3, _ uv: V2) -> UInt32 {
        positions.append(p)
        normals.append(n)
        uvs.append(uv)
        return UInt32(positions.count - 1)
    }

    /// Adds a triangle wound to face the way `facing` points. With `vertex`,
    /// this is the escape hatch for shapes the helpers below do not cover.
    mutating func triangle(_ a: UInt32, _ b: UInt32, _ c: UInt32, facing: V3) {
        let geometric = simd_cross(positions[Int(b)] - positions[Int(a)], positions[Int(c)] - positions[Int(a)])
        indices += simd_dot(geometric, facing) >= 0 ? [a, b, c] : [a, c, b]
    }

    /// A parallelogram from `origin` along `u` then `v`. It faces the side
    /// that `cross(u, v)` points to. Texture runs along `u`.
    mutating func rect(origin: V3, u: V3, v: V3, uvOrigin: V2 = .zero) {
        let normal = simd_normalize(simd_cross(u, v))
        let lu = simd_length(u), lv = simd_length(v)
        let a = vertex(origin, normal, uvOrigin)
        let b = vertex(origin + u, normal, uvOrigin + V2(lu, 0))
        let c = vertex(origin + u + v, normal, uvOrigin + V2(lu, lv))
        let d = vertex(origin + v, normal, uvOrigin + V2(0, lv))
        indices += [a, b, c, a, c, d]
    }

    /// Same rectangle, turned if needed so it faces `facing`.
    mutating func rect(origin: V3, u: V3, v: V3, facing: V3, uvOrigin: V2 = .zero) {
        if simd_dot(simd_cross(u, v), facing) >= 0 {
            rect(origin: origin, u: u, v: v, uvOrigin: uvOrigin)
        } else {
            rect(origin: origin + u, u: -u, v: v, uvOrigin: uvOrigin)
        }
    }

    /// A box spanned by three edges from one corner, faces outward.
    mutating func box(origin: V3, u: V3, v: V3, w: V3, uvOrigin: V2 = .zero) {
        let centre = origin + (u + v + w) / 2
        for (a, b, c) in [(u, v, w), (w, v, u), (u, w, v)] {
            rect(origin: origin, u: a, v: b, facing: origin + (a + b) / 2 - centre, uvOrigin: uvOrigin)
            rect(origin: origin + c, u: a, v: b, facing: origin + c + (a + b) / 2 - centre, uvOrigin: uvOrigin)
        }
    }

    /// An axis-aligned box between two corners.
    mutating func box(from low: V3, to high: V3, uvOrigin: V2 = .zero) {
        let size = high - low
        box(origin: low, u: V3(size.x, 0, 0), v: V3(0, size.y, 0), w: V3(0, 0, size.z), uvOrigin: uvOrigin)
    }

    /// A flat polygon given as points and index triples.
    mutating func polygon(_ points: [V3], triangles: [Int], normal: V3, uv: (V3) -> V2) {
        let base = points.map { vertex($0, normal, uv($0)) }
        for i in stride(from: 0, to: triangles.count - 2, by: 3) {
            triangle(base[triangles[i]], base[triangles[i + 1]], base[triangles[i + 2]], facing: normal)
        }
    }

    /// An upright solid with a convex outline in x and z and a softened
    /// top edge. Corners sharper than about 40 degrees stay crisp.
    mutating func prism(outline: [V2], from y0: Float, to y1: Float, bevel: Float) {
        let count = outline.count
        guard count >= 3 else { return }
        var area: Float = 0
        for i in 0..<count {
            let a = outline[i], b = outline[(i + 1) % count]
            area += a.x * b.y - b.x * a.y
        }
        let sign: Float = area > 0 ? 1 : -1
        func edgeNormal(_ i: Int) -> V2 {
            let d = outline[(i + 1) % count] - outline[i]
            return simd_normalize(V2(d.y, -d.x)) * sign
        }
        func smooth(_ i: Int) -> V2 { simd_normalize(edgeNormal((i + count - 1) % count) + edgeNormal(i)) }
        func sideNormal(vertex i: Int, edge e: Int) -> V2 {
            simd_dot(edgeNormal((i + count - 1) % count), edgeNormal(i)) > 0.77 ? smooth(i) : edgeNormal(e)
        }
        let shoulder = y1 - bevel
        var inset: [V3] = []
        for i in 0..<count {
            let p = outline[i] - smooth(i) * bevel
            inset.append(V3(p.x, y1, p.y))
        }
        for i in 0..<count {
            let j = (i + 1) % count
            let ni = sideNormal(vertex: i, edge: i), nj = sideNormal(vertex: j, edge: i)
            let out = V3(edgeNormal(i).x, 0, edgeNormal(i).y)
            let a = vertex(V3(outline[i].x, y0, outline[i].y), V3(ni.x, 0, ni.y), .zero)
            let b = vertex(V3(outline[j].x, y0, outline[j].y), V3(nj.x, 0, nj.y), .zero)
            let c = vertex(V3(outline[j].x, shoulder, outline[j].y), V3(nj.x, 0, nj.y), .zero)
            let d = vertex(V3(outline[i].x, shoulder, outline[i].y), V3(ni.x, 0, ni.y), .zero)
            triangle(a, b, c, facing: out)
            triangle(a, c, d, facing: out)
            // Bevel: normals swing from sideways to up across the strip.
            let e = vertex(inset[j], V3(0, 1, 0), .zero)
            let f = vertex(inset[i], V3(0, 1, 0), .zero)
            let lean = simd_normalize(out + V3(0, 1, 0))
            triangle(d, c, e, facing: lean)
            triangle(d, e, f, facing: lean)
        }
        let centre = inset.reduce(V3.zero, +) / Float(count)
        let hub = vertex(centre, V3(0, 1, 0), .zero)
        let rim = inset.map { vertex($0, V3(0, 1, 0), .zero) }
        for i in 0..<count { triangle(hub, rim[i], rim[(i + 1) % count], facing: V3(0, 1, 0)) }
    }

    func geometry() -> SCNGeometry {
        func source(_ semantic: SCNGeometrySource.Semantic, _ data: Data, components: Int, stride: Int) -> SCNGeometrySource {
            SCNGeometrySource(data: data, semantic: semantic, vectorCount: positions.count, usesFloatComponents: true,
                              componentsPerVector: components, bytesPerComponent: 4, dataOffset: 0, dataStride: stride)
        }
        let vertexData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let normalData = normals.withUnsafeBufferPointer { Data(buffer: $0) }
        let uvData = uvs.withUnsafeBufferPointer { Data(buffer: $0) }
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(data: indexData, primitiveType: .triangles,
                                         primitiveCount: indices.count / 3, bytesPerIndex: 4)
        return SCNGeometry(sources: [
            source(.vertex, vertexData, components: 3, stride: MemoryLayout<V3>.stride),
            source(.normal, normalData, components: 3, stride: MemoryLayout<V3>.stride),
            source(.texcoord, uvData, components: 2, stride: MemoryLayout<V2>.stride),
        ], elements: [element])
    }
}
