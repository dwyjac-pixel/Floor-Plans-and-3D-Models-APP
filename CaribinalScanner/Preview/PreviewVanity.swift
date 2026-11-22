import SceneKit
import simd

/// A floor-standing vanity with a drawer row over doors, a counter with an
/// undermount basin, a single lever tap and a framed mirror, built to the
/// drawn footprint. Its back is at -z and its doors face +z.
extension PreviewRoomScene {
    func buildVanity(_ solid: PreviewLayout.Solid, in node: SCNNode) {
        let hw = Float(solid.width) / 2, hd = Float(solid.depth) / 2
        let top: Float = 0.87, slab: Float = 0.03, kick: Float = 0.10, gap: Float = 0.003
        let face = hd - 0.022
        var cabinet = PreviewMesh(), stone = PreviewMesh(), china = PreviewMesh(), dark = PreviewMesh()

        dark.box(from: V3(-hw + 0.02, 0, -hd), to: V3(hw - 0.02, kick, face - 0.07))
        // Side panels only: the top is the counter and the basin drops inside.
        for x in [-hw, hw] {
            cabinet.rect(origin: V3(x, kick, -hd), u: V3(0, 0, face - 0.019 + hd), v: V3(0, top - slab - kick, 0),
                         facing: V3(x, 0, 0), uvOrigin: PreviewMesh.V2(0.11, 0.07))
        }
        // A dark plane just behind the fronts makes the reveals read.
        dark.rect(origin: V3(-hw + 0.001, kick + 0.001, face - 0.0185), u: V3(2 * hw - 0.002, 0, 0),
                  v: V3(0, top - slab - kick - 0.002, 0))

        // Fronts: a drawer row over doors.
        let frontTop = top - slab - gap, frontBottom = kick + gap
        let drawer: Float = frontTop - frontBottom > 0.5 ? 0.17 : 0
        let doors = max(1, Int((solid.width / 0.45).rounded()))
        let doorWidth = (2 * hw - gap * Float(doors + 1)) / Float(doors)
        func front(_ x0: Float, _ x1: Float, _ y0: Float, _ y1: Float) {
            cabinet.box(from: V3(x0, y0, face - 0.018), to: V3(x1, y1, face),
                        uvOrigin: PreviewMesh.V2(x0 + hw + y0 * 0.37, y0))
        }
        if drawer > 0 {
            front(-hw + gap, hw - gap, frontTop - drawer, frontTop)
            rod(.hardware, in: node, radius: 0.005, length: 0.15, at: V3(0, frontTop - drawer / 2, face + 0.026), along: .x)
            for dx: Float in [-0.06, 0.06] {
                rod(.hardware, in: node, radius: 0.004, length: 0.026, at: V3(dx, frontTop - drawer / 2, face + 0.013), along: .z)
            }
        }
        let doorTop = drawer > 0 ? frontTop - drawer - gap : frontTop
        for index in 0..<doors {
            let x0 = -hw + gap + Float(index) * (doorWidth + gap)
            front(x0, x0 + doorWidth, frontBottom, doorTop)
            // Pulls near the meeting edge, or the right edge of a single door.
            let inner = doors == 1 ? x0 + doorWidth - 0.045 : (index < doors / 2 ? x0 + doorWidth - 0.045 : x0 + 0.045)
            let pullY = doorTop - 0.14
            rod(.hardware, in: node, radius: 0.005, length: 0.15, at: V3(inner, pullY, face + 0.026), along: .y)
            for dy: Float in [-0.06, 0.06] {
                rod(.hardware, in: node, radius: 0.004, length: 0.026, at: V3(inner, pullY + dy, face + 0.013), along: .z)
            }
        }

        // Counter with an undermount basin.
        let basinWidth = min(0.48, 2 * hw - 0.22), basinDepth = min(0.34, 2 * hd - 0.2)
        let bx0 = -basinWidth / 2, bx1 = basinWidth / 2, bz0 = 0.015 - basinDepth / 2, bz1 = 0.015 + basinDepth / 2
        let under = top - slab
        func slabPiece(_ x0: Float, _ x1: Float, _ z0: Float, _ z1: Float) {
            stone.box(from: V3(x0, under, z0), to: V3(x1, top, z1), uvOrigin: PreviewMesh.V2(x0 + hw, z0 + hd))
        }
        slabPiece(-hw, bx0, -hd, hd)
        slabPiece(bx1, hw, -hd, hd)
        slabPiece(bx0, bx1, -hd, bz0)
        slabPiece(bx0, bx1, bz1, hd)
        stone.box(from: V3(-hw, top, -hd), to: V3(hw, top + 0.10, -hd + 0.015), uvOrigin: PreviewMesh.V2(0.3, 0.6))
        let bowl = under - 0.125
        china.rect(origin: V3(bx0, bowl, bz0), u: V3(basinWidth, 0, 0), v: V3(0, 0, basinDepth), facing: up)
        china.rect(origin: V3(bx0, bowl, bz0), u: V3(basinWidth, 0, 0), v: V3(0, under - bowl, 0), facing: V3(0, 0, 1))
        china.rect(origin: V3(bx0, bowl, bz1), u: V3(basinWidth, 0, 0), v: V3(0, under - bowl, 0), facing: V3(0, 0, -1))
        china.rect(origin: V3(bx0, bowl, bz0), u: V3(0, 0, basinDepth), v: V3(0, under - bowl, 0), facing: V3(1, 0, 0))
        china.rect(origin: V3(bx1, bowl, bz0), u: V3(0, 0, basinDepth), v: V3(0, under - bowl, 0), facing: V3(-1, 0, 0))
        rod(.hardware, in: node, radius: 0.022, length: 0.004, at: V3(0, bowl + 0.002, 0.015), along: .y)

        // Single lever tap behind the basin.
        let tapZ = max(-hd + 0.05, bz0 - 0.05)
        rod(.hardware, in: node, radius: 0.024, length: 0.012, at: V3(0, top + 0.006, tapZ), along: .y)
        rod(.hardware, in: node, radius: 0.014, length: 0.20, at: V3(0, top + 0.10, tapZ), along: .y)
        rod(.hardware, in: node, radius: 0.011, length: 0.13, at: V3(0, top + 0.19, tapZ + 0.058), along: .z)
        rod(.hardware, in: node, radius: 0.011, length: 0.03, at: V3(0, top + 0.178, tapZ + 0.118), along: .y)
        rod(.hardware, in: node, radius: 0.006, length: 0.065, at: V3(0.04, top + 0.105, tapZ), along: .x)

        // Mirror on the wall behind, when the vanity backs onto one.
        if walled(solid, 0, 1) {
            let ceiling = Float(layout.clearHeight(above: solid.centre - solid.zAxis * (solid.depth / 2 - 0.02)))
            let low = top + 0.20, high = min(1.95, ceiling - 0.07)
            if high - low > 0.35 {
                let x0 = -hw + 0.06, x1 = hw - 0.06, back = -hd + 0.004, rim: Float = 0.012
                var glass = PreviewMesh()
                glass.rect(origin: V3(x0 + rim, low + rim, back + 0.012), u: V3(x1 - x0 - 2 * rim, 0, 0),
                           v: V3(0, high - low - 2 * rim, 0), facing: V3(0, 0, 1))
                emit(glass, .mirror, in: node)
                block(.hardware, in: node, x: x0...x1, y: low...(low + rim), z: back...(back + 0.02))
                block(.hardware, in: node, x: x0...x1, y: (high - rim)...high, z: back...(back + 0.02))
                block(.hardware, in: node, x: x0...(x0 + rim), y: low...high, z: back...(back + 0.02))
                block(.hardware, in: node, x: (x1 - rim)...x1, y: low...high, z: back...(back + 0.02))
            }
        }
        emit(cabinet, .vanityCabinet, in: node)
        emit(stone, .vanityTop, in: node)
        emit(china, .whiteware, in: node)
        emit(dark, .shadowGap, in: node)
    }
}
