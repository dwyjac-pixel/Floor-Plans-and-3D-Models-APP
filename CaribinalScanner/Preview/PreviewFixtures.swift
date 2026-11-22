import SceneKit
import simd

/// Finished models for the fixtures a bathroom needs, each built to the
/// footprint drawn on the plan. A fixture's own x runs along its width,
/// its back is at -z and its front at +z, the same as the plan editor.
extension PreviewRoomScene {
    func buildFixtures() {
        let root = SCNNode()
        root.name = "fixtures"
        scene.rootNode.addChildNode(root)
        for solid in layout.solids {
            let node = SCNNode()
            node.name = "fixture-\(solid.id.uuidString)"
            node.simdPosition = v(solid.centre, 0)
            node.simdEulerAngles = V3(0, Float(solid.yawDegrees * .pi / 180), 0)
            (solid.kind == .bulkhead ? overheadHidden : root).addChildNode(node)
            switch solid.kind {
            case .vanity: buildVanity(solid, in: node)
            case .toilet: buildToilet(solid, in: node)
            case .shower: buildShower(solid, in: node)
            case .bulkhead: buildBulkhead(solid, in: node)
            default: buildMassing(solid, in: node)
            }
        }
    }

    // MARK: Parts

    private func emit(_ mesh: PreviewMesh, _ slot: PreviewFinish.Slot, in node: SCNNode) {
        if !mesh.isEmpty { add(mesh.geometry(), slot: slot, to: node) }
    }

    @discardableResult
    private func block(_ slot: PreviewFinish.Slot, in node: SCNNode, x: ClosedRange<Float>, y: ClosedRange<Float>,
                       z: ClosedRange<Float>, chamfer: Float = 0) -> SCNNode {
        let box = SCNBox(width: CGFloat(x.upperBound - x.lowerBound), height: CGFloat(y.upperBound - y.lowerBound),
                         length: CGFloat(z.upperBound - z.lowerBound), chamferRadius: CGFloat(chamfer))
        box.chamferSegmentCount = 3
        let child = add(box, slot: slot, to: node)
        child.simdPosition = V3((x.lowerBound + x.upperBound) / 2, (y.lowerBound + y.upperBound) / 2,
                                (z.lowerBound + z.upperBound) / 2)
        return child
    }

    private enum Axis { case x, y, z }

    @discardableResult
    private func rod(_ slot: PreviewFinish.Slot, in node: SCNNode, radius: Float, length: Float, at centre: V3,
                     along axis: Axis) -> SCNNode {
        let cylinder = SCNCylinder(radius: CGFloat(radius), height: CGFloat(length))
        cylinder.radialSegmentCount = 24
        let child = add(cylinder, slot: slot, to: node)
        child.simdPosition = centre
        switch axis {
        case .x: child.simdEulerAngles = V3(0, 0, .pi / 2)
        case .y: break
        case .z: child.simdEulerAngles = V3(.pi / 2, 0, 0)
        }
        return child
    }

    /// Whether one side of a footprint stands against a wall.
    private func walled(_ solid: PreviewLayout.Solid, _ a: Int, _ b: Int) -> Bool {
        let corners = solid.corners
        return layout.touchesWall(corners[a], corners[b])
    }

    /// Headroom over a fixture: the lowest ceiling or bulkhead above it.
    private func headroom(over solid: PreviewLayout.Solid) -> Float {
        Float((solid.corners + [solid.centre]).map { layout.clearHeight(above: $0) }.min() ?? layout.ceilingHeight)
    }

    // MARK: Vanity

