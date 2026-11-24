import SceneKit

@main
struct PreviewReferenceFloorTests {
    static func main() {
        guard let floor = PreviewReferenceFloor(),
              let charcoal = PreviewFinish.finish("floor.charcoal-24x24"),
              let grey = PreviewFinish.finish("wall.soft-grey") else {
            fatalError("Missing reference floor or test finishes")
        }
        let rooms = PreviewReferenceFloor.Room.allCases
        func snapshot() -> [String?] {
            rooms.flatMap { [floor.finishID(.floor, in: $0), floor.finishID(.wall, in: $0)] }
        }
        let before = snapshot()
        precondition(before.allSatisfy { $0 != nil })
        let camera = floor.camera.simdTransform
        let count = floor.bathroom.nodeCount
        floor.change(charcoal, in: .living)
        let flooring = snapshot()
        precondition(before.indices.filter { before[$0] != flooring[$0] } == [2])
        floor.change(grey, in: .bedroom)
        let paint = snapshot()
        precondition(paint.indices.filter { flooring[$0] != paint[$0] } == [5])
        precondition(floor.camera.simdTransform == camera && floor.bathroom.nodeCount == count)

        // The centre line crosses each physical opening, stays off jambs,
        // and uses the same clear bathroom crossing as the approved sample.
        let kitchen = floor.tour.first { $0.room == .kitchen }!.stops
        let living = Array(floor.tour.first { $0.room == .living }!.stops.suffix(2))
        let bedroom = floor.tour.first { $0.room == .bedroom }!.stops
        precondition(kitchen[0].z == kitchen[1].z && kitchen[0].x > -6.2 && kitchen[1].x < -6.3)
        precondition(kitchen.last!.fov >= 100, "kitchen tour should arrive at the wide view")
        precondition(living[0].x == living[1].x && living[1].z < -0.1)
        precondition((-5.0 ... -4.3).contains(living[0].x))
        precondition(bedroom[1].x == bedroom[2].x && bedroom[2].z > 1.7)
        precondition((-3.2 ... -2.5).contains(bedroom[1].x))
        let bath = floor.tour.first { $0.room == .bath }!.stops
        let entry = PreviewCamera.entry(in: floor.bathroom.layout)!
        for i in 0...300 {
            let t = Double(i) / 300
            let from = bath[bath.count - 2], to = bath[bath.count - 1]
            let point = PreviewLayout.Point(x: Double(from.x) + Double(to.x - from.x) * t,
                                            z: Double(from.z) + Double(to.z - from.z) * t)
            let offset = point - entry.wall.start
            let distance = offset.dot(entry.wall.inward)
            if (-0.15...0.05).contains(distance) {
                let along = offset.dot(entry.wall.direction)
                precondition(along > entry.void.from + 0.1 && along < entry.void.to - 0.1)
            }
            if distance >= 0 {
                precondition(floor.bathroom.layout.contains(point))
                precondition(!floor.bathroom.layout.isInsideSolid(point, margin: 0.10))
            }
        }
        var drawing = PreviewReferenceKitchen.room()
        let fridge = drawing.fixtures.firstIndex { $0.kind == .fridge }!
        drawing.fixtures[fridge].z = 1.35
        let edited = PreviewReferenceFloor(kitchen: drawing)!
        let fridgeID = drawing.fixtures[fridge].id
        let node = edited.scene.rootNode.childNode(withName: "fixture-\(fridgeID)", recursively: true)
        precondition(abs((node?.simdPosition.z ?? 0) - 1.35) < 0.001, "the joined scene uses the saved refrigerator position")
        let originalHallPaint = edited.finishID(.wall, in: .hall)
        edited.change(grey, in: .kitchen)
        precondition(edited.finishID(.wall, in: .kitchen) == grey.id)
        precondition(edited.finishID(.wall, in: .hall) == originalHallPaint)

        let start = PreviewReferenceFloor.Pose(x: 0, z: 0, heading: 170)
        let end = PreviewReferenceFloor.Pose(x: 2, z: 0, heading: -170)
        let half = start.interpolated(to: end, fraction: 0.5)
        precondition(half.x == 1 && half.heading == 180, "turn through the shortest angle")
        print("Independent finishes, saved appliance placement, and four door crossings passed.")
    }
}
