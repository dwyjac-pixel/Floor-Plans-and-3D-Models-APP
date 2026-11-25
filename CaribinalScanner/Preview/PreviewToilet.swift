import SceneKit
import simd

/// A skirted two-piece toilet built to the drawn footprint. The tank is
/// at -z against the wall and the bowl faces +z.
///
/// The tank lid spans the drawn width, its back is on the wall line and
/// the seat reaches the drawn front, so the model fills the footprint and
/// never leaves it. Heights are not on the plan; they are the usual ones
/// for a two-piece toilet (seat about 0.43 m, tank about 0.79 m).
extension PreviewRoomScene {
    func buildToilet(_ solid: PreviewLayout.Solid, in node: SCNNode) {
        let toilet = ToiletModel(width: Float(solid.width), depth: Float(solid.depth))
        emit(toilet.china, .whiteware, in: node)
        emit(toilet.dark, .shadowGap, in: node)
        emit(toilet.metal, .hardware, in: node)
    }
}

/// The three meshes of a toilet: china, the dark joint lines and the
/// metal trim. Everything is local to the fixture: x across, z from the
/// wall (-depth / 2) to the front, y up from the floor.
private struct ToiletModel {
    typealias V3 = SIMD3<Float>

    var china = PreviewMesh()
    var dark = PreviewMesh()
    var metal = PreviewMesh()