    private func buildVanity(_ solid: PreviewLayout.Solid, in node: SCNNode) {
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

    // MARK: Toilet

    private func buildToilet(_ solid: PreviewLayout.Solid, in node: SCNNode) {
        let hw = Float(solid.width) / 2, hd = Float(solid.depth) / 2
        let half = min(hw - 0.03, 0.185), nose = min(0.27, Float(solid.depth) * 0.4)
        func outline(from back: Float, grow: Float) -> [PreviewMesh.V2] {
            let middle = hd - nose
            var points = [PreviewMesh.V2(-half - grow, back), PreviewMesh.V2(-half - grow, middle)]
            for step in 1..<18 {
                let angle = Float.pi * Float(step) / 18
                points.append(PreviewMesh.V2(-cos(angle) * (half + grow), middle + sin(angle) * (nose + grow)))
            }
            points += [PreviewMesh.V2(half + grow, middle), PreviewMesh.V2(half + grow, back)]
            return points
        }
        var china = PreviewMesh()
        china.prism(outline: outline(from: -hd + 0.03, grow: 0), from: 0, to: 0.385, bevel: 0.018)
        china.prism(outline: outline(from: -hd + 0.215, grow: 0.007), from: 0.392, to: 0.43, bevel: 0.014)
        emit(china, .whiteware, in: node)
        var dark = PreviewMesh()
        dark.prism(outline: outline(from: -hd + 0.215, grow: -0.006), from: 0.38, to: 0.394, bevel: 0)
        emit(dark, .shadowGap, in: node)
        let tank = min(0.40, 2 * hw - 0.06)
        block(.whiteware, in: node, x: (-tank / 2)...(tank / 2), y: 0.385...0.78, z: (-hd + 0.008)...(-hd + 0.198), chamfer: 0.022)
        block(.whiteware, in: node, x: (-tank / 2 - 0.006)...(tank / 2 + 0.006), y: 0.782...0.812,
              z: (-hd + 0.004)...(-hd + 0.204), chamfer: 0.011)
        rod(.hardware, in: node, radius: 0.022, length: 0.005, at: V3(0, 0.8145, -hd + 0.10), along: .y)
    }

    // MARK: Shower

    private func buildShower(_ solid: PreviewLayout.Solid, in node: SCNNode) {
        let hw = Float(solid.width) / 2, hd = Float(solid.depth) / 2
        let pan: Float = 0.06
        let clear = headroom(over: solid)
        let glassTop = min(1.98, clear - 0.10)
        // Corner order: back left, back right, front right, front left.
        let backWalled = walled(solid, 0, 1), rightWalled = walled(solid, 1, 2)
        let frontWalled = walled(solid, 2, 3), leftWalled = walled(solid, 3, 0)

        block(.showerBase, in: node, x: -hw...hw, y: 0...pan, z: -hd...hd, chamfer: 0.008)
        block(.hardware, in: node, x: (-min(0.35, hw * 0.5))...min(0.35, hw * 0.5), y: pan...(pan + 0.003),
              z: (-hd + 0.07)...(-hd + 0.13))

        var glass = PreviewMesh()
        func pane(x: ClosedRange<Float>, z: ClosedRange<Float>) {
            // One sheet at the middle of the pane's thickness.
            let wide = x.upperBound - x.lowerBound, deep = z.upperBound - z.lowerBound
            if wide > deep {
                glass.rect(origin: V3(x.lowerBound, pan, (z.lowerBound + z.upperBound) / 2), u: V3(wide, 0, 0),
                           v: V3(0, glassTop - pan, 0), facing: V3(0, 0, 1))
            } else {
                glass.rect(origin: V3((x.lowerBound + x.upperBound) / 2, pan, z.lowerBound), u: V3(0, 0, deep),
                           v: V3(0, glassTop - pan, 0), facing: V3(1, 0, 0))
            }
            // A fine green line along the top edge keeps the glass legible.
            block(.glassEdge, in: node, x: x, y: (glassTop - 0.002)...glassTop, z: z)
        }
        func edge(x: Float, z: Float) {
            block(.glassEdge, in: node, x: (x - 0.005)...(x + 0.005), y: pan...glassTop, z: (z - 0.005)...(z + 0.005))
        }

        if !frontWalled {
            let plane = hd - 0.022
            // The fixed pane stands at the shower head end, the door at the other.
            let headLeft = leftWalled || !rightWalled
            let doorWidth: Float = 2 * hw >= 1.25 ? 0.70 : 2 * hw - 0.012
            let fixed = 2 * hw - doorWidth - 0.006
            let sign: Float = headLeft ? 1 : -1
            // Positions are written for a head on the left and mirrored otherwise.
            func span(_ a: Float, _ b: Float) -> ClosedRange<Float> { min(a * sign, b * sign)...max(a * sign, b * sign) }
            let doorStart = -hw + fixed + 0.006
            if fixed > 0.15 {
                pane(x: span(-hw + 0.004, -hw + fixed), z: (plane - 0.005)...(plane + 0.005))
                block(.hardware, in: node, x: span(-hw, -hw + fixed), y: pan...(pan + 0.012), z: (plane - 0.009)...(plane + 0.009))
                block(.hardware, in: node, x: span(-hw, -hw + 0.012), y: pan...glassTop, z: (plane - 0.009)...(plane + 0.009))
                edge(x: (-hw + fixed) * sign, z: plane)
            }
            pane(x: span(doorStart, hw - 0.006), z: (plane - 0.005)...(plane + 0.005))
            edge(x: doorStart * sign, z: plane)
            edge(x: (hw - 0.006) * sign, z: plane)
            // Hinges on the wall side of the door, a pull on its free edge.
            for y in [pan + 0.28, glassTop - 0.28] {
                block(.hardware, in: node, x: span(hw - 0.055, hw), y: (y - 0.045)...(y + 0.045),
                      z: (plane - 0.014)...(plane + 0.014), chamfer: 0.003)
            }
            for side: Float in [-1, 1] {
                rod(.hardware, in: node, radius: 0.009, length: 0.32, at: V3((doorStart + 0.075) * sign, 1.05, plane + side * 0.04), along: .y)
                for dy: Float in [-0.12, 0.12] {
                    rod(.hardware, in: node, radius: 0.006, length: 0.035,
                        at: V3((doorStart + 0.075) * sign, 1.05 + dy, plane + side * 0.022), along: .z)
                }
            }
            // A slim header ties the glass to both walls.
            block(.hardware, in: node, x: -hw...hw, y: glassTop...(glassTop + 0.014), z: (plane - 0.008)...(plane + 0.008))
        }
        for (isWalled, x) in [(leftWalled, -hw + 0.022), (rightWalled, hw - 0.022)] where !isWalled {
            pane(x: (x - 0.005)...(x + 0.005), z: (-hd + 0.004)...(hd - 0.03))
            block(.hardware, in: node, x: (x - 0.009)...(x + 0.009), y: pan...(pan + 0.012), z: -hd...(hd - 0.03))
        }

        emit(glass, .glass, in: node)

        // Rain head and valve on an end wall, or the back wall failing that.
        let headY = min(2.02, clear - 0.10)
        if leftWalled || rightWalled {
            let sign: Float = leftWalled ? 1 : -1
            rod(.hardware, in: node, radius: 0.011, length: 0.34, at: V3((-hw + 0.17) * sign, headY, 0), along: .x)
            rod(.hardware, in: node, radius: 0.028, length: 0.008, at: V3((-hw + 0.004) * sign, headY, 0), along: .x)
            rod(.hardware, in: node, radius: 0.105, length: 0.012, at: V3((-hw + 0.34) * sign, headY - 0.03, 0), along: .y)
            rod(.hardware, in: node, radius: 0.011, length: 0.03, at: V3((-hw + 0.34) * sign, headY - 0.012, 0), along: .y)
            rod(.hardware, in: node, radius: 0.075, length: 0.008, at: V3((-hw + 0.004) * sign, 1.12, 0), along: .x)
            rod(.hardware, in: node, radius: 0.022, length: 0.05, at: V3((-hw + 0.03) * sign, 1.12, 0), along: .x)
            rod(.hardware, in: node, radius: 0.007, length: 0.075, at: V3((-hw + 0.05) * sign, 1.12, 0.035), along: .z)
        } else if backWalled {
            rod(.hardware, in: node, radius: 0.011, length: 0.34, at: V3(0, headY, -hd + 0.17), along: .z)
            rod(.hardware, in: node, radius: 0.105, length: 0.012, at: V3(0, headY - 0.03, -hd + 0.34), along: .y)
            rod(.hardware, in: node, radius: 0.075, length: 0.008, at: V3(0.25, 1.12, -hd + 0.004), along: .z)
            rod(.hardware, in: node, radius: 0.022, length: 0.05, at: V3(0.25, 1.12, -hd + 0.03), along: .z)
        }
    }

    // MARK: Bulkhead and everything else

    private func buildBulkhead(_ solid: PreviewLayout.Solid, in node: SCNNode) {
        let hw = Float(solid.width) / 2, hd = Float(solid.depth) / 2
        let height = Float(layout.ceilingHeight), drop = Float(solid.drop ?? PreviewLayout.defaultBulkheadDrop)
        var mesh = PreviewMesh()
        mesh.box(from: V3(-hw, height - drop, -hd), to: V3(hw, height - 0.001, hd))
        if !mesh.isEmpty { add(mesh.geometry(), slot: .ceiling, to: node).castsShadow = false }
    }

    /// A plain block for anything this release has no finished model for.
    /// It keeps the drawn footprint and is listed under the picture.
    private func buildMassing(_ solid: PreviewLayout.Solid, in node: SCNNode) {
        let hw = Float(solid.width) / 2, hd = Float(solid.depth) / 2
        let ceiling = Float(layout.ceilingHeight)
        let range: ClosedRange<Float>
        switch solid.kind {
        case .upperCabinets: range = min(1.37, ceiling - 0.8)...min(2.13, ceiling - 0.02)
        case .fridge: range = 0...min(1.75, ceiling - 0.05)
        case .furnace, .waterHeater: range = 0...min(1.5, ceiling - 0.05)
        case .bedQueen, .bedSingle, .tubShower: range = 0...0.55
        case .sofa: range = 0...0.8
        case .stairs: range = 0...min(1.0, ceiling - 0.05)
        default: range = 0...0.9
        }
        block(.massing, in: node, x: -hw...hw, y: range, z: -hd...hd, chamfer: 0.01)
    }
}
