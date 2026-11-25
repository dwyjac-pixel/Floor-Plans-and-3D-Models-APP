import SceneKit

/// The reference bathroom's adjoining hall, in the bathroom's scene coordinates.
/// The bathroom shell already supplies the door opening and its lined reveals.
struct PreviewHallway {
    let start: PreviewCamera.Stop
    let end: PreviewCamera.Stop

    init?(room: PreviewRoomScene) {
        guard let entry = PreviewCamera.entry(in: room.layout),
              let doorway = room.stops.first(where: { $0.kind == .doorway }),
              let inside = room.stops.first(where: { $0.kind == .inside }),
              PreviewCamera.glideIsClear(from: doorway, to: inside, in: room.layout)
        else { return nil }

        let wall = entry.wall
        let center = wall.point(at: (entry.void.from + entry.void.to) / 2)
        let depth = 1.75
        let begin = center - wall.inward * 1.50
        start = .init(kind: .doorway, eye: .init(x: begin.x, y: doorway.eye.y, z: begin.z),
                      headingDegrees: atan2(wall.inward.z, wall.inward.x) * 180 / .pi,
                      pitchDegrees: doorway.pitchDegrees, horizontalFOV: doorway.horizontalFOV,
                      verticalShift: doorway.verticalShift)
        end = inside

        let up = room.up
        let side = room.v(wall.direction, 0)
        let inward = room.v(wall.inward, 0)
        let out = -inward
        let edge = room.v(wall.start, 0)
        let width = Float(wall.length)
        let height = Float(room.layout.ceilingHeight)
        let reach = Float(depth)
        let thickness = Float(PreviewLayout.wallThickness)
        let back = edge + out * reach
        let face = edge + out * thickness
        let group = SCNNode()
        group.name = "reference-hallway"
        room.scene.rootNode.addChildNode(group)

        func surface(_ mesh: PreviewMesh, color: String, roughness: CGFloat = 0.85) {
            let geometry = mesh.geometry()
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = PreviewTextures.color(color)
            material.roughness.contents = roughness
            geometry.firstMaterial = material
            let node = SCNNode(geometry: geometry)
            node.castsShadow = false
            group.addChildNode(node)
        }

        var floor = PreviewMesh(), ceiling = PreviewMesh(), paint = PreviewMesh(), trim = PreviewMesh()
        floor.rect(origin: edge, u: side * width, v: out * reach, facing: up)
        ceiling.rect(origin: edge + up * height, u: side * width, v: out * reach, facing: -up)
        paint.rect(origin: edge, u: out * reach, v: up * height, facing: side)
        paint.rect(origin: edge + side * width, u: out * reach, v: up * height, facing: -side)
        paint.rect(origin: back, u: side * width, v: up * height, facing: inward)
        // The hall-facing finish shares the bathroom opening's edges and head.
        for cell in room.layout.cells(for: wall) {
            paint.rect(origin: face + side * Float(cell.u0) + up * Float(cell.v0),
                       u: side * Float(cell.u1 - cell.u0), v: up * Float(cell.v1 - cell.v0), facing: out)
        }
        let left = Float(entry.void.from), right = Float(entry.void.to), head = Float(entry.void.head)
        let casing: Float = 0.06
        for u in [left - casing, right] {
            trim.box(origin: face + side * u, u: side * casing, v: up * (head + casing), w: out * 0.012)
        }
        trim.box(origin: face + side * left + up * head, u: side * (right - left),
                 v: up * casing, w: out * 0.012)
        surface(floor, color: "9B8065")
        surface(ceiling, color: "E9E7DF")
        surface(paint, color: "A8B4BA")
        surface(trim, color: "EEECE5")
    }

    /// A continuous crossing with a smooth start and finish.
    func camera(at fraction: Double) -> PreviewCamera.Stop {
        let t = min(1, max(0, fraction))
        let s = t * t * (3 - 2 * t)
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * s }
        return .init(kind: .inside,
                     eye: .init(x: mix(start.eye.x, end.eye.x), y: mix(start.eye.y, end.eye.y),
                                z: mix(start.eye.z, end.eye.z)),
                     headingDegrees: mix(start.headingDegrees, end.headingDegrees),
                     pitchDegrees: mix(start.pitchDegrees, end.pitchDegrees),
                     horizontalFOV: mix(start.horizontalFOV, end.horizontalFOV),
                     verticalShift: mix(start.verticalShift, end.verticalShift))
    }
}
