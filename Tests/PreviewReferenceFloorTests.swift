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
        // Leaving the kitchen, the camera faces the way it walks whenever it
        // is near the doorway. Turning there would swing the view across the
        // open door leaf and blank the picture.
        var previous = floor.tour.first { $0.room == .kitchen }!.stops.last!
        for stop in floor.tour.first(where: { $0.room == .living })!.stops {
            for step in 0...40 {
                let pose = previous.interpolated(to: stop, fraction: Double(step) / 40)
                let nearDoor = abs(pose.x - -6.30) < 0.9 && abs(pose.z - 0.8) < 0.6
                let turned = abs((pose.heading + 540).truncatingRemainder(dividingBy: 360) - 180)
                precondition(!nearDoor || pose.x > -6.0 || turned < 45,
                             "camera turns across the kitchen door at x \(pose.x), heading \(pose.heading)")
            }
            previous = stop
        }

        // The kitchen doorway is on the route, so its leaf is not drawn.
        let kitchenDoor = PreviewCamera.entry(in: floor.kitchen.layout)!.void.id
        let leaf = floor.scene.rootNode.childNode(withName: "door-\(kitchenDoor.uuidString)", recursively: true)
        precondition(leaf?.isHidden == true, "the kitchen door leaf would hang across the walk back to the hall")

        // One sun for a whole floor, however many rooms it joins: every
        // extra key or bounce would relight every other room.
        func lights(in scene: SCNScene) -> (directional: Int, casters: Int, perSurface: Int) {
            var all: [SCNLight] = []
            var categories: Set<Int> = []
            scene.rootNode.enumerateHierarchy { node, _ in
                if let light = node.light { all.append(light) }
                if node.geometry != nil { categories.insert(node.categoryBitMask) }
            }
            let most = categories.map { category in all.filter { $0.categoryBitMask & category != 0 }.count }.max() ?? 0
            return (all.filter { $0.type == .directional }.count, all.filter(\.castsShadow).count, most)
        }
        let sample = lights(in: floor.scene)
        precondition(sample.directional == 2 && sample.casters == 1, "the sample floor has one key and one bounce, found \(sample)")
        precondition(sample.perSurface <= 8, "no surface is lit by more than eight lights")

        // A saved floor: a hall and a bedroom drawn far from the origin,
        // sharing a wall with a door on each face.
        var hall = CornerRoom(corners: [.init(x: 10, z: 20), .init(x: 13, z: 20), .init(x: 13, z: 21.2), .init(x: 10, z: 21.2)],
                              ceilingHeightMeters: 2.3, ceilingHeightSource: .fieldMeasured)
        hall.openings = [.init(kind: .door, wallIndex: 2, offsetMeters: 1.0, widthMeters: 0.8, heightMeters: 2.03)]
        var bed = CornerRoom(corners: [.init(x: 10, z: 21.3), .init(x: 13, z: 21.3), .init(x: 13, z: 24.3), .init(x: 10, z: 24.3)],
                             ceilingHeightMeters: 2.3, ceilingHeightSource: .fieldMeasured)
        bed.openings = [.init(kind: .door, wallIndex: 0, offsetMeters: 1.2, widthMeters: 0.8, heightMeters: 2.03)]
        bed.floorType = .carpet
        var den = bed
        den.corners = den.corners.map { .init(x: $0.x + 20, z: $0.z) }
        let hallID = UUID(), bedID = UUID(), denID = UUID()
        guard let saved = SavedFloorWalkthrough(entries: [(hallID, "Hallway", hall), (bedID, "Bedroom", bed), (denID, "Den", den)]) else {
            fatalError("Two rooms that share a doorway did not join")
        }
        precondition(saved.walkthroughRooms.map(\.name) == ["Hallway", "Bedroom"], "the hall and bedroom join through their door")
        precondition(saved.connectionMessage?.contains("Den") == true, "a room with no shared doorway is named, not drawn")
        let joined = lights(in: saved.scene)
        precondition(joined.directional == 2 && joined.casters == 1, "a saved floor has one key and one bounce, found \(joined)")
        precondition(joined.perSurface <= 8, "no surface is lit by more than eight lights")
        precondition(saved.camera.camera?.wantsHDR == true && saved.camera.camera?.wantsExposureAdaptation == false,
                     "a saved floor is exposed like a single room")
        // Rooms sit where the drawing puts them.
        let bedroomGroup = saved.scene.rootNode.childNode(withName: "saved-room-\(bedID.uuidString)", recursively: false)
        precondition(bedroomGroup?.simdPosition == SIMD3<Float>(10, 0, 21.3), "the bedroom stands at its drawn position")
        // Each room opens with the floor its plan names: the bedroom was drawn with carpet.
        precondition(saved.finishID(.floor, roomID: bedID.uuidString) == "floor.carpet", "a carpeted bedroom is drawn with carpet")
        precondition(saved.finishID(.floor, roomID: hallID.uuidString) == PreviewFinish.looks[0].finishes[.floor],
                     "a room with no floor named takes the look's floor")
        // A floor change in one room and a paint change in the other touch nothing else.
        let hallBefore = (saved.finishID(.floor, roomID: hallID.uuidString), saved.finishID(.wall, roomID: hallID.uuidString))
        let pose = saved.camera.simdTransform
        saved.change(charcoal, roomID: bedID.uuidString)
        precondition(saved.finishID(.floor, roomID: bedID.uuidString) == charcoal.id)
        precondition(saved.finishID(.floor, roomID: hallID.uuidString) == hallBefore.0)
        saved.change(grey, roomID: hallID.uuidString)
        precondition(saved.finishID(.wall, roomID: hallID.uuidString) == grey.id && saved.finishID(.floor, roomID: hallID.uuidString) == hallBefore.0)
        precondition(saved.finishID(.wall, roomID: bedID.uuidString) != grey.id && saved.camera.simdTransform == pose)
        // Every standing point of the route is inside a room and clear of the walls.
        let layouts = [PreviewLayout(room: hall), PreviewLayout(room: bed)]
        for stop in saved.walkthroughLegs.flatMap(\.stops) + [saved.entrance] {
            let point = PreviewLayout.Point(x: Double(stop.x), z: Double(stop.z))
            let inRoom = layouts.contains { $0.contains(point - $0.origin) }
            let inDoorway = point.x > 11.1 && point.x < 11.9 && point.z > 21.15 && point.z < 21.35
            precondition(inRoom || inDoorway, "route point \(point) is outside every room")
        }
        // A mirror in a joined room reflects the floor it stands in. A
        // bathroom opens west onto a hall. From inside it the glass
        // shows the doorway, and through the doorway the hall: lit
        // surfaces, not the empty dark a single room has past its door.
        func darkShare(of floorScene: SCNScene) -> Double? {
            var glass: SCNMaterial?
            floorScene.rootNode.enumerateHierarchy { node, _ in
                if let material = node.geometry?.firstMaterial, material.name == "fixed.mirror",
                   material.lightingModel == .constant { glass = material }
            }
            guard let contents = glass?.diffuse.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
            let image = contents as! CGImage
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                          bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?
                    .draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            var dark = 0
            for i in stride(from: 0, to: bytes.count, by: 4) where max(bytes[i], bytes[i + 1], bytes[i + 2]) < 70 { dark += 1 }
            return Double(dark) / Double(bytes.count / 4)
        }
        let ensuite = PreviewReferenceRoom.bathroom()
        var lobby = CornerRoom(corners: [.init(x: 8.7, z: 20), .init(x: 9.9, z: 20), .init(x: 9.9, z: 21.6), .init(x: 8.7, z: 21.6)],
                               ceilingHeightMeters: 2.134, ceilingHeightSource: .fieldMeasured)
        lobby.openings = [.init(kind: .door, wallIndex: 1, offsetMeters: 0.688, widthMeters: 0.762, heightMeters: 1.930)]
        let lobbyID = UUID(), bathID = UUID()
        guard let suite = SavedFloorWalkthrough(entries: [(lobbyID, "Hall", lobby), (bathID, "Bathroom", ensuite)]) else {
            fatalError("A hall and a bathroom that share a doorway did not join")
        }
        precondition(suite.walkthroughRooms.count == 2, "the hall and the bathroom join through the bathroom door")
        precondition(darkShare(of: suite.scene) == nil, "a joined room has taken no reflection before anyone looks")
        let standing = SIMD3<Float>(11.8, 1.35, 21.3)
        suite.refreshMirrors(seenFrom: standing)
        guard let joinedDark = darkShare(of: suite.scene) else { fatalError("A mirror in a joined room took no reflection") }
        precondition(joinedDark < 0.05, "a joined mirror shows the hall through the doorway, found \(Int(joinedDark * 100)) percent dark")
        // The same bathroom on its own has nothing past its door.
        let alone = PreviewRoomScene(layout: PreviewLayout(room: ensuite), library: PreviewFinishLibrary(textureSize: 256))
        alone.refreshMirror(seenFrom: SIMD3<Float>(1.8, 1.35, 1.3))
        guard let aloneDark = darkShare(of: alone.scene) else { fatalError("A mirror in a single room took no reflection") }
        precondition(aloneDark > 0.2, "a single room's mirror shows the empty doorway, found \(Int(aloneDark * 100)) percent dark")
        // Far across the floor the mirror is left alone.
        let taken = suite.scene.rootNode.childNodes.count
        suite.change(grey, roomID: lobbyID.uuidString)
        suite.refreshMirrors(seenFrom: SIMD3<Float>(40, 1.35, 21.3))
        precondition(suite.scene.rootNode.childNodes.count == taken, "taking a reflection leaves nothing behind in the floor")
        print("Independent finishes, saved appliance placement, four door crossings, one sun per floor, a saved floor join, and a joined mirror passed.")
    }
}