    init(width: Float, depth: Float) {
        let hw = width / 2, hd = depth / 2

        // Heights, floor up.
        let rimTop: Float = 0.400
        let seatLow = rimTop + 0.005, seatHigh = seatLow + 0.016
        let lidLow = seatHigh + 0.0035, lidHigh = lidLow + 0.018
        let tankLow = rimTop + 0.003, tankHigh: Float = 0.738
        let coverLow = tankHigh + 0.003, coverHigh = coverLow + 0.030

        // Tank: the cover spans the drawn width and backs onto the wall.
        let coverHalf = min(hw, 0.29)
        let tankDepth = min(max(depth * 0.27, 0.15), 0.21, depth * 0.45)
        let overhang: Float = 0.007
        let tankFront = -hd + tankDepth
        let tankTopHalf = coverHalf - overhang

        // Seat and bowl: the seat nose is the drawn front.
        let seatHalf = min(max(width * 0.37, 0.16), 0.195, hw)
        let seatBack = min(tankFront + overhang + 0.046, hd - 0.03)
        let seatTip = min(hd, seatBack + 0.56)
        let seatLength = seatTip - seatBack
        let nose = min(0.30, seatLength * 0.62)
        let seat = Plan(half: seatHalf, back: seatBack, shoulder: seatTip - nose, tip: seatTip, corner: 0.034)
        var rim = seat.grown(-0.004)
        rim.back = -hd + 0.030
        rim.corner = 0.030

        // Bowl and skirt: full at the rim, tucked in toward the floor.
        let lip: Float = 0.005, band: Float = 0.042, foot: Float = 0.018
        let recede = min(0.068, seatLength * 0.15), tuck: Float = min(0.022, rim.half * 0.12)
        let skirtTop = rimTop - band
        var bowl: [[V3]] = []
        var base = rim.grown(-lip)
        base.half -= tuck
        base.tip -= recede
        // A low foot, a touch proud of the skirt, makes a clean line on the floor.
        bowl.append(base.grown(0.0035).ring(at: 0))
        bowl.append(base.grown(0.0035).ring(at: 0.008))
        bowl.append(base.grown(0.0015).ring(at: 0.012))
        let steps = 9
        for step in 0...steps {
            let s = Float(step) / Float(steps)
            let full = 1 - pow(1 - s, 1.2)
            var plan = rim.grown(-lip)
            plan.half -= tuck * (1 - full)
            plan.tip -= recede * (1 - full)
            bowl.append(plan.ring(at: foot + (skirtTop - foot) * s))
        }
        // The rim stands a little proud of the skirt, eased out with no ledge.
        for (rise, part) in [(Float(0.004), Float(0.9)), (0.009, 0.5), (0.014, 0.1), (0.018, 0)] {
            bowl.append(rim.grown(-lip * part).ring(at: skirtTop + rise))
        }
        bowl += Self.roundOver(rim, from: rimTop - 0.006, radius: 0.006)
        bowl.append(rim.grown(-0.030).ring(at: rimTop))
        china.skin(bowl, capEnd: true)

        // Seat, then lid, each with its own joint line.
        var seatRings = [seat.grown(-0.004).ring(at: seatLow), seat.ring(at: seatLow + 0.004)]
        seatRings += Self.roundOver(seat, from: seatHigh - 0.004, radius: 0.004, segments: 2)
        seatRings.append(seat.grown(-0.03).ring(at: seatHigh))
        china.skin(seatRings, capStart: true, capEnd: true)
        dark.skin([seat.grown(-0.016).ring(at: rimTop - 0.002), seat.grown(-0.016).ring(at: seatLow + 0.002)])

        var lidRings = [seat.grown(-0.003).ring(at: lidLow), seat.ring(at: lidLow + 0.003)]
        lidRings += Self.roundOver(seat, from: lidHigh - 0.011, radius: 0.010, segments: 4)
        lidRings.append(seat.grown(-0.05).ring(at: lidHigh + 0.0015))
        lidRings.append(seat.grown(-0.10).ring(at: lidHigh + 0.0025))
        china.skin(lidRings, capStart: true, capEnd: true)
        dark.skin([seat.grown(-0.012).ring(at: seatHigh - 0.002), seat.grown(-0.012).ring(at: lidLow + 0.002)])

        // Hinge caps on the deck behind the lid.
        let hingeX = max(min(0.078, seatHalf - 0.055), 0.02), hingeZ = seatBack + 0.006, hingeTop = lidHigh + 0.005
        for x in [-hingeX, hingeX] {
            metal.lathe(at: V3(x, 0, hingeZ), profile: [
                (0.0165, rimTop - 0.002), (0.0165, hingeTop - 0.004), (0.0152, hingeTop - 0.001),
                (0.0125, hingeTop), (0.005, hingeTop + 0.0006),
            ])
        }

        // Tank: narrower at the foot, round under, a flat joint to the bowl.
        let taper: Float = 0.010, lean: Float = 0.012, under: Float = 0.022
        let top = Slab(half: tankTopHalf, back: -hd + 0.006, front: tankFront, backCorner: 0.012, frontCorner: 0.038)
        var low = top
        low.half -= taper
        low.front -= lean
        var tank: [[V3]] = []
        for step in 0...3 {
            let angle = Float(step) * .pi / 6
            tank.append(low.grown(-under * (1 - sin(angle))).ring(at: tankLow + under * (1 - cos(angle))))
        }
        tank.append(top.ring(at: tankHigh - 0.002))
        tank.append(top.grown(-0.002).ring(at: tankHigh))
        china.skin(tank, capStart: true, capEnd: true)
        let joint = Slab(half: min(rim.half, low.half) - 0.014, back: rim.back + 0.012, front: low.front - under - 0.004,
                         backCorner: 0.004, frontCorner: 0.004)
        dark.skin([joint.ring(at: rimTop - 0.002), joint.ring(at: tankLow + 0.002)])

        // Cover: a little proud of the tank all round, soft top edge.
        var cover = top.grown(overhang)
        cover.back = -hd
        var coverRings = [cover.grown(-0.003).ring(at: coverLow), cover.ring(at: coverLow + 0.003)]
        coverRings += Self.roundOver(cover, from: coverHigh - 0.006, radius: 0.006)
        coverRings.append(cover.grown(-0.04).ring(at: coverHigh + 0.001))
        china.skin(coverRings, capStart: true, capEnd: true)
        dark.skin([top.grown(-0.006).ring(at: tankHigh - 0.002), top.grown(-0.006).ring(at: coverLow + 0.002)])

        // Dual flush button in the middle of the cover.
        let buttonZ = (cover.back + cover.front) / 2, buttonY = coverHigh + 0.001
        metal.lathe(at: V3(0, 0, buttonZ), profile: [
            (0.0290, buttonY - 0.002), (0.0290, buttonY + 0.0020), (0.0275, buttonY + 0.0032),
            (0.0240, buttonY + 0.0032), (0.0232, buttonY + 0.0020), (0.0222, buttonY + 0.0020),
            (0.0222, buttonY + 0.0048), (0.0200, buttonY + 0.0062), (0.006, buttonY + 0.0068),
        ])
        dark.box(from: V3(-0.0007, buttonY + 0.004, buttonZ - 0.0215), to: V3(0.0007, buttonY + 0.0071, buttonZ + 0.0215))
    }

