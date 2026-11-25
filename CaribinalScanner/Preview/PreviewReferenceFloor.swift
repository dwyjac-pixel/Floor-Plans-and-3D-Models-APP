import SceneKit
import simd

/// One reference level in metres. The bathroom keeps its measured shell;
/// the hall and side rooms share their adjoining partitions.
final class PreviewReferenceFloor {
    enum Room: String, CaseIterable, Identifiable {
        case hall = "Hallway", living = "Living Room", bedroom = "Bedroom", bath = "Bathroom", kitchen = "Kitchen"
        var id: Self { self }
    }

    struct Pose {
        let x: Float
        let z: Float
        let heading: Double
        var pitch: Double = 0
        var fov = PreviewCamera.interiorFOV
        var y = PreviewCamera.standingEye

        func interpolated(to end: Pose, fraction t: Double) -> Pose {
            let eased = t * t * (3 - 2 * t)
            let turn = (end.heading - heading + 540).truncatingRemainder(dividingBy: 360) - 180
            return Pose(x: x + (end.x - x) * Float(eased), z: z + (end.z - z) * Float(eased),
                        heading: heading + turn * eased, pitch: pitch + (end.pitch - pitch) * eased,
                        fov: fov + (end.fov - fov) * eased, y: y + (end.y - y) * eased)
        }
    }

    struct Leg {
        let room: Room
        let stops: [Pose]
    }

    let bathroom: PreviewRoomScene
    let kitchen: PreviewRoomScene
    private let kitchenOpening: ClosedRange<Float>
    private var kitchenSelection = PreviewFinish.Selection()
    let entrance: Pose
    let tour: [Leg]
    private var finishes: [Room: [PreviewFinish.Slot: SCNGeometry]] = [:]
    private var bathroomSelection = PreviewFinish.Selection()

    var scene: SCNScene { bathroom.scene }
    var camera: SCNNode { bathroom.cameraNode }

    init?(kitchen drawing: CornerRoom = PreviewReferenceKitchen.room()) {
        let library = PreviewFinishLibrary(textureSize: 512)
        let bath = PreviewRoomScene(layout: PreviewLayout(room: PreviewReferenceRoom.bathroom()), library: library)
        guard let hall = PreviewHallway(room: bath) else { return nil }
        let layout = PreviewLayout(room: drawing)
        guard layout.problems.isEmpty, let door = PreviewCamera.entry(in: layout) else { return nil }
        let centre = door.wall.point(at: door.void.centre)
        // The west end of the hall meets the kitchen's actual doorway.
        // Kitchens whose outline wraps behind that wall need a different hall layout.
        guard layout.floor.allSatisfy({ ($0 - centre).dot(door.wall.inward) >= -0.005 }) else { return nil }
        let halfDoor = Float(door.void.width) / 2
        guard halfDoor > 0.22, halfDoor < 0.79 else { return nil }
        kitchenOpening = (0.8 - halfDoor)...(0.8 + halfDoor)
        kitchen = PreviewRoomScene(layout: layout, library: library)
        bathroom = bath
        let rotation = Double.pi - atan2(door.wall.inward.z, door.wall.inward.x)
        let c = cos(rotation), s = sin(rotation)
        func map(_ point: PreviewLayout.Point) -> PreviewLayout.Point {
            let delta = point - centre
            return .init(x: -6.30 + delta.x * c - delta.z * s, z: 0.8 + delta.x * s + delta.z * c)
        }
        let entry = centre + door.wall.inward * 0.42
        guard layout.contains(entry), !layout.isInsideSolid(entry, margin: 0.13) else { return nil }
        let inside = map(entry)
        let crossesDoor = Pose(x: Float(inside.x), z: Float(inside.z), heading: 180, fov: 86)
        var kitchenStops = [Pose(x: -5.92, z: 0.8, heading: 180, fov: 78), crossesDoor]
        var kitchenExit: [Pose] = []
        if let wide = kitchen.stops.first(where: { $0.kind == .kitchenWide }),
           (0...40).allSatisfy({ step in
               let point = entry + (wide.plan - entry) * (Double(step) / 40)
               return layout.contains(point) && !layout.isInsideSolid(point, margin: 0.13)
           }) {
            let position = map(wide.plan)
            let widePose = Pose(x: Float(position.x), z: Float(position.z),
                                heading: wide.headingDegrees + rotation * 180 / .pi,
                                pitch: wide.pitchDegrees, fov: wide.horizontalFOV)
            kitchenStops.append(widePose)
            // Turn toward the doorway before walking out. Turning at the
            // door itself swings the view across the open door leaf, which
            // then fills the whole picture.
            let out = atan2(Double(crossesDoor.z - widePose.z), Double(crossesDoor.x - widePose.x)) * 180 / .pi
            kitchenExit.append(Pose(x: widePose.x, z: widePose.z, heading: out, fov: 82))
            kitchenExit.append(Pose(x: crossesDoor.x, z: crossesDoor.z, heading: 0, fov: 82))
        }
        kitchenExit.append(Pose(x: -5.92, z: 0.8, heading: 0))
        entrance = Pose(x: -4.90, z: 0.8, heading: 180)
        tour = [
            .init(room: .kitchen, stops: kitchenStops),
            .init(room: .living, stops: kitchenExit + [.init(x: -4.65, z: 0.8, heading: -90),
                                                       .init(x: -4.65, z: -1.32, heading: -65, fov: 92)]),
            .init(room: .bedroom, stops: [.init(x: -4.65, z: 0.8, heading: 0),
                                          .init(x: -2.85, z: 0.8, heading: 90),
                                          .init(x: -2.85, z: 2.8, heading: 50)]),
            .init(room: .bath, stops: [.init(x: -2.85, z: 0.8, heading: 0),
                                      .init(x: -1.85, z: Float(hall.start.eye.z), heading: 0),
                                      .init(x: Float(hall.start.eye.x), z: Float(hall.start.eye.z), heading: hall.start.headingDegrees),
                                      .init(x: Float(hall.end.eye.x), z: Float(hall.end.eye.z), heading: hall.end.headingDegrees)])
        ]

        // Extend the tested hall. Its end cap gives way to this corridor.
        bath.scene.rootNode.childNode(withName: "reference-hallway", recursively: false)?.removeFromParentNode()
        build()
        // The bathroom's key and bounce light the whole floor. The kitchen
        // brings only its own ceiling lights.
        let kitchenGroup = kitchen.join(scene, named: "joined-kitchen", index: 1, bringSun: false)
        let origin = map(.init(x: 0, z: 0))
        kitchenGroup.simdPosition = SIMD3(Float(origin.x), 0, Float(origin.z))
        kitchenGroup.simdEulerAngles.y = -Float(rotation)
        // A doorway the tour walks through is shown without its leaf, as on
        // a saved floor. Standing open, this one hangs across the way from
        // the wide view back to the hall and blanks the picture.
        kitchenGroup.childNode(withName: "door-\(door.void.id.uuidString)", recursively: true)?.isHidden = true
        placeCamera(entrance)
    }

