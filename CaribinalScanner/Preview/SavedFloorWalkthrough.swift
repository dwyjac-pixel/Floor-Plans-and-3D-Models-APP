import SceneKit

struct WalkthroughRoom: Identifiable {
    let id: String
    let name: String
}

struct WalkthroughLeg {
    let room: WalkthroughRoom
    let stops: [PreviewReferenceFloor.Pose]
}

protocol FloorWalkthroughScene: AnyObject {
    var scene: SCNScene { get }
    var camera: SCNNode { get }
    var entrance: PreviewReferenceFloor.Pose { get }
    var walkthroughRooms: [WalkthroughRoom] { get }
    var walkthroughLegs: [WalkthroughLeg] { get }
    var connectionMessage: String? { get }
    /// Every dimension a default stood in for, across the rooms shown.
    var assumptions: [PreviewLayout.Assumption] { get }
    func finishID(_ slot: PreviewFinish.Slot, roomID: String) -> String?
    func change(_ finish: PreviewFinish.Finish, roomID: String)
}

extension FloorWalkthroughScene {
    func placeCamera(_ pose: PreviewReferenceFloor.Pose) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        camera.simdPosition = SIMD3(pose.x, Float(pose.y), pose.z)
        camera.simdOrientation = PreviewRoomScene.orientation(headingDegrees: pose.heading, pitchDegrees: pose.pitch)
        SCNTransaction.commit()
        PreviewRoomScene.aim(camera.camera, for: .init(kind: .inside,
            eye: .init(x: Double(pose.x), y: pose.y, z: Double(pose.z)),
            headingDegrees: pose.heading, pitchDegrees: pose.pitch,
            horizontalFOV: pose.fov, verticalShift: 0.22))
    }
}

extension PreviewReferenceFloor: FloorWalkthroughScene {
    var walkthroughRooms: [WalkthroughRoom] { Room.allCases.map { .init(id: $0.rawValue, name: $0.rawValue) } }
    var walkthroughLegs: [WalkthroughLeg] {
        tour.map { .init(room: .init(id: $0.room.rawValue, name: $0.room.rawValue), stops: $0.stops) }
    }
    var connectionMessage: String? { nil }
    var assumptions: [PreviewLayout.Assumption] { [] }

    func finishID(_ slot: PreviewFinish.Slot, roomID: String) -> String? {
        Room(rawValue: roomID).flatMap { finishID(slot, in: $0) }
    }

    func change(_ finish: PreviewFinish.Finish, roomID: String) {
        if let room = Room(rawValue: roomID) { change(finish, in: room) }
    }
}

/// Joins the saved rooms in their original plan coordinates. A connection
/// requires overlapping floor-level openings on two opposing wall faces.
final class SavedFloorWalkthrough: FloorWalkthroughScene {
    typealias Point = PreviewLayout.Point
    typealias Pose = PreviewReferenceFloor.Pose

    private struct Room {
        let label: WalkthroughRoom
        let layout: PreviewLayout

        func clear(_ point: Point) -> Bool {
            let local = point - layout.origin
            return layout.contains(local) && layout.clearance(from: local) > 0.11
                && !layout.isInsideSolid(local, margin: 0.10)
        }