    /// Rings that turn a vertical side into a flat top through a quarter
    /// round, ending one radius inside the plan at `from + radius`.
    private static func roundOver<Shape: ToiletOutline>(_ shape: Shape, from y: Float, radius: Float,
                                                         segments: Int = 3) -> [[V3]] {
        (0...segments).map { step in
            let angle = Float(step) / Float(segments) * .pi / 2
            return shape.grown(-radius * (1 - cos(angle))).ring(at: y + radius * sin(angle))
        }
    }
}

private protocol ToiletOutline {
    func grown(_ amount: Float) -> Self
    func ring(at y: Float) -> [SIMD3<Float>]
}

/// The plan of a bowl, seat or lid: a straight back with eased corners,
/// straight sides and a full rounded nose. Rings always have the same
/// number of points, so any two can be joined.
private struct Plan: ToiletOutline {
    var half: Float
    var back: Float
    var shoulder: Float
    var tip: Float
    var corner: Float

    /// Offsets the outline outward, or inward for a negative amount. An
    /// inset stops short of the middle, so a small plan never turns inside out.
    func grown(_ amount: Float) -> Plan {
        let g = max(amount, -max(min(half, (tip - back) / 2) - 0.006, 0))
        return Plan(half: half + g, back: back - g, shoulder: shoulder, tip: tip + g, corner: corner + g)
    }

    func ring(at y: Float) -> [SIMD3<Float>] {
        let a = max(half, 0.004), front = max(tip, back + 0.012)
        let start = min(max(shoulder, back + 0.004), front - 0.004)
        let r = max(0.002, min(corner, a - 0.001, start - back - 0.001))
        let length = front - start
        var points: [SIMD3<Float>] = []
        for step in 0...4 {
            let angle = -Float.pi / 2 + Float(step) * .pi / 8
            points.append(SIMD3(a - r + cos(angle) * r, y, back + r + sin(angle) * r))
        }
        for step in 0...28 {
            let angle = Float(step) * .pi / 28
            let c = cos(angle), s = sin(angle)
            let x = (c < 0 ? -1 : 1) * pow(abs(c), 0.85) * a
            points.append(SIMD3(x, y, start + pow(s, 0.85) * length))
        }
        for step in 0...4 {
            let angle = Float.pi + Float(step) * .pi / 8
            points.append(SIMD3(-a + r + cos(angle) * r, y, back + r + sin(angle) * r))
        }
        return points
    }
}

/// The plan of the tank or its cover: a rectangle with eased corners,
/// tighter at the wall than at the front.
private struct Slab: ToiletOutline {
    var half: Float
    var back: Float
    var front: Float
    var backCorner: Float
    var frontCorner: Float

    func grown(_ amount: Float) -> Slab {
        let g = max(amount, -max(min(half, (front - back) / 2) - 0.006, 0))
        return Slab(half: half + g, back: back - g, front: front + g, backCorner: backCorner + g, frontCorner: frontCorner + g)
    }

