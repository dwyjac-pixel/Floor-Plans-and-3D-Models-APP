import CoreGraphics
import Foundation

/// Finish textures drawn in code, so the app ships no image files for
/// them and every pattern is at a known real-world size.
enum PreviewTextures {
    struct Maps {
        let albedo: CGImage
        let roughness: CGImage?
        let normal: CGImage?
        /// Size of one repeat in metres.
        let width: Double
        let height: Double
    }

    typealias RGB = (r: Double, g: Double, b: Double)

    static func rgb(_ hex: String) -> RGB {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x808080
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    static func color(_ hex: String, alpha: Double = 1) -> CGColor {
        let c = rgb(hex)
        return CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [c.r, c.g, c.b, alpha])!
    }

    // MARK: Noise

    private static func hash(_ x: Int, _ y: Int, _ seed: UInt64) -> Double {
        var h = UInt64(bitPattern: Int64(x)) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(bitPattern: Int64(y)) &* 0xC2B2_AE3D_27D4_EB4F ^ seed
        h ^= h >> 31
        h = h &* 0xBF58_476D_1CE4_E5B9
        h ^= h >> 29
        h = h &* 0x94D0_49BB_1331_11EB
        h ^= h >> 32
        return Double(h & 0xFF_FFFF) / Double(0xFF_FFFF)
    }

    /// Smooth noise in 0 to 1 that wraps every `px` by `py` cells.
    private static func noise(_ x: Double, _ y: Double, _ px: Int, _ py: Int, _ seed: UInt64) -> Double {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = x - Double(x0), fy = y - Double(y0)
        func wrap(_ v: Int, _ p: Int) -> Int { ((v % p) + p) % p }
        func corner(_ dx: Int, _ dy: Int) -> Double { hash(wrap(x0 + dx, px), wrap(y0 + dy, py), seed) }
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let top = corner(0, 0) + (corner(1, 0) - corner(0, 0)) * sx
        let bottom = corner(0, 1) + (corner(1, 1) - corner(0, 1)) * sx
        return top + (bottom - top) * sy
    }

