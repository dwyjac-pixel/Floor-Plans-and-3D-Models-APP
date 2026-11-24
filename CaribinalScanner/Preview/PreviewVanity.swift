import SceneKit
import simd

/// A floor-standing vanity built to the drawn footprint. The counter is the
/// footprint: its edges sit at plus and minus half the drawn width and
/// depth, and the cabinet stands just inside them the way a stock vanity
/// does. Flat fronts with fine reveals over a recessed toe kick, an eased
/// counter with a backsplash, an undermount basin, a single lever tap and
/// a framed mirror. Its back is at -z and its doors face +z.
extension PreviewRoomScene {
    func buildVanity(_ solid: PreviewLayout.Solid, in node: SCNNode) {
        typealias V2 = PreviewMesh.V2
        let hw = Float(solid.width) / 2, hd = Float(solid.depth) / 2
        let forward = V3(0, 0, 1)
        let outward = [V3(0, -1, 0), V3(1, 0, 0), V3(0, 1, 0), V3(-1, 0, 0)]
        // Stock sizes: 870 high on a 100 toe kick, with a 30 slab that
        // oversails the doors by 25 and the cabinet sides by 6.
        let top: Float = 0.87, slab: Float = 0.03, under = top - slab, kick: Float = 0.10
        let cw = hw - min(0.006, hw * 0.05)
        let face = hd - min(0.025, hd * 0.2)
        let doorBack = face - 0.019, carcass = doorBack - 0.002
        let kickFace = max(-hd + 0.02, face - 0.075)
        let gap: Float = 0.003
        var cabinet = PreviewMesh(), stone = PreviewMesh(), china = PreviewMesh()
        var dark = PreviewMesh(), metal = PreviewMesh(), glass = PreviewMesh()

        // MARK: Cabinet

        // Sides run to the floor and are notched at the front for the toe kick.
        for sign: Float in [-1, 1] {
            let x = sign * cw
            cabinet.flat([V3(x, kick, kickFace), V3(x, kick, carcass), V3(x, under, carcass), V3(x, under, -hd),
                          V3(x, 0, -hd), V3(x, 0, kickFace)], normal: V3(sign, 0, 0)) { V2($0.z + hd, $0.y) }
            // The slit between the side and the back of the doors.
            let slit = sign * (cw - 0.0008)
            dark.flat([V3(slit, kick, carcass), V3(slit, kick, doorBack), V3(slit, under, doorBack), V3(slit, under, carcass)],
                      normal: V3(sign, 0, 0))
        }
        cabinet.flat([V3(-cw, 0, kickFace), V3(cw, 0, kickFace), V3(cw, kick, kickFace), V3(-cw, kick, kickFace)],
                     normal: forward) { V2($0.x + hw, $0.y) }
        cabinet.flat([V3(-cw, 0, -hd), V3(cw, 0, -hd), V3(cw, under, -hd), V3(-cw, under, -hd)],
                     normal: -forward) { V2($0.x + hw, $0.y) }
        dark.flat([V3(-cw, kick, kickFace), V3(cw, kick, kickFace), V3(cw, kick, carcass), V3(-cw, kick, carcass)], normal: -up)
        // Dark behind the fronts, so every reveal reads as a fine line.
        dark.flat([V3(-cw + 0.0004, kick, carcass + 0.0004), V3(cw - 0.0004, kick, carcass + 0.0004),
                   V3(cw - 0.0004, under, carcass + 0.0004), V3(-cw + 0.0004, under, carcass + 0.0004)], normal: forward)

        // Fronts: a slab with a slightly eased edge. Grain carries across
        // neighbouring fronts, as it does when they are cut from one sheet.
        let bevel: Float = 0.0025, sink: Float = 0.001
        func front(_ x0: Float, _ x1: Float, _ y0: Float, _ y1: Float) {
            let inner = [V3(x0 + bevel, y0 + bevel, face), V3(x1 - bevel, y0 + bevel, face),
                         V3(x1 - bevel, y1 - bevel, face), V3(x0 + bevel, y1 - bevel, face)]
            let outer = [V3(x0, y0, face - sink), V3(x1, y0, face - sink), V3(x1, y1, face - sink), V3(x0, y1, face - sink)]
            cabinet.flat(inner, normal: forward) { V2($0.x + hw, $0.y) }
            for i in 0..<4 {
                let j = (i + 1) % 4
                // The bottom edge shades with the face: the floor bounce would pick it out.
                let lean = i == 0 ? forward : simd_normalize(forward * bevel + outward[i] * sink)
                cabinet.flat([inner[i], inner[j], outer[j], outer[i]], normal: lean) { V2($0.x + hw, $0.y) }
                let upright = i % 2 == 1
                cabinet.flat([outer[i], outer[j], V3(outer[j].x, outer[j].y, doorBack), V3(outer[i].x, outer[i].y, doorBack)],
                             normal: outward[i]) { upright ? V2($0.y, $0.z) : V2($0.x + hw, $0.z) }
            }
        }
        // Bar pulls on two posts.
        func pull(_ centre: V3, along axis: V3, fits room: Float) {
            let length = min(0.16, room - 0.08)
            guard length > 0.05 else { return }
            let proud = forward * 0.028
            metal.bar(from: centre - axis * (length / 2) + proud, to: centre + axis * (length / 2) + proud, radius: 0.006)
            for sign: Float in [-1, 1] {
                let foot = centre + axis * (sign * (length / 2 - 0.016))
                metal.bar(from: foot, to: foot + proud, radius: 0.005, sides: 8, capped: false)
            }
        }

        let left = -cw + 0.0015, right = cw - 0.0015
        let rowTop = under - gap, rowBottom = rowTop - 0.155, lowerTop = rowBottom - gap
        dark.flat([V3(left, kick, face - sink - 0.0002), V3(right, kick, face - sink - 0.0002),
                   V3(right, rowTop, face - sink - 0.0002), V3(left, rowTop, face - sink - 0.0002)], normal: forward)
        // A drawer front over a pair of doors; wide vanities gain a bank of
        // drawers either side.
        var columns: [(x0: Float, x1: Float, drawers: Bool)] = [(left, right, false)]
        if right - left >= 1.0 {
            let bank = min(0.42, max(0.28, (right - left) * 0.25))
            columns = [(left, left + bank, true), (left + bank + gap, right - bank - gap, false), (right - bank, right, true)]
        }
        for column in columns {
            let width = column.x1 - column.x0, middle = (column.x0 + column.x1) / 2
            front(column.x0, column.x1, rowBottom, rowTop)
            pull(V3(middle, (rowBottom + rowTop) / 2, face), along: V3(1, 0, 0), fits: width)
            if column.drawers {
                let split = (kick + lowerTop) / 2
                for (y0, y1) in [(kick, split - gap / 2), (split + gap / 2, lowerTop)] {
                    front(column.x0, column.x1, y0, y1)
                    pull(V3(middle, (y0 + y1) / 2, face), along: V3(1, 0, 0), fits: width)
                }
            } else {
                let doors = width < 0.5 ? 1 : 2
                let doorWidth = (width - gap * Float(doors - 1)) / Float(doors)
                for index in 0..<doors {
                    let x0 = column.x0 + Float(index) * (doorWidth + gap)
                    front(x0, x0 + doorWidth, kick, lowerTop)
                    // Pulls by the meeting edge, or the free edge of a single door.
                    let x = doors == 2 && index == 1 ? x0 + 0.045 : x0 + doorWidth - 0.045
                    pull(V3(x, lowerTop - 0.14, face), along: up, fits: lowerTop - kick)
                }
            }
        }

        // MARK: Counter

        let ease: Float = 0.003
        let deck: (V3) -> V2 = { V2($0.x + hw, $0.z + hd) }
        let basinWidth = min(0.48, 2 * hw - 0.20), basinDepth = min(0.35, 2 * hd - 0.20)
        let hasBasin = basinWidth >= 0.22 && basinDepth >= 0.16
        let a = basinWidth / 2, b = basinDepth / 2, round = min(0.085, min(a, b) * 0.6)
        // The basin sits forward of centre, leaving a deck for the tap.
        let zc = hd - 0.08 - max(0, 2 * hd - 0.55) / 3 - b
        let arcSteps = 8
        /// A rounded rectangle about the basin centre: points and outward
        /// directions, corner by corner from the front right.
        func ring(grow: Float) -> [(p: V3, out: V3)] {
            var points: [(p: V3, out: V3)] = []
            for quarter in 0..<4 {
                let cx = (quarter == 0 || quarter == 3 ? 1 : -1) * (a - round), cz = (quarter < 2 ? 1 : -1) * (b - round)
                for step in 0...arcSteps {
                    let angle = (Float(quarter) + Float(step) / Float(arcSteps)) * .pi / 2
                    let out = V3(cos(angle), 0, sin(angle))
                    points.append((V3(cx, 0, zc + cz) + out * (round + grow), out))
                }
            }
            return points
        }
        let deckCorners = [V3(hw - ease, top, hd - ease), V3(-hw + ease, top, hd - ease), V3(-hw + ease, top, -hd), V3(hw - ease, top, -hd)]
        if hasBasin {
            // The top, fanned from each corner of the slab to the cut out.
            let lip = ring(grow: 0.002), wall = ring(grow: 0)
            let joint: Float = 0.0015
            let lipIndex = lip.map { stone.vertex($0.p + up * top, up, deck($0.p)) }
            let cornerIndex = deckCorners.map { stone.vertex($0, up, deck($0)) }
            for side in 0..<4 {
                let first = side * (arcSteps + 1) + arcSteps / 2
                let near = cornerIndex[side], far = cornerIndex[(side + 1) % 4]
                for edge in 0...arcSteps {
                    stone.triangle(edge <= arcSteps / 2 ? near : far, lipIndex[(first + edge) % lip.count],
                                   lipIndex[(first + edge + 1) % lip.count], facing: up)
                }
                stone.triangle(near, lipIndex[(first + arcSteps / 2 + 1) % lip.count], far, facing: up)
            }
            // The polished edge of the cut out, eased at the top.
            var along: [Float] = [0]
            for i in 1...wall.count { along.append(along[i - 1] + simd_distance(wall[i % wall.count].p, wall[i - 1].p)) }
            let order = Array(0..<wall.count) + [0]
            stone.band(order.map { lip[$0].p + up * top }, order.map { _ in up },
                       order.map { wall[$0].p + up * (top - 0.002) }, order.map { -wall[$0].out }) { i, low in
                V2(along[i], low ? 0.003 : 0)
            }
            stone.band(order.map { wall[$0].p + up * (top - 0.002) }, order.map { -wall[$0].out },
                       order.map { wall[$0].p + up * (under + joint) }, order.map { -wall[$0].out }) { i, low in
                V2(along[i], low ? slab : 0.003)
            }
            // The shadow line where the stone meets the bowl.
            dark.band(order.map { wall[$0].p + up * (under + joint) }, order.map { -wall[$0].out },
                      order.map { wall[$0].p + up * under }, order.map { -wall[$0].out })

            // Undermount basin: a rounded bowl that falls steeply from the
            // rim and flattens toward the drain. The stone oversails it.
            let bowlDepth: Float = 0.13, drain: Float = 0.021, rings = 14, power: Float = 2.0 / 3.0
            var dense: [(w: Float, d: Float, phi: Float)] = []
            for i in 0...240 {
                let phi = Float(i) / 240 * .pi / 2
                dense.append((1 - pow(max(0, cos(phi)), power), pow(max(0, sin(phi)), power), phi))
            }
            let run = min(a, b) - drain
            var travelled: [Float] = [0]
            for i in 1..<dense.count {
                travelled.append(travelled[i - 1] + simd_length(V2((dense[i].w - dense[i - 1].w) * run, (dense[i].d - dense[i - 1].d) * bowlDepth)))
            }
            var profile: [(w: Float, d: Float, phi: Float)] = []
            var cursor = 0
            for k in 0...rings {
                let target = travelled[travelled.count - 1] * Float(k) / Float(rings)
                while cursor < dense.count - 1, travelled[cursor] < target { cursor += 1 }
                profile.append(dense[cursor])
            }
            let rim = ring(grow: 0.003)
            let centre = V3(0, 0, zc)
            let spokes = rim.map { simd_normalize($0.p - centre) * drain + centre }
            let grid: [[V3]] = profile.map { sample in
                rim.indices.map { rim[$0].p + (spokes[$0] - rim[$0].p) * sample.w + up * (under - bowlDepth * sample.d) }
            }
            var bowl: [[UInt32]] = [], bowlNormals: [[V3]] = []
            for k in 0...rings {
                var row: [UInt32] = [], rowNormals: [V3] = []
                // The slope of the profile at this ring, exact at the rim and the drain.
                let inwardRun = pow(max(0, sin(profile[k].phi)), 2 - power), fall = pow(max(0, cos(profile[k].phi)), 2 - power)
                for i in 0..<rim.count {
                    let around = grid[k][(i + 1) % rim.count] - grid[k][(i + rim.count - 1) % rim.count]
                    let down = (spokes[i] - rim[i].p) * inwardRun - up * (bowlDepth * fall)
                    var normal = simd_normalize(simd_cross(around, down))
                    let inward = centre - V3(grid[k][i].x, 0, grid[k][i].z) + up * 0.05
                    if simd_dot(normal, inward) < 0 { normal = -normal }
                    row.append(china.vertex(grid[k][i], normal, .zero))
                    rowNormals.append(normal)
                }
                bowl.append(row)
                bowlNormals.append(rowNormals)
            }
            for k in 0..<rings {
                for i in 0..<rim.count {
                    let j = (i + 1) % rim.count
                    let facing = bowlNormals[k][i] + bowlNormals[k + 1][j]
                    china.triangle(bowl[k][i], bowl[k][j], bowl[k + 1][j], facing: facing)
                    china.triangle(bowl[k][i], bowl[k + 1][j], bowl[k + 1][i], facing: facing)
                }
            }
            // Drain: a flange with a raised stopper.
            let floor = under - bowlDepth
            metal.tube([V3(0, floor - 0.002, zc), V3(0, floor + 0.0025, zc)], radii: [0.031, 0.030], sides: 24, capped: (false, true))
            dark.tube([V3(0, floor + 0.0025, zc), V3(0, floor + 0.003, zc)], radii: [0.0215, 0.0215], sides: 20, capped: (false, true))
            metal.tube([V3(0, floor + 0.003, zc), V3(0, floor + 0.0065, zc)], radii: [0.019, 0.017], sides: 20, capped: (false, true))

            // Single lever tap on the deck behind the basin.
            let tapZ = max(-hd + 0.05, zc - b - 0.052)
            func tap(_ y: Float, _ z: Float) -> V3 { V3(0, top + y, tapZ + z) }
            metal.tube([tap(0, 0), tap(0.006, 0)], radii: [0.026, 0.025], sides: 20, capped: (false, true))
            metal.tube([tap(0.006, 0), tap(0.125, 0)], radii: [0.0195, 0.0185], sides: 20, capped: (false, true))
            dark.tube([tap(0.125, 0), tap(0.128, 0)], radii: [0.0165, 0.0165], sides: 16, capped: (false, false))
            metal.tube([tap(0.128, 0), tap(0.155, 0)], radii: [0.0185, 0.0185], sides: 20, capped: (true, true))
            var spout: [V3] = [], spoutRadii: [Float] = []
            let sweep: Float = 0.097, rise: Float = 38 * .pi / 180
            for i in 0...10 {
                let t = Float(i) / 10, angle = rise - t * 78 * .pi / 180
                spout.append(tap(0.098 + sweep * (cos(angle) - cos(rise)), 0.008 + sweep * (sin(rise) - sin(angle))))
                spoutRadii.append(0.0115 - 0.0015 * t)
            }
            metal.tube(spout, radii: spoutRadii, sides: 14, capped: (false, true))
            metal.tube([tap(0.146, 0.008), tap(0.178, 0.088)], radii: [0.0065, 0.0045], sides: 10, capped: (false, true))
        } else {
            stone.flat(deckCorners, normal: up, uv: deck)
        }
        // Eased arris along the front and both ends, then the square edges.
        stone.patch([deckCorners[1], deckCorners[0], V3(hw, top - ease, hd), V3(-hw, top - ease, hd)],
                    normals: [up, up, forward, forward], uv: deck)
        stone.flat([V3(-hw, under, hd), V3(hw, under, hd), V3(hw, top - ease, hd), V3(-hw, top - ease, hd)],
                   normal: forward) { V2($0.x + hw, 2 * hd + top - $0.y) }
        for sign: Float in [-1, 1] {
            let x = sign * hw, out = V3(sign, 0, 0)
            stone.patch([V3(x - sign * ease, top, -hd), V3(x - sign * ease, top, hd - ease), V3(x, top - ease, hd), V3(x, top - ease, -hd)],
                        normals: [up, up, out, out], uv: deck)
            stone.flat([V3(x, under, -hd), V3(x, under, hd), V3(x, top - ease, hd), V3(x, top - ease, -hd)], normal: out) {
                V2($0.z + hd, $0.y)
            }
            stone.flat([V3(sign * cw, under, -hd), V3(x, under, -hd), V3(x, under, hd), V3(sign * cw, under, hd)], normal: -up, uv: deck)
        }
        stone.flat([V3(-hw, under, -hd), V3(hw, under, -hd), V3(hw, top, -hd), V3(-hw, top, -hd)], normal: -forward) { V2($0.x + hw, $0.y) }
        stone.flat([V3(-cw, under, carcass), V3(cw, under, carcass), V3(cw, under, hd), V3(-cw, under, hd)], normal: -up, uv: deck)

        // Backsplash: a 100 upstand of the same slab with an eased top edge.
        let splashTop = top + 0.10, splashFace = -hd + 0.02
        stone.flat([V3(-hw, top, splashFace), V3(hw, top, splashFace), V3(hw, splashTop - ease, splashFace), V3(-hw, splashTop - ease, splashFace)],
                   normal: forward) { V2($0.x + hw, $0.y - top) }
        stone.patch([V3(-hw, splashTop - ease, splashFace), V3(hw, splashTop - ease, splashFace),
                     V3(hw, splashTop, splashFace - ease), V3(-hw, splashTop, splashFace - ease)],
                    normals: [forward, forward, up, up]) { V2($0.x + hw, $0.y - top) }
        stone.flat([V3(-hw, splashTop, -hd), V3(hw, splashTop, -hd), V3(hw, splashTop, splashFace - ease), V3(-hw, splashTop, splashFace - ease)],
                   normal: up, uv: deck)
        stone.flat([V3(-hw, top, -hd), V3(hw, top, -hd), V3(hw, splashTop, -hd), V3(-hw, splashTop, -hd)], normal: -forward) { V2($0.x + hw, $0.y) }
        for sign: Float in [-1, 1] {
            let x = sign * hw
            stone.flat([V3(x, top, -hd), V3(x, top, splashFace), V3(x, splashTop - ease, splashFace), V3(x, splashTop, splashFace - ease),
                        V3(x, splashTop, -hd)], normal: V3(sign, 0, 0)) { V2($0.z + hd, $0.y - top) }
        }

        // MARK: Mirror

        // Decor on the wall behind, when the vanity backs onto one. It hangs
        // clear of the backsplash and stops short of the ceiling or of any
        // bulkhead over it.
        if walled(solid, 0, 1) {
            let width = min(2 * hw - 0.12, 1.2)
            var ceiling = Float(layout.ceilingHeight)
            for step in 0...8 {
                let across = Double(width) * (Double(step) / 8 - 0.5)
                let point = solid.centre + solid.xAxis * across - solid.zAxis * (solid.depth / 2 - 0.02)
                ceiling = min(ceiling, Float(layout.clearHeight(above: point)))
            }
            let low = splashTop + 0.10, high = min(1.95, ceiling - 0.07)
            if high - low > 0.35, width > 0.25 {
                if vanityMount == nil {
                    vanityMount = PreviewVanityMount(node: node, width: width, depth: hd,
                                                    bottom: low, top: high, clearance: ceiling)
                }
                let x0 = -width / 2, x1 = width / 2, back = -hd, proud = -hd + 0.016, rim: Float = 0.016
                let outer = [V3(x0, low, proud), V3(x1, low, proud), V3(x1, high, proud), V3(x0, high, proud)]
                let inner = [V3(x0 + rim, low + rim, proud), V3(x1 - rim, low + rim, proud),
                             V3(x1 - rim, high - rim, proud), V3(x0 + rim, high - rim, proud)]
                for i in 0..<4 {
                    let j = (i + 1) % 4
                    metal.flat([outer[i], outer[j], inner[j], inner[i]], normal: forward)
                    metal.flat([outer[i], outer[j], V3(outer[j].x, outer[j].y, back), V3(outer[i].x, outer[i].y, back)],
                               normal: outward[i])
                }
                // A fine dark line sets the glass off from its frame.
                dark.flat(inner.map { $0 - forward * 0.002 }, normal: forward)
                // The glass leans a few degrees toward the ceiling at its head and
                // the floor at its foot, so it picks up a soft gradient of the room
                // the way a mirror does and never reads as a flat grey card.
                let line: Float = 0.002, rows = 6
                let heights = (0...rows).map { low + rim + line + (high - low - 2 * rim - 2 * line) * Float($0) / Float(rows) }
                let lean = (0...rows).map { simd_normalize(forward + up * (Float($0) / Float(rows) - 0.5) * 0.6) }
                glass.band(heights.map { V3(x0 + rim + line, $0, proud - 0.001) }, lean,
                           heights.map { V3(x1 - rim - line, $0, proud - 0.001) }, lean)
            }
        }

        emit(cabinet, .vanityCabinet, in: node)
        emit(stone, .vanityTop, in: node)
        emit(china, .whiteware, in: node)
        emit(dark, .shadowGap, in: node)
        emit(metal, .hardware, in: node)
        emit(glass, .mirror, in: node)
    }
}