    func ring(at y: Float) -> [SIMD3<Float>] {
        let a = max(half, 0.004), z1 = max(front, back + 0.008)
        let limit = min(a, (z1 - back) / 2) - 0.001
        let rb = max(0.001, min(backCorner, limit)), rf = max(0.001, min(frontCorner, limit))
        var points: [SIMD3<Float>] = []
        func arc(_ cx: Float, _ cz: Float, _ r: Float, from: Float) {
            for step in 0...5 {
                let angle = from + Float(step) * .pi / 10
                points.append(SIMD3(cx + cos(angle) * r, y, cz + sin(angle) * r))
            }
        }
        arc(a - rb, back + rb, rb, from: -.pi / 2)
        arc(a - rf, z1 - rf, rf, from: 0)
        arc(-a + rf, z1 - rf, rf, from: .pi / 2)
        arc(-a + rb, back + rb, rb, from: .pi)
        return points
    }
}

private extension PreviewMesh {
    /// Skins a stack of closed rings, all with the same number of points,
    /// with smooth normals. Two rings close together make a soft edge.
    mutating func skin(_ rings: [[V3]], capStart: Bool = false, capEnd: Bool = false) {
        let count = rings.first?.count ?? 0
        guard rings.count >= 2, count >= 3, !rings.contains(where: { $0.count != count }) else { return }
        var centre = V3.zero
        for ring in rings { centre += ring.reduce(V3.zero, +) }
        centre /= Float(rings.count * count)
        var normals: [[V3]] = []
        var vote: Float = 0
        for j in 0..<rings.count {
            let before = rings[max(j - 1, 0)], after = rings[min(j + 1, rings.count - 1)]
            var row: [V3] = []
            for i in 0..<count {
                let around = rings[j][(i + 1) % count] - rings[j][(i + count - 1) % count]
                let cross = simd_cross(around, after[i] - before[i])
                let length = simd_length(cross)
                let normal = length > 1e-10 ? cross / length : V3(0, 1, 0)
                vote += simd_dot(normal, rings[j][i] - centre)
                row.append(normal)
            }
            normals.append(row)
        }
        let sign: Float = vote >= 0 ? 1 : -1
        var index: [[UInt32]] = []
        for j in 0..<rings.count {
            index.append((0..<count).map { vertex(rings[j][$0], normals[j][$0] * sign, .zero) })
        }
        for j in 0..<(rings.count - 1) {
            for i in 0..<count {
                let k = (i + 1) % count
                let facing = (normals[j][i] + normals[j][k] + normals[j + 1][k] + normals[j + 1][i]) * sign
                triangle(index[j][i], index[j][k], index[j + 1][k], facing: facing)
                triangle(index[j][i], index[j + 1][k], index[j + 1][i], facing: facing)
            }
        }
        if capStart { cap(rings[0], awayFrom: centre) }
        if capEnd { cap(rings[rings.count - 1], awayFrom: centre) }
    }

    /// A flat fan over a convex ring, facing away from a point inside the solid.
    mutating func cap(_ ring: [V3], awayFrom inside: V3) {
        let middle = ring.reduce(V3.zero, +) / Float(ring.count)
        var normal = V3.zero
        for i in 0..<ring.count { normal += simd_cross(ring[i] - middle, ring[(i + 1) % ring.count] - middle) }
        guard simd_length(normal) > 1e-12 else { return }
        normal = simd_normalize(normal)
        if simd_dot(normal, middle - inside) < 0 { normal = -normal }
        let hub = vertex(middle, normal, .zero)
        let edge = ring.map { vertex($0, normal, .zero) }
        for i in 0..<ring.count { triangle(hub, edge[i], edge[(i + 1) % ring.count], facing: normal) }
    }

    /// A turned solid about an upright axis through `axis`, from pairs of
    /// radius and height, bottom to top. The top is closed.
    mutating func lathe(at axis: V3, profile: [(radius: Float, y: Float)], segments: Int = 20) {
        let rings = profile.map { step in
            (0..<segments).map { index -> V3 in
                let angle = Float(index) / Float(segments) * 2 * .pi
                return V3(axis.x + cos(angle) * step.radius, step.y, axis.z + sin(angle) * step.radius)
            }
        }
        skin(rings, capEnd: true)
    }
}