        func route(from: Point, to: Point) -> [Point]? {
            func direct(_ a: Point, _ b: Point) -> Bool {
                let distance = (b - a).length
                let count = max(1, Int(ceil(distance / 0.08)))
                return (0...count).allSatisfy { clear(a + (b - a) * (Double($0) / Double(count))) }
            }
            if direct(from, to) { return [to] }
            // Use a bounded grid for rooms where a fixture or a corner
            // blocks the straight line. Then remove unnecessary waypoints.
            let minX = layout.floor.map(\.x).min() ?? 0, maxX = layout.floor.map(\.x).max() ?? 0
            let minZ = layout.floor.map(\.z).min() ?? 0, maxZ = layout.floor.map(\.z).max() ?? 0
            let step = max(0.20, max(maxX - minX, maxZ - minZ) / 45)
            let nx = Int((maxX - minX) / step), nz = Int((maxZ - minZ) / step)
            guard nx > 0, nz > 0 else { return nil }
            func point(_ id: Int) -> Point {
                layout.origin + .init(x: minX + (Double(id % nx) + 0.5) * step,
                                      z: minZ + (Double(id / nx) + 0.5) * step)
            }
            let cells = 0..<(nx * nz)
            let start = cells.filter { (point($0) - from).length < step * 2 && direct(from, point($0)) }
                .min { (point($0) - from).length < (point($1) - from).length }
            guard let start else { return nil }
            var queue = [start], next = 0
            var parent = [start: start]
            while next < queue.count {
                let cell = queue[next]
                next += 1
                let current = point(cell)
                if direct(current, to) {
                    var path = [to, current], index = cell
                    while index != start {
                        index = parent[index]!
                        path.append(point(index))
                    }
                    var simplified: [Point] = []
                    var last = from
                    while !path.isEmpty {
                        guard let target = path.firstIndex(where: { direct(last, $0) }) else { return nil }
                        last = path[target]
                        simplified.append(last)
                        path.removeSubrange(target...)
                    }
                    return simplified
                }
                let x = cell % nx, z = cell / nx
                for (dx, dz) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let xx = x + dx, zz = z + dz
                    guard xx >= 0, xx < nx, zz >= 0, zz < nz else { continue }
                    let child = zz * nx + xx
                    guard parent[child] == nil, direct(current, point(child)) else { continue }
                    parent[child] = cell
                    queue.append(child)
                }
            }
            return nil
        }
    }

    private struct Door {
        let wall: PreviewLayout.WallFace
        let opening: PreviewLayout.Void
        let origin: Point

        func position(_ offset: Double) -> Point { origin + wall.point(at: offset) }
    }

    private struct Link {
        let from: Int
        let to: Int
        let entry: Point
        let exit: Point
        let openingA: UUID
        let openingB: UUID
        let sillA: Point
        let sillB: Point
        let width: Double
    }

    let scene = SCNScene()
    let camera = SCNNode()
    let entrance: Pose
    let walkthroughRooms: [WalkthroughRoom]
    let walkthroughLegs: [WalkthroughLeg]
    let connectionMessage: String?
    let assumptions: [PreviewLayout.Assumption]
    private var models: [String: PreviewRoomScene] = [:]
    private var selections: [String: PreviewFinish.Selection] = [:]

    init?(entries: [(id: UUID, name: String, room: CornerRoom)]) {
        let rooms: [Room] = entries.compactMap { entry in
            let layout = PreviewLayout(room: entry.room)
            guard layout.problems.isEmpty else { return nil }
            return Room(label: .init(id: entry.id.uuidString, name: entry.name), layout: layout)
        }
        guard rooms.count >= 2 else { return nil }
        let doors = rooms.map { room in
            room.layout.walls.flatMap { wall in
                wall.voids.filter { $0.sill < 0.05 && $0.width >= 0.55 && $0.head >= 1.45 }
                    .map { Door(wall: wall, opening: $0, origin: room.layout.origin) }
            }
        }
        var links: [Link] = []
        for a in rooms.indices {
            for b in rooms.indices where a < b {
                for left in doors[a] {
                    for right in doors[b] where left.wall.inward.dot(right.wall.inward) < -0.99 {
                        let origin = left.position(0)
                        let rightCentre = right.position(right.opening.centre)
                        let gap = (rightCentre - origin).dot(left.wall.inward)
                        guard (-0.24...0.02).contains(gap) else { continue }
                        let axis = left.wall.direction
                        let rightOffsets = [right.opening.from, right.opening.to].map { (right.position($0) - origin).dot(axis) }
                        let low = max(left.opening.from, min(rightOffsets[0], rightOffsets[1]))
                        let high = min(left.opening.to, max(rightOffsets[0], rightOffsets[1]))
                        guard high - low >= 0.50 else { continue }
                        let sillA = left.position((low + high) / 2)
                        let sillB = sillA + left.wall.inward * gap
                        let insideA = sillA + left.wall.inward * 0.31
                        let insideB = sillB + right.wall.inward * 0.31
                        guard rooms[a].clear(insideA), rooms[b].clear(insideB) else { continue }
                        links.append(.init(from: a, to: b, entry: insideA, exit: insideB,
                                           openingA: left.opening.id, openingB: right.opening.id,
                                           sillA: sillA, sillB: sillB, width: high - low))
                        links.append(.init(from: b, to: a, entry: insideB, exit: insideA,
                                           openingA: right.opening.id, openingB: left.opening.id,
                                           sillA: sillB, sillB: sillA, width: high - low))
                    }
                }
            }
        }
        guard let start = rooms.indices.first(where: { index in
            rooms[index].label.name.localizedCaseInsensitiveContains("hall") && links.contains { $0.from == index }
        }) ?? links.first?.from else { return nil }

        func pose(_ point: Point, facing target: Point, in room: Room, fov: Double = 78, pitch: Double = 0) -> Pose {
            let delta = target - point
            let y = PreviewCamera.eyeHeight(for: room.layout, at: point - room.layout.origin)
            return Pose(x: Float(point.x), z: Float(point.z), heading: atan2(delta.z, delta.x) * 180 / .pi,
                        pitch: pitch, fov: fov, y: y)
        }
        func orderedLinks(from index: Int) -> [Link] {
            links.filter { $0.from == index }.sorted {
                let a = rooms[$0.to].layout.solids.contains { $0.kind.category == .kitchen }
                let b = rooms[$1.to].layout.solids.contains { $0.kind.category == .kitchen }
                return a && !b
            }
        }
        let first = orderedLinks(from: start)[0]
        let hallStart = first.entry + (first.entry - first.sillA) * 1.8
        let firstPoint = rooms[start].clear(hallStart) ? hallStart : first.entry
        entrance = pose(firstPoint, facing: first.exit, in: rooms[start])
        var visited: Set<Int> = [start]
        var legs: [WalkthroughLeg] = []
        var used: [Link] = []
        var lastArrival = 0
        func visit(_ index: Int, from startPoint: Point) -> Point {
            var position = startPoint
            for link in orderedLinks(from: index) where !visited.contains(link.to) {
                guard let path = rooms[index].route(from: position, to: link.entry) else { continue }
                visited.insert(link.to)
                used.append(link)
                var stops = zip(path, Array(path.dropFirst()) + [link.exit]).map {
                    pose($0, facing: $1, in: rooms[index])
                }
                let destination = rooms[link.to]
                stops.append(pose(link.exit, facing: link.exit + (link.exit - link.entry), in: destination))
                var arrival = link.exit
                if let wide = PreviewCamera.stops(for: destination.layout).first(where: { $0.kind == .kitchenWide }),
                   let approach = destination.route(from: arrival, to: wide.plan + destination.layout.origin) {
                    let forward = wide.forward
                    stops += approach.map { pose($0, facing: $0 + forward, in: destination,
                                                fov: wide.horizontalFOV, pitch: wide.pitchDegrees) }
                    arrival = wide.plan + destination.layout.origin
                }
                legs.append(.init(room: destination.label, stops: stops))
                lastArrival = legs.count
                let returned = visit(link.to, from: arrival)
                guard let back = destination.route(from: returned, to: link.exit) else { return position }
                legs.append(.init(room: rooms[index].label, stops: back.map { pose($0, facing: link.entry, in: destination) }
                    + [pose(link.entry, facing: link.entry + (link.entry - link.exit), in: rooms[index])]))
                position = link.entry
            }
            return position
        }
        _ = visit(start, from: firstPoint)
        legs = Array(legs.prefix(lastArrival))
        guard !used.isEmpty else { return nil }
        let connected = [rooms[start].label] + rooms.indices.filter { $0 != start && visited.contains($0) }.map { rooms[$0].label }
        walkthroughRooms = connected
        walkthroughLegs = legs
        assumptions = visited.sorted().flatMap { rooms[$0].layout.assumptions }
        connectionMessage = visited.count == entries.count ? nil
            : "Rooms outside this route: \(entries.filter { entry in !connected.contains { $0.id == entry.id.uuidString } }.map(\.name).joined(separator: ", ")). Check their outlines, fixture clearances, and matching doors or cased openings in Edit Proposed Layout, then save a new revision."

        let library = PreviewFinishLibrary(textureSize: 512)
        scene.background.contents = PreviewTextures.color("26282B")
        let environment = PreviewTextures.environment(for: rooms[start].layout, lamps: [])
        scene.lightingEnvironment.contents = environment.image
        scene.lightingEnvironment.intensity = CGFloat(environment.intensity)
        let doorsToOpen = Set(used.flatMap { [$0.openingA, $0.openingB] })
        for (order, index) in visited.sorted().enumerated() {
            let room = rooms[index]
            // Each room opens with the floor the plan names for it.
            let model = PreviewRoomScene(layout: room.layout, selection: .starting(for: room.layout), library: library)
            model.overheadHidden.isHidden = false
            // One key and one bounce for the whole floor, from the first room.
            let group = model.join(scene, named: "saved-room-\(room.label.id)", index: order, bringSun: order == 0)
            group.simdPosition = SIMD3(Float(room.layout.origin.x), 0, Float(room.layout.origin.z))
            for id in doorsToOpen {
                group.childNode(withName: "door-\(id.uuidString)", recursively: true)?.isHidden = true
            }
            models[room.label.id] = model
            selections[room.label.id] = model.selection
        }
        for link in used {
            let delta = link.sillB - link.sillA
            guard delta.length > 0.005 else { continue }
            let across = Point(x: -delta.z, z: delta.x) * (link.width / (2 * delta.length))
            let edge = link.sillA - across
            var mesh = PreviewMesh()
            mesh.rect(origin: SIMD3(Float(edge.x), 0, Float(edge.z)),
                      u: SIMD3(Float(across.x * 2), 0, Float(across.z * 2)),
                      v: SIMD3(Float(delta.x), 0, Float(delta.z)), facing: SIMD3(0, 1, 0))
            let geometry = mesh.geometry()
            geometry.firstMaterial = library.material("fixed.trim")
            scene.rootNode.addChildNode(SCNNode(geometry: geometry))
        }
        // The same exposure and shading as a single room, so a finish
        // chosen here looks the same in Preview Renovation.
        let lens = SCNCamera()
        PreviewRoomScene.configure(lens)
        camera.camera = lens
        scene.rootNode.addChildNode(camera)
        placeCamera(entrance)
    }

    func finishID(_ slot: PreviewFinish.Slot, roomID: String) -> String? {
        models[roomID]?.shownFinishes[slot]
    }

    func change(_ finish: PreviewFinish.Finish, roomID: String) {
        guard var selection = selections[roomID], let model = models[roomID] else { return }
        selection.overrides[finish.slot] = finish.id
        selections[roomID] = selection
        model.apply(selection)
    }
}
