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
            case .tubShower: buildTub(solid, in: node)
            case .bulkhead: buildBulkhead(solid, in: node)
            case .baseCabinets, .island, .upperCabinets, .shortUpperCabinet, .kitchenSink: buildKitchenCabinet(solid, in: node)
            case .fridge, .stove, .microwave, .dishwasher: buildKitchenAppliance(solid, in: node)
            default: buildMassing(solid, in: node)
            }
        }
    }

    private func buildTub(_ solid: PreviewLayout.Solid, in node: SCNNode) {
        let x = Float(solid.width / 2), z = Float(solid.depth / 2)
        guard x > 0.10, z > 0.10 else {
            buildMassing(solid, in: node)
            return
        }
        let rim: Float = 0.065
        block(.whiteware, in: node, x: -x...x, y: 0...0.18, z: -z...z, chamfer: 0.02)
        for xs in [-x...(-x + rim), (x - rim)...x] {
            block(.whiteware, in: node, x: xs, y: 0.17...0.53, z: -z...z, chamfer: 0.02)
        }
        for zs in [-z...(-z + rim), (z - rim)...z] {
            block(.whiteware, in: node, x: (-x + rim)...(x - rim), y: 0.17...0.53, z: zs, chamfer: 0.02)
        }
    }

    // MARK: Parts

    func emit(_ mesh: PreviewMesh, _ slot: PreviewFinish.Slot, in node: SCNNode) {
        if !mesh.isEmpty { add(mesh.geometry(), slot: slot, to: node) }
    }

    @discardableResult
    func block(_ slot: PreviewFinish.Slot, in node: SCNNode, x: ClosedRange<Float>, y: ClosedRange<Float>,
                       z: ClosedRange<Float>, chamfer: Float = 0) -> SCNNode {
        let box = SCNBox(width: CGFloat(x.upperBound - x.lowerBound), height: CGFloat(y.upperBound - y.lowerBound),
                         length: CGFloat(z.upperBound - z.lowerBound), chamferRadius: CGFloat(chamfer))
        box.chamferSegmentCount = 3
        let child = add(box, slot: slot, to: node)
        child.simdPosition = V3((x.lowerBound + x.upperBound) / 2, (y.lowerBound + y.upperBound) / 2,
                                (z.lowerBound + z.upperBound) / 2)
        return child
    }

    enum Axis { case x, y, z }

    @discardableResult
    func rod(_ slot: PreviewFinish.Slot, in node: SCNNode, radius: Float, length: Float, at centre: V3,
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
    func walled(_ solid: PreviewLayout.Solid, _ a: Int, _ b: Int) -> Bool {
        let corners = solid.corners
        return layout.touchesWall(corners[a], corners[b])
    }

    /// Headroom over a fixture: the lowest ceiling or bulkhead above it.
    func headroom(over solid: PreviewLayout.Solid) -> Float {
        Float((solid.corners + [solid.centre]).map { layout.clearHeight(above: $0) }.min() ?? layout.ceilingHeight)
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
        case .furnace, .waterHeater: range = 0...min(1.5, ceiling - 0.05)
        case .bedQueen, .bedSingle, .tubShower: range = 0...0.55
        case .sofa: range = 0...0.8
        case .stairs: range = 0...min(1.0, ceiling - 0.05)
        default: range = 0...0.9
        }
        block(.massing, in: node, x: -hw...hw, y: range, z: -hd...hd, chamfer: 0.01)
    }
}