/// Shapes the vanity needs beyond flat boxes: eased edges, smooth bands
/// and round bars, all in one mesh per finish so a vanity is six draws.
private extension PreviewMesh {
    /// A flat convex face, fanned from its first corner.
    mutating func flat(_ corners: [V3], normal: V3, uv: (V3) -> V2 = { _ in .zero }) {
        patch(corners, normals: corners.map { _ in normal }, uv: uv)
    }

    /// A face with a normal at each corner, for eased edges that shade round.
    mutating func patch(_ corners: [V3], normals: [V3], uv: (V3) -> V2 = { _ in .zero }) {
        guard corners.count >= 3, normals.count == corners.count else { return }
        let index = corners.indices.map { vertex(corners[$0], normals[$0], uv(corners[$0])) }
        let facing = normals.reduce(V3.zero, +)
        for i in 1..<(corners.count - 1) { triangle(index[0], index[i], index[i + 1], facing: facing) }
    }

    /// A smooth band between two rows of points. `uv` is asked for each
    /// point by its place in the row and whether it is on the second row.
    mutating func band(_ a: [V3], _ na: [V3], _ b: [V3], _ nb: [V3], uv: (Int, Bool) -> V2 = { _, _ in .zero }) {
        guard a.count >= 2, b.count == a.count, na.count == a.count, nb.count == a.count else { return }
        let ia = a.indices.map { vertex(a[$0], na[$0], uv($0, false)) }
        let ib = b.indices.map { vertex(b[$0], nb[$0], uv($0, true)) }
        for i in 0..<(a.count - 1) {
            let facing = na[i] + nb[i] + na[i + 1] + nb[i + 1]
            triangle(ia[i], ia[i + 1], ib[i + 1], facing: facing)
            triangle(ia[i], ib[i + 1], ib[i], facing: facing)
        }
    }

}

