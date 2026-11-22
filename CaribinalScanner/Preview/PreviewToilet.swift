import SceneKit
import simd

/// A skirted two-piece toilet built to the drawn footprint. The tank is
/// at -z against the wall and the bowl faces +z.
extension PreviewRoomScene {
    func buildToilet(_ solid: PreviewLayout.Solid, in node: SCNNode) {
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
}