    func change(_ finish: PreviewFinish.Finish, in room: Room) {
        guard finish.slot == .floor || finish.slot == .wall else { return }
        if room == .bath {
            bathroomSelection.overrides[finish.slot] = finish.id
            bathroom.apply(bathroomSelection)
        } else if room == .kitchen {
            kitchenSelection.overrides[finish.slot] = finish.id
            kitchen.apply(kitchenSelection)
        } else {
            let material = bathroom.library.material(finish.id)
            finishes[room]?[finish.slot]?.firstMaterial = material
            if room == .hall, finish.slot == .wall { hallEntryFace?.firstMaterial = material }
        }
    }

    func finishID(_ slot: PreviewFinish.Slot, in room: Room) -> String? {
        if room == .bath { return bathroom.shownFinishes[slot] }
        if room == .kitchen { return kitchen.shownFinishes[slot] }
        return finishes[room]?[slot]?.firstMaterial?.name
    }

    private func build() {
        typealias V = SIMD3<Float>
        let h = Float(bathroom.layout.ceilingHeight)
        let up = V(0, 1, 0)
        let group = SCNNode()
        group.name = "reference-level"
        scene.rootNode.addChildNode(group)

        func add(_ mesh: PreviewMesh, material: SCNMaterial) -> SCNGeometry {
            let geometry = mesh.geometry()
            geometry.firstMaterial = material
            let node = SCNNode(geometry: geometry)
            node.castsShadow = false
            group.addChildNode(node)
            return geometry
        }

        func solid(_ low: V, _ high: V, color: String) {
            var mesh = PreviewMesh()
            mesh.box(from: low, to: high)
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = PreviewTextures.color(color)
            material.roughness.contents = 0.72
            _ = add(mesh, material: material)
        }

        // These holes use the same extents on both faces. Reveals bridge
        // the 100 mm partition, and jambs stay outside of the clear opening.
        let livingDoor: ClosedRange<Float> = -5.10 ... -4.20
        let bedroomDoor: ClosedRange<Float> = -3.30 ... -2.40
        let head: Float = 1.93

        func room(_ id: Room, x: ClosedRange<Float>, z: ClosedRange<Float>,
                  south: ClosedRange<Float>? = nil, north: ClosedRange<Float>? = nil) {
            let x0 = x.lowerBound, x1 = x.upperBound, z0 = z.lowerBound, z1 = z.upperBound
            var floor = PreviewMesh(), ceiling = PreviewMesh(), wall = PreviewMesh()
            floor.rect(origin: V(x0, 0, z0), u: V(x1 - x0, 0, 0), v: V(0, 0, z1 - z0), facing: up)
            ceiling.rect(origin: V(x0, h, z0), u: V(x1 - x0, 0, 0), v: V(0, 0, z1 - z0), facing: -up)
            func west(_ low: Float, _ high: Float, bottom: Float = 0) {
                wall.rect(origin: V(x0, bottom, low), u: V(0, 0, high - low),
                          v: up * (h - bottom), facing: V(1, 0, 0))
            }
            if id == .hall {
                west(z0, kitchenOpening.lowerBound)
                west(kitchenOpening.upperBound, z1)
                west(kitchenOpening.lowerBound, kitchenOpening.upperBound,
                     bottom: min(h, Float(PreviewCamera.entry(in: kitchen.layout)?.void.head ?? 1.93)))
                floor.rect(origin: V(-6.30, 0, kitchenOpening.lowerBound), u: V(0.10, 0, 0),
                           v: V(0, 0, kitchenOpening.upperBound - kitchenOpening.lowerBound), facing: up)
            } else {
                west(z0, z1)
            }
            if id != .hall {
                wall.rect(origin: V(x1, 0, z0), u: V(0, 0, z1 - z0), v: up * h, facing: V(-1, 0, 0))
            }
            for (edge, opening, normal) in [(z0, south, V(0, 0, 1)), (z1, north, V(0, 0, -1))] {
                func face(_ a: Float, _ b: Float, bottom: Float = 0) {
                    wall.rect(origin: V(a, bottom, edge), u: V(b - a, 0, 0),
                              v: up * (h - bottom), facing: normal)
                }
                if let opening {
                    face(x0, opening.lowerBound)
                    face(opening.upperBound, x1)
                    face(opening.lowerBound, opening.upperBound, bottom: head)
                } else { face(x0, x1) }
            }
            let floorID = id == .living ? "floor.greige-12x24" : "floor.grey-12x24"
            let wallID = id == .bedroom ? "wall.sage" : "wall.warm-white"
            finishes[id] = [
                .floor: add(floor, material: bathroom.library.material(floorID)),
                .wall: add(wall, material: bathroom.library.material(wallID))
            ]
            _ = add(ceiling, material: bathroom.library.material("fixed.ceiling"))
        }

        room(.hall, x: -6.2 ... 0, z: 0 ... 1.6, south: livingDoor, north: bedroomDoor)
        room(.living, x: -6.2 ... -1.7, z: -3.6 ... -0.1, north: livingDoor)
        room(.bedroom, x: -4.5 ... -0.1, z: 1.7 ... 4.65, south: bedroomDoor)

        var reveals = PreviewMesh()
        for (door, z) in [(livingDoor, Float(-0.1)), (bedroomDoor, Float(1.6))] {
            let a = door.lowerBound, b = door.upperBound
            for (edge, normal) in [(a, V(1, 0, 0)), (b, V(-1, 0, 0))] {
                reveals.rect(origin: V(edge, 0, z), u: V(0, 0, 0.1), v: up * head, facing: normal)
            }
            reveals.rect(origin: V(a, head, z), u: V(b - a, 0, 0), v: V(0, 0, 0.1), facing: -up)
            reveals.rect(origin: V(a, 0, z), u: V(b - a, 0, 0), v: V(0, 0, 0.1), facing: up)
        }
        // Paint the hall-facing side of the bathroom partition using the
        // bathroom layout's actual opening, including its head and jambs.
        let entry = PreviewCamera.entry(in: bathroom.layout)!
        var hallFace = PreviewMesh()
        for cell in bathroom.layout.cells(for: entry.wall) {
            let p = entry.wall.point(at: cell.u0) - entry.wall.inward * PreviewLayout.wallThickness
            hallFace.rect(origin: bathroom.v(p, cell.v0),
                          u: bathroom.v(entry.wall.direction, 0) * Float(cell.u1 - cell.u0),
                          v: up * Float(cell.v1 - cell.v0), facing: -bathroom.v(entry.wall.inward, 0))
        }
        if let hallWalls = finishes[.hall]?[.wall]?.firstMaterial {
            // Keep this mesh in the same finish selection as the hall walls.
            hallEntryFace = add(hallFace, material: hallWalls)
        }
        _ = add(reveals, material: bathroom.library.material("fixed.trim"))

        // Reference furniture stays outside the walked route.
        solid(V(-5.85, 0, -3.3), V(-3.15, 0.42, -2.42), color: "B5A791")
        solid(V(-5.85, 0.42, -3.3), V(-3.15, 0.83, -3.09), color: "B5A791")
        solid(V(-5.35, 0, -2.12), V(-3.9, 0.36, -1.72), color: "896A51")
        solid(V(-2.04, 0, 2.54), V(-0.45, 0.33, 4.5), color: "896A51")
        solid(V(-2.02, 0.33, 2.56), V(-0.47, 0.58, 4.44), color: "D9D2C4")
        solid(V(-2.04, 0.33, 4.43), V(-0.45, 0.94, 4.52), color: "896A51")
    }

    private var hallEntryFace: SCNGeometry?
}
