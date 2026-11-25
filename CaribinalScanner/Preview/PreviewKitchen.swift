import SceneKit

extension PreviewRoomScene {
    func buildKitchenCabinet(_ solid: PreviewLayout.Solid, in node: SCNNode) {
        let x = Float(solid.width / 2), z = Float(solid.depth / 2)
        let short = solid.kind == .shortUpperCabinet
        let upper = short || solid.kind == .upperCabinets
        let top = upper ? min(2.12, headroom(over: solid) - 0.04) : 0.88
        let bottom = upper ? max(0.94, top - (short ? 0.30 : 0.70)) : 0.09
        guard x > 0.04, z > 0.04, top > bottom + 0.10 else { return }
        block(.vanityCabinet, in: node, x: -x...x, y: bottom...(solid.kind == .kitchenSink ? 0.75 : top), z: -z...(z - 0.025))
        if !upper {
            block(.shadowGap, in: node, x: -x...x, y: 0...bottom, z: -z...(z - 0.047))
            if solid.kind == .kitchenSink {
                kitchenSink(in: node, x: x, z: z)
            } else {
                block(.vanityTop, in: node, x: -x...x, y: top...0.92, z: -z...z, chamfer: 0.003)
            }
        }

        let count = short && solid.width >= 0.45 ? 2 : max(1, min(24, Int((solid.width / 0.54).rounded())))
        let panelWidth = 2 * x / Float(count)
        for index in 0..<count {
            let left = -x + Float(index) * panelWidth
            let edges = (left + 0.003)...(left + panelWidth - 0.003)
            let height = top - bottom
            let drawer = !upper && solid.kind != .kitchenSink
            let split = drawer ? top - height * 0.27 : top
            func front(_ low: Float, _ high: Float, handleY: Float, vertical: Bool = false) {
                block(.vanityCabinet, in: node, x: edges, y: low...high,
                      z: (z - 0.023)...z, chamfer: 0.002)
                let innerEdge = short && index == 1 ? edges.lowerBound + 0.025 : edges.upperBound - 0.025
                let handleX = vertical ? innerEdge : left + panelWidth / 2
                rod(.hardware, in: node, radius: 0.006, length: min(0.14, panelWidth * 0.55),
                    at: V3(handleX, handleY, z + 0.016), along: vertical ? .y : .x)
            }
            front(bottom + 0.004, split - 0.004, handleY: upper ? bottom + 0.11 : split - 0.07,
                  vertical: upper)
            if drawer { front(split + 0.003, top - 0.003, handleY: (split + top) / 2) }
        }
    }

    private func kitchenSink(in node: SCNNode, x: Float, z: Float) {
        let bowlX = x * 0.73, bowlZ = z * 0.65
        for strip in [-x ... -bowlX, bowlX...x] {
            block(.vanityTop, in: node, x: strip, y: 0.88...0.92, z: -z...z)
        }
        for strip in [-z ... -bowlZ, bowlZ...z] {
            block(.vanityTop, in: node, x: -bowlX...bowlX, y: 0.88...0.92, z: strip)
        }
        // The bowl drops into the counter opening.
        block(.applianceSteel, in: node, x: -bowlX...bowlX, y: 0.76...0.78, z: -bowlZ...bowlZ)
        for strip in [-bowlX ... (-bowlX + 0.012), (bowlX - 0.012)...bowlX] {
            block(.applianceSteel, in: node, x: strip, y: 0.78...0.92, z: -bowlZ...bowlZ)
        }
        for strip in [-bowlZ ... (-bowlZ + 0.012), (bowlZ - 0.012)...bowlZ] {
            block(.applianceSteel, in: node, x: -bowlX...bowlX, y: 0.78...0.92, z: strip)
        }
        rod(.shadowGap, in: node, radius: 0.034, length: 0.004, at: V3(0, 0.782, 0), along: .y)
        let back = -(z + bowlZ) / 2
        var faucet = PreviewMesh()
        faucet.tube([V3(0, 0.92, back), V3(0, 1.13, back), V3(0, 1.17, back + 0.04),
                     V3(0, 1.17, back + 0.13), V3(0, 1.13, back + 0.18)],
                    radii: [0.016, 0.016, 0.016, 0.016, 0.016], sides: 16, capped: (false, true))
        emit(faucet, .hardware, in: node)
    }

    func buildKitchenAppliance(_ solid: PreviewLayout.Solid, in node: SCNNode) {
        let x = Float(solid.width / 2), z = Float(solid.depth / 2)
        let clearance = headroom(over: solid)
        let mounted = solid.kind == .microwave
        let top: Float = mounted ? min(1.79, clearance - 0.36)
            : min(clearance - 0.025, solid.kind == .fridge ? 1.79 : 0.91)
        let bottom: Float = mounted ? max(0.94, top - 0.37) : 0
        guard x > 0.04, z > 0.04, top > bottom + 0.12 else { return }
        block(.applianceSteel, in: node, x: -x...x, y: bottom...top, z: -z...(z - 0.012), chamfer: 0.004)
        let face = (z - 0.011)...z
        let height = top - bottom

        switch solid.kind {
        case .fridge:
            let split = bottom + height * 0.31
            for panel in [(bottom + 0.02)...(split - 0.003), (split + 0.003)...top] {
                block(.applianceSteel, in: node, x: -x...x, y: panel, z: face, chamfer: 0.004)
                let middle = (panel.lowerBound + panel.upperBound) / 2
                rod(.applianceSteel, in: node, radius: 0.012, length: min(0.45, (panel.upperBound - panel.lowerBound) * 0.65),
                    at: V3(x * 0.78, middle, z + 0.022), along: .y)
            }
        case .stove:
            block(.shadowGap, in: node, x: -x...x, y: (top - 0.015)...top, z: -z...z)
            for side in [-0.5 as Float, 0.5] {
                for row in [-0.50 as Float, 0.50] {
                    rod(.applianceSteel, in: node, radius: min(x, z) * 0.32, length: 0.004,
                        at: V3(x * side, top + 0.002, z * row), along: .y)
                }
            }
            block(.shadowGap, in: node, x: (-x * 0.87)...(x * 0.87), y: (top * 0.20)...(top * 0.76), z: face, chamfer: 0.003)
            for knob in [-0.72 as Float, -0.24, 0.24, 0.72] {
                rod(.shadowGap, in: node, radius: 0.018, length: 0.022,
                    at: V3(x * knob, top * 0.92, z + 0.012), along: .z)
            }
            rod(.applianceSteel, in: node, radius: 0.009, length: x * 1.65, at: V3(0, top * 0.80, z + 0.022), along: .x)
        case .microwave:
            block(.shadowGap, in: node, x: (-x * 0.91)...(x * 0.49),
                  y: (bottom + height * 0.12)...(top - height * 0.14), z: face, chamfer: 0.004)
            block(.shadowGap, in: node, x: (x * 0.63)...(x * 0.91),
                  y: (bottom + height * 0.61)...(bottom + height * 0.83), z: face)
            rod(.applianceSteel, in: node, radius: 0.008, length: height * 0.57,
                at: V3(x * 0.48, bottom + height * 0.49, z + 0.023), along: .y)
        case .dishwasher:
            block(.shadowGap, in: node, x: (-x * 0.87)...(x * 0.87), y: (top * 0.86)...(top * 0.96), z: face)
            block(.applianceSteel, in: node, x: -x...x, y: (top * 0.09)...(top * 0.85), z: face, chamfer: 0.003)
            rod(.applianceSteel, in: node, radius: 0.009, length: x * 1.65, at: V3(0, top * 0.79, z + 0.022), along: .x)
        default: break
        }
    }
}