    private static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    private static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB { (mix(a.r, b.r, t), mix(a.g, b.g, t), mix(a.b, b.b, t)) }
    private static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = clamp((x - a) / (b - a))
        return t * t * (3 - 2 * t)
    }

    // MARK: Images

    private static func image(_ width: Int, _ height: Int, linear: Bool, _ pixel: (Int, Int) -> RGB) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = pixel(x, y)
                let i = (y * width + x) * 4
                bytes[i] = UInt8(clamp(c.r) * 255 + 0.5)
                bytes[i + 1] = UInt8(clamp(c.g) * 255 + 0.5)
                bytes[i + 2] = UInt8(clamp(c.b) * 255 + 0.5)
            }
        }
        let space = CGColorSpace(name: linear ? CGColorSpace.linearSRGB : CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    private static func normalMap(_ width: Int, _ height: Int, strength: Double, _ heightAt: (Int, Int) -> Double) -> CGImage {
        image(width, height, linear: true) { x, y in
            let dx = heightAt((x + 1) % width, y) - heightAt((x + width - 1) % width, y)
            let dy = heightAt(x, (y + 1) % height) - heightAt(x, (y + height - 1) % height)
            let nx = -dx * strength, ny = dy * strength
            let length = (nx * nx + ny * ny + 1).squareRoot()
            return (nx / length * 0.5 + 0.5, ny / length * 0.5 + 0.5, 1 / length * 0.5 + 0.5)
        }
    }

    // MARK: Tile

    static func tile(_ tile: PreviewFinish.Tile, seed: UInt64) -> Maps {
        let widthMM = tile.repeatWidth * 1000, heightMM = tile.repeatHeight * 1000
        let scale = 1024 / max(widthMM, heightMM)
        let w = max(64, Int((widthMM * scale).rounded())), h = max(64, Int((heightMM * scale).rounded()))
        let mmPerPixelX = widthMM / Double(w), mmPerPixelY = heightMM / Double(h)
        let tileColour = rgb(tile.tileHex), groutColour = rgb(tile.groutHex)
        let veined = tile.mottle > 0.5

        // Per pixel: 0 in the joint, 1 on the tile face, with the tile's
        // column and row for shade variation.
        func sample(_ px: Int, _ py: Int) -> (face: Double, column: Int, row: Int, x: Double, y: Double) {
            let x = (Double(px) + 0.5) * mmPerPixelX, y = (Double(py) + 0.5) * mmPerPixelY
            let row = Int(floor(y / tile.pitchY))
            let shifted = x - tile.rowShift * Double(row) * tile.pitchX
            let column = Int(floor(shifted / tile.pitchX))
            let lx = shifted - Double(column) * tile.pitchX, ly = y - Double(row) * tile.pitchY
            let edge = min(min(lx, tile.pitchX - lx), min(ly, tile.pitchY - ly)) - tile.grout / 2
            let wrapped = ((column % tile.columns) + tile.columns) % tile.columns
            return (smoothstep(-0.5 * mmPerPixelX, max(1.0, 1.5 * mmPerPixelX), edge), wrapped, row, x, y)
        }
        var faces = [Double](repeating: 0, count: w * h)
        let albedo = image(w, h, linear: false) { px, py in
            let s = sample(px, py)
            faces[py * w + px] = s.face
            let shade = 1 + tile.variation * (hash(s.column, s.row, seed) * 2 - 1)
            let cloud = noise(s.x / widthMM * 7, s.y / heightMM * 7, 7, 7, seed &+ 11) * 2 - 1
            let fine = hash(px, py, seed &+ 23) * 2 - 1
            var body = 1 + tile.mottle * 0.07 * cloud + 0.008 * fine
            if veined {
                let warp = noise(s.x / widthMM * 5, s.y / heightMM * 5, 5, 5, seed &+ 31)
                let band = abs(noise(s.x / widthMM * 3 + warp, s.y / heightMM * 3, 3, 3, seed &+ 37 &+ UInt64(s.column * 7 + s.row)) - 0.5)
                body -= 0.16 * (1 - smoothstep(0, 0.03, band))
            }
            let face: RGB = (tileColour.r * shade * body, tileColour.g * shade * body, tileColour.b * shade * body)
            let joint = 1 + 0.03 * fine
            return mix((groutColour.r * joint, groutColour.g * joint, groutColour.b * joint), face, s.face)
        }
        let roughness = image(w, h, linear: true) { px, py in
            let value = mix(0.92, tile.roughness, faces[py * w + px])
            return (value, value, value)
        }
        let normal = normalMap(w, h, strength: 1.6) { px, py in faces[py * w + px] }
        return Maps(albedo: albedo, roughness: roughness, normal: normal, width: tile.repeatWidth, height: tile.repeatHeight)
    }

    // MARK: Wood

    static func wood(_ wood: PreviewFinish.Wood, seed: UInt64) -> Maps {
        let size = 1024
        let base = rgb(wood.hex), grain = rgb(wood.grainHex)
        let albedo = image(size, size, linear: false) { px, py in
            let along = Double(wood.vertical ? py : px) / Double(size)
            let across = Double(wood.vertical ? px : py) / Double(size)
            // Long soft bands of figure with fine fibre over them. The
            // bands wander so no two boards read as ruled lines.
            let warp = noise(along * 2, across * 6, 2, 6, seed) * 3.2
            let ring = 0.5 + 0.5 * sin((across * 17 + warp) * 2 * .pi)
            let fibre = noise(along * 10, across * 520, 10, 520, seed &+ 5)
            let streak = noise(along * 4, across * 90, 4, 90, seed &+ 7)
            let broad = noise(along * 2, across * 4, 2, 4, seed &+ 9)
            let amount = 0.16 * ring + 0.16 * fibre + 0.22 * streak + 0.2 * broad - 0.12
            return mix(base, grain, clamp(amount))
        }
        return Maps(albedo: albedo, roughness: nil, normal: nil, width: 1.0, height: 1.0)
    }

    // MARK: Stone

    static func stone(hex: String, veinHex: String, veining: Double, seed: UInt64) -> Maps {
        let size = 1024
        let base = rgb(hex), vein = rgb(veinHex)
        let albedo = image(size, size, linear: false) { px, py in
            let x = Double(px) / Double(size), y = Double(py) / Double(size)
            let cloud = noise(x * 6, y * 6, 6, 6, seed) * 2 - 1
            let fine = hash(px, py, seed &+ 3) * 2 - 1
            let warp = noise(x * 4, y * 4, 4, 4, seed &+ 7) * 1.3
            let band = abs(noise(x * 3 + warp, y * 3 + warp * 0.6, 3, 3, seed &+ 13) - 0.5)
            let line = (1 - smoothstep(0, 0.035, band)) * veining
            let body = 1 + 0.018 * cloud + 0.012 * fine
            return mix((base.r * body, base.g * body, base.b * body), vein, clamp(line * 0.8))
        }
        return Maps(albedo: albedo, roughness: nil, normal: nil, width: 1.2, height: 1.2)
    }

    // MARK: Lighting environment

    /// A soft picture of a lit room, wrapped around the scene, that gives
    /// surfaces their fill light and gives chrome, glass and glazed china
    /// something to reflect. One environment serves every look so two
    /// looks are always compared under the same light.
    static func environment() -> CGImage {
        let w = 512, h = 256
        // Close to neutral, so a grey paint reads grey and a white reads
        // white. The warmth in the picture comes from the ceiling lights.
        let ceiling: RGB = (0.82, 0.81, 0.79), wall: RGB = (0.72, 0.71, 0.69), floor: RGB = (0.56, 0.55, 0.53)
        let lamp: RGB = (1.0, 0.97, 0.92), window: RGB = (0.94, 0.97, 1.0)
        func glow(_ azimuth: Double, _ elevation: Double, at a0: Double, _ e0: Double, radius: Double) -> Double {
            var da = abs(azimuth - a0)
            if da > 180 { da = 360 - da }
            let d2 = (da * da + (elevation - e0) * (elevation - e0)) / (radius * radius)
            return exp(-d2)
        }
        return image(w, h, linear: false) { px, py in
            let azimuth = (Double(px) + 0.5) / Double(w) * 360
            let elevation = 90 - (Double(py) + 0.5) / Double(h) * 180
            var c = mix(floor, wall, smoothstep(-32, -12, elevation))
            c = mix(c, ceiling, smoothstep(18, 38, elevation))
            let lamps = glow(azimuth, elevation, at: 70, 62, radius: 16) + glow(azimuth, elevation, at: 250, 62, radius: 16)
            c = mix(c, lamp, clamp(lamps))
            c = mix(c, window, 0.85 * glow(azimuth, elevation, at: 160, 18, radius: 11))
            return c
        }
    }
}