extension PreviewMesh {
    /// A round bar along a path, its radius given at each point.
    mutating func tube(_ path: [V3], radii: [Float], sides: Int = 12, capped: (start: Bool, end: Bool) = (true, true)) {
        guard path.count >= 2, radii.count == path.count, sides >= 3 else { return }
        var frames: [(along: V3, side: V3, other: V3)] = []
        var rows: [[UInt32]] = []
        func spoke(_ frame: (along: V3, side: V3, other: V3), _ turn: Float) -> V3 {
            let angle = 2 * Float.pi * turn / Float(sides)
            return frame.side * cos(angle) + frame.other * sin(angle)
        }
        for k in path.indices {
            let along = simd_normalize(path[min(k + 1, path.count - 1)] - path[max(k - 1, 0)])
            var side: V3
            if let last = frames.last {
                side = simd_normalize(last.side - along * simd_dot(last.side, along))
            } else {
                side = simd_normalize(simd_cross(along, abs(along.x) < 0.9 ? V3(1, 0, 0) : V3(0, 1, 0)))
            }
            let frame = (along: along, side: side, other: simd_cross(along, side))
            frames.append(frame)
            rows.append((0..<sides).map { j in
                let out = spoke(frame, Float(j))
                return vertex(path[k] + out * radii[k], out, .zero)
            })
        }
        for k in 0..<(path.count - 1) {
            for j in 0..<sides {
                let l = (j + 1) % sides, out = spoke(frames[k], Float(j) + 0.5)
                triangle(rows[k][j], rows[k][l], rows[k + 1][l], facing: out)
                triangle(rows[k][j], rows[k + 1][l], rows[k + 1][j], facing: out)
            }
        }
        for (wanted, k, sign) in [(capped.start, 0, Float(-1)), (capped.end, path.count - 1, Float(1))] where wanted {
            let normal = frames[k].along * sign
            let hub = vertex(path[k], normal, .zero)
            let edge = (0..<sides).map { vertex(path[k] + spoke(frames[k], Float($0)) * radii[k], normal, .zero) }
            for j in 0..<sides { triangle(hub, edge[j], edge[(j + 1) % sides], facing: normal) }
        }
    }

    /// A straight round bar.
    fileprivate mutating func bar(from a: V3, to b: V3, radius: Float, sides: Int = 12, capped: Bool = true) {
        tube([a, b], radii: [radius, radius], sides: sides, capped: (capped, capped))
    }
}
