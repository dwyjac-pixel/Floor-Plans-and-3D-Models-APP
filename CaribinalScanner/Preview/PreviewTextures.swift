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

    /// The picture of the room that lights it, with the strength to show
    /// it at so every room gets the same amount of fill light.
    struct Environment {
        let image: CGImage
        let intensity: Double
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

    /// A colour given as light, not as screen values, for lamps and other
    /// places where the numbers are amounts of light.
    static func light(_ r: Double, _ g: Double, _ b: Double) -> CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [encoded(r), encoded(g), encoded(b), 1])!
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
    /// Light to screen value (the sRGB curve).
    private static func encoded(_ v: Double) -> Double {
        let c = clamp(v)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    // MARK: Images

    /// An 8 bit picture from a value per pixel.
    ///
    /// Every picture is tagged sRGB, data maps included. SceneKit converts
    /// an image tagged as linear before it samples it, which tilts every
    /// normal and raises every roughness. An sRGB tag passes the bytes of a
    /// normal or roughness map through untouched.
    private static func image(_ width: Int, _ height: Int, _ pixel: (Int, Int) -> RGB) -> CGImage {
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
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    /// A normal map from heights. `heightAt` and both pixel sizes are in
    /// the same unit, so the slopes are the real ones. A lower height reads
    /// as a recess: checked on walls and floor with a raking light.
    private static func normalMap(_ width: Int, _ height: Int, pixelWidth: Double, pixelHeight: Double,
                                  _ heightAt: (Int, Int) -> Double) -> CGImage {
        image(width, height) { x, y in
            let dx = (heightAt((x + 1) % width, y) - heightAt((x + width - 1) % width, y)) / (2 * pixelWidth)
            let dy = (heightAt(x, (y + 1) % height) - heightAt(x, (y + height - 1) % height)) / (2 * pixelHeight)
            let nx = -dx, ny = dy
            let length = (nx * nx + ny * ny + 1).squareRoot()
            return (nx / length * 0.5 + 0.5, ny / length * 0.5 + 0.5, 1 / length * 0.5 + 0.5)
        }
    }

    // MARK: Tile

    static func tile(_ tile: PreviewFinish.Tile, seed: UInt64, size: Int = 1024) -> Maps {
        let widthMM = tile.repeatWidth * 1000, heightMM = tile.repeatHeight * 1000
        let scale = Double(size) / max(widthMM, heightMM)
        let w = max(64, Int((widthMM * scale).rounded())), h = max(64, Int((heightMM * scale).rounded()))
        let mmPerPixelX = widthMM / Double(w), mmPerPixelY = heightMM / Double(h)
        let pixel = max(mmPerPixelX, mmPerPixelY)
        let tileColour = rgb(tile.tileHex), groutColour = rgb(tile.groutHex)
        let veined = tile.mottle > 0.5

        // Per pixel: millimetres in from the tile's edge (negative inside
        // the joint), with the tile's column and row for shade variation.
        func sample(_ px: Int, _ py: Int) -> (edge: Double, column: Int, row: Int, x: Double, y: Double) {
            let x = (Double(px) + 0.5) * mmPerPixelX, y = (Double(py) + 0.5) * mmPerPixelY
            let row = Int(floor(y / tile.pitchY))
            let shifted = x - tile.rowShift * Double(row) * tile.pitchX
            let column = Int(floor(shifted / tile.pitchX))
            let lx = shifted - Double(column) * tile.pitchX, ly = y - Double(row) * tile.pitchY
            let edge = min(min(lx, tile.pitchX - lx), min(ly, tile.pitchY - ly)) - tile.grout / 2
            let wrapped = ((column % tile.columns) + tile.columns) % tile.columns
            return (edge, wrapped, row, x, y)
        }
        // Height in millimetres: the grout lies 0.5 mm under the face and
        // the tile's edge is eased over the next 2.5 mm, as a pressed tile is.
        var faces = [Double](repeating: 0, count: w * h), heights = [Double](repeating: 0, count: w * h)
        let albedo = image(w, h) { px, py in
            let s = sample(px, py)
            // The joint is drawn at its true width, softened by one pixel.
            let face = smoothstep(-0.6 * pixel, 0.6 * pixel, s.edge)
            faces[py * w + px] = face
            heights[py * w + px] = 0.5 * face + 0.3 * smoothstep(0, 2.5, s.edge)
            let shade = 1 + tile.variation * (hash(s.column, s.row, seed) * 2 - 1)
            let cloud = noise(s.x / widthMM * 7, s.y / heightMM * 7, 7, 7, seed &+ 11) * 2 - 1
            let fine = hash(px, py, seed &+ 23) * 2 - 1
            var body = 1 + tile.mottle * 0.07 * cloud + 0.008 * fine
            if veined {
                let warp = noise(s.x / widthMM * 5, s.y / heightMM * 5, 5, 5, seed &+ 31)
                let band = abs(noise(s.x / widthMM * 3 + warp, s.y / heightMM * 3, 3, 3, seed &+ 37 &+ UInt64(s.column * 7 + s.row)) - 0.5)
                body -= 0.16 * (1 - smoothstep(0, 0.03, band))
            }
            let tone = shade * body
            let joint = 1 + 0.03 * fine
            return mix((groutColour.r * joint, groutColour.g * joint, groutColour.b * joint),
                       (tileColour.r * tone, tileColour.g * tone, tileColour.b * tone), face)
        }
        let roughness = image(w, h) { px, py in
            let value = mix(0.9, tile.roughness, faces[py * w + px])
            return (value, value, value)
        }
        let normal = normalMap(w, h, pixelWidth: mmPerPixelX, pixelHeight: mmPerPixelY) { px, py in heights[py * w + px] }
        return Maps(albedo: albedo, roughness: roughness, normal: normal, width: tile.repeatWidth, height: tile.repeatHeight)
    }

    // MARK: Plank floors

    /// Boards one texture repeat long, laid in rows with each row started
    /// at its own point so the end joints do not line up. Every board has
    /// its own shade and its own run of grain.
    static func plank(_ plank: PreviewFinish.Plank, seed: UInt64, size: Int = 1024) -> Maps {
        let widthMM = plank.repeatWidth * 1000, heightMM = plank.repeatHeight * 1000
        let scale = Double(size) / max(widthMM, heightMM)
        let w = max(64, Int((widthMM * scale).rounded())), h = max(64, Int((heightMM * scale).rounded()))
        let mmX = widthMM / Double(w), mmY = heightMM / Double(h)
        let pixel = max(mmX, mmY)
        let base = rgb(plank.hex), grain = rgb(plank.grainHex)
        var heights = [Double](repeating: 0, count: w * h)
        let albedo = image(w, h) { px, py in
            let x = (Double(px) + 0.5) * mmX, y = (Double(py) + 0.5) * mmY
            let row = min(plank.rows - 1, Int(y / plank.width))
            // Each row starts somewhere along the board, the same every repeat.
            let start = hash(row, 17, seed) * plank.length
            var along = (x - start).truncatingRemainder(dividingBy: plank.length)
            if along < 0 { along += plank.length }
            let across = y - Double(row) * plank.width
            let edge = min(min(across, plank.width - across), min(along, plank.length - along))
            // A fine dark line at every joint, about a pixel wide.
            let joint = 1 - smoothstep(0, 1.2 * pixel, edge)
            heights[py * w + px] = 0.4 * smoothstep(0, 2.0, edge)
            let board = seed &+ UInt64(row * 131 + 7)
            let u = along / plank.length, v = across / plank.width
            let drift = noise(u * 3, v * 2 + Double(row) * 5.3, 3, 64, board) - 0.5
            let ring = v * 3.2 + drift * 2.6 + hash(row, 3, seed) * 4
            let phase = ring - floor(ring)
            let late = smoothstep(0.3, 0.9, phase) * (1 - smoothstep(0.9, 1, phase))
            let fibre = noise(u * 24, v * 46 + Double(row) * 9.1, 24, 512, board &+ 5) - 0.5
            let shade = 1 + plank.variation * (hash(row, 29, seed) * 2 - 1)
            let amount = clamp(0.12 + 0.3 * late + 0.34 * fibre)
            let tone = mix(base, grain, amount)
            let dark = 1 - 0.45 * joint
            return (tone.r * shade * dark, tone.g * shade * dark, tone.b * shade * dark)
        }
        let normal = normalMap(w, h, pixelWidth: mmX, pixelHeight: mmY) { px, py in heights[py * w + px] }
        return Maps(albedo: albedo, roughness: nil, normal: normal, width: plank.repeatWidth, height: plank.repeatHeight)
    }

    // MARK: Carpet and concrete

    /// A surface with no pattern: soft clouding and fine grain over one
    /// colour. With `pile` the grain also has depth, as carpet does.
    static func mottled(hex: String, cloud: Double, grain: Double, pile: Bool, seed: UInt64, size: Int = 1024) -> Maps {
        // Carpet needs its tufts resolved, so its repeat is small. A hard
        // floor has only soft clouding, which would show as a grid of
        // blotches unless the repeat is wider than most rooms are deep.
        let side = pile ? 0.8 : 2.6
        let n = max(64, size / 2)
        let base = rgb(hex)
        var heights = [Double](repeating: 0, count: n * n)
        let albedo = image(n, n) { px, py in
            let x = Double(px) / Double(n), y = Double(py) / Double(n)
            let soft = noise(x * 5, y * 5, 5, 5, seed) * 2 - 1
            let fine = hash(px, py, seed &+ 3) * 2 - 1
            let tuft = noise(x * 96, y * 96, 96, 96, seed &+ 9) * 2 - 1
            heights[py * n + px] = pile ? 1.2 * (tuft * 0.6 + fine * 0.4) : 0
            let tone = 1 + cloud * soft + grain * (pile ? tuft * 0.7 + fine * 0.3 : fine)
            return (base.r * tone, base.g * tone, base.b * tone)
        }
        let millimetres = side * 1000 / Double(n)
        let normal = pile ? normalMap(n, n, pixelWidth: millimetres, pixelHeight: millimetres) { px, py in heights[py * n + px] } : nil
        return Maps(albedo: albedo, roughness: nil, normal: normal, width: side, height: side)
    }

    // MARK: Wood

    static func wood(_ wood: PreviewFinish.Wood, seed: UInt64, size: Int = 1024) -> Maps {
        let base = rgb(wood.hex), grain = rgb(wood.grainHex)
        let albedo = image(size, size) { px, py in
            let along = Double(wood.vertical ? py : px) / Double(size)
            let across = Double(wood.vertical ? px : py) / Double(size)
            // Growth rings cut on the flat: lines that run with the board
            // and drift, closing into a soft arch here and there. Each
            // ring darkens toward its late wood and ends in a fine line.
            let drift = noise(along * 2, across * 3, 2, 3, seed) - 0.5
            let wander = noise(along * 5, across * 9, 5, 9, seed &+ 3) - 0.5
            let ring = across * 11 + drift * 3.4 + wander * 0.7
            let phase = ring - floor(ring)
            let late = smoothstep(0.25, 0.9, phase) * (1 - smoothstep(0.9, 1, phase))
            // Pores and fibre: fine streaks along the grain.
            let fibre = noise(along * 9, across * 640, 9, 640, seed &+ 5) - 0.5
            let streak = noise(along * 4, across * 110, 4, 110, seed &+ 7) - 0.5
            let broad = noise(along * 2, across * 5, 2, 5, seed &+ 9) - 0.5
            let amount = 0.18 + 0.34 * late + 0.26 * fibre + 0.30 * streak + 0.22 * broad
            return mix(base, grain, clamp(amount))
        }
        return Maps(albedo: albedo, roughness: nil, normal: nil, width: 1.0, height: 1.0)
    }

    // MARK: Stone

    static func stone(hex: String, veinHex: String, veining: Double, seed: UInt64, size: Int = 1024) -> Maps {
        let base = rgb(hex), vein = rgb(veinHex)
        let albedo = image(size, size) { px, py in
            let x = Double(px) / Double(size), y = Double(py) / Double(size)
            // Engineered quartz: an even fine speckle, a faint cloud, and
            // veins that swell, thin out and fade along their length.
            let cloud = noise(x * 6, y * 6, 6, 6, seed) * 2 - 1
            let fine = hash(px, py, seed &+ 3) * 2 - 1
            let fleck = noise(x * 190, y * 190, 190, 190, seed &+ 5) * 2 - 1
            let warp = noise(x * 4, y * 4, 4, 4, seed &+ 7) * 1.3
            let band = abs(noise(x * 3 + warp, y * 3 + warp * 0.6, 3, 3, seed &+ 13) - 0.5)
            let swell = noise(x * 5, y * 5, 5, 5, seed &+ 17)
            let main = (1 - smoothstep(0, 0.012 + 0.05 * swell * swell, band)) * smoothstep(0.25, 0.6, swell)
            let hair = abs(noise(x * 7 - warp, y * 7 + warp, 7, 7, seed &+ 19) - 0.5)
            let thin = (1 - smoothstep(0, 0.012, hair)) * 0.35
            let body = 1 + 0.016 * cloud + 0.01 * fine + 0.012 * fleck
            return mix((base.r * body, base.g * body, base.b * body), vein, clamp(max(main, thin) * veining))
        }
        return Maps(albedo: albedo, roughness: nil, normal: nil, width: 1.2, height: 1.2)
    }

    // MARK: Lighting environment

    /// A soft picture of the empty room, drawn once from the plan and
    /// wrapped around the scene.
    ///
    /// It gives every surface its fill light, and it is what the mirror,
    /// chrome, glass and glazed china reflect: the room's own ceiling,
    /// walls and floor in plain neutral tones, its ceiling lights, its
    /// windows and its open doorway, each in the direction it really lies.
    /// It shows no fixtures and no finishes, so it is the same picture for
    /// every look and a finish change never redraws it.
    ///
    /// The picture is stored at a fraction of its brightness and shown
    /// stronger, which leaves the ceiling lights several times brighter
    /// than the walls, as a polished surface needs.
    static func environment(for layout: PreviewLayout, lamps: [PreviewLayout.Point]) -> Environment {
        let w = 512, h = 256
        let xs = layout.floor.map(\.x), zs = layout.floor.map(\.z)
        let top = max(layout.ceilingHeight, 1)
        var middle = PreviewLayout.Point(x: ((xs.min() ?? 0) + (xs.max() ?? 1)) / 2, z: ((zs.min() ?? 0) + (zs.max() ?? 1)) / 2)
        if !layout.contains(middle), let lamp = lamps.first { middle = lamp }
        let eye = (x: middle.x, y: min(1.25, top * 0.6), z: middle.z)
        let open = PreviewCamera.entry(in: layout)?.void.id

        // Amounts of light, before the stored scale. Close to neutral, so
        // a grey paint reads grey: the walls a touch cool, the floor's
        // bounce a touch warm, the lamps warm and the daylight cool.
        let ceiling: RGB = (0.56, 0.565, 0.57), wall: RGB = (0.50, 0.505, 0.515), floor: RGB = (0.30, 0.295, 0.285)
        let lamp: RGB = (2.5, 2.38, 2.2), daylight: RGB = (1.9, 2.05, 2.2), beyond: RGB = (0.03, 0.03, 0.035)
        let stored = 1 / 2.5
        /// The average light the picture gives a surface, whatever the room.
        let fill = 0.47

        var total = 0.0, weight = 0.0
        let picture = image(w, h) { px, py in
            let heading = (Double(px) + 0.5) / Double(w) * 2 * .pi
            let elevation = .pi / 2 - (Double(py) + 0.5) / Double(h) * .pi
            let dx = cos(elevation) * cos(heading), dy = sin(elevation), dz = cos(elevation) * sin(heading)

            // Nearest surface along the ray: ceiling, floor or a wall face.
            var distance = dy > 1e-6 ? (top - eye.y) / dy : (dy < -1e-6 ? -eye.y / dy : Double.infinity)
            var c = dy > 0 ? ceiling : floor
            // Distance in from the nearest edge of that surface, in metres.
            var edge = Double.infinity
            var onWall = false
            for face in layout.walls {
                let facing = dx * face.inward.x + dz * face.inward.z
                guard facing < -1e-6 else { continue }
                let t = ((face.start.x - eye.x) * face.inward.x + (face.start.z - eye.z) * face.inward.z) / facing
                guard t > 0, t < distance else { continue }
                let along = (eye.x + dx * t - face.start.x) * face.direction.x + (eye.z + dz * t - face.start.z) * face.direction.z
                guard along >= -0.01, along <= face.length + 0.01 else { continue }
                let up = eye.y + dy * t
                distance = t
                onWall = true
                // Brightest below the ceiling lights, easing toward the floor.
                c = mix(wall, (wall.r * 0.8, wall.g * 0.8, wall.b * 0.8), smoothstep(0.55, 1, 1 - up / top))
                edge = min(min(along, face.length - along), min(up, top - up))
                for void in face.voids where along > void.from && along < void.to && up > void.sill && up < void.head {
                    let inset = min(min(along - void.from, void.to - along), min(up - void.sill, void.head - up))
                    let through: RGB
                    switch void.kind {
                    case .window: through = daylight
                    case .opening: through = beyond
                    default: through = void.id == open ? beyond : wall
                    }
                    c = mix(c, through, smoothstep(0, 0.04, inset))
                    edge = .infinity
                }
            }
            if !onWall, distance.isFinite {
                edge = layout.clearance(from: PreviewLayout.Point(x: eye.x + dx * distance, z: eye.z + dz * distance))
            }
            // Corners and edges gather a little less light.
            if edge.isFinite {
                let shade = 1 - 0.16 * (1 - smoothstep(0, 0.4, edge))
                c = (c.r * shade, c.g * shade, c.b * shade)
            }
            // Ceiling lights: a bright lens with a soft glow around it.
            if dy > 0 {
                for point in lamps {
                    let lx = point.x - eye.x, ly = top - eye.y, lz = point.z - eye.z
                    let reach = (lx * lx + ly * ly + lz * lz).squareRoot()
                    let angle = acos(clamp((dx * lx + dy * ly + dz * lz) / reach))
                    let lens = 0.07 / reach
                    let glow = 1 - smoothstep(lens * 0.7, lens * 1.3, angle)
                    let halo = 0.12 * exp(-(angle * angle) / (lens * lens * 14))
                    c = mix(c, lamp, clamp(glow + halo))
                }
            }
            let luminance = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
            total += luminance * cos(elevation)
            weight += cos(elevation)
            return (encoded(c.r * stored), encoded(c.g * stored), encoded(c.b * stored))
        }
        // Every room gets the same average fill, however much of it is
        // window or doorway.
        let average = weight > 0 ? total / weight : 0.5
        return Environment(image: picture, intensity: fill / max(average, 0.05) / stored)
    }
}
