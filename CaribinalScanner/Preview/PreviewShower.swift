import SceneKit
import simd

/// An alcove or corner shower built to the drawn footprint: a low base,
/// clear glass on every side that is not a wall, and a rain head and valve
/// on an end wall. Its back is at -z and its entry faces +z.
extension PreviewRoomScene {
    func buildShower(_ solid: PreviewLayout.Solid, in node: SCNNode) {
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
}
