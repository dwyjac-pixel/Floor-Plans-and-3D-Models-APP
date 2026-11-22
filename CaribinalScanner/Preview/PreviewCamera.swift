import Foundation

/// Where the preview camera may stand, worked out from the plan alone.
///
/// Stops are plain values in scene space (see `PreviewLayout`), so the same
/// numbers drive the live view, the exported still and the tests. The
/// camera never roams: it glides between stops, which is what keeps it out
/// of walls and fixtures.
enum PreviewCamera {
    enum Kind: String, CaseIterable {
        case doorway
        case inside
        case overhead

        /// Button title.
        var title: String {
            switch self {
            case .doorway: "Doorway"
            case .inside: "Inside"
            case .overhead: "Overhead"
            }
        }
    }

    struct Vector: Equatable {
        var x: Double
        var y: Double
        var z: Double
    }

    struct Stop: Equatable {
        let kind: Kind
        let eye: Vector
        /// Compass heading of the view in the plan, degrees from +x toward +z.
        let headingDegrees: Double
        /// Negative looks down. Standing stops stay level so walls and
        /// door frames stay upright; the overhead stop is straight down.
        let pitchDegrees: Double
        /// Horizontal field of view for the fixed 4:3 picture.
        let horizontalFOV: Double
        /// How far the picture is slid down the lens, as a share of half
        /// its height: the architectural photographer's shift, which shows
        /// more floor and less ceiling without tipping the camera.
        let verticalShift: Double

        /// Tangents of the lowest and highest sight lines in the picture.
        var verticalReach: (down: Double, up: Double) {
            let half = tan(horizontalFOV / 2 * .pi / 180) / PreviewCamera.aspect
            return (half * (1 + verticalShift), half * (1 - verticalShift))
        }

        var plan: PreviewLayout.Point { .init(x: eye.x, z: eye.z) }
        var forward: PreviewLayout.Point {
            let r = headingDegrees * .pi / 180
            return .init(x: cos(r), z: sin(r))
        }
    }

    /// Width over height of every preview picture, on screen and exported.
    static let aspect = 4.0 / 3.0
    /// About a 26 mm lens on a full-frame camera: wide enough for a small
    /// room, short of the stretched look of an ultra-wide.
    static let interiorFOV = 70.0
    static let interiorPitch = 0.0
    static let interiorShift = 0.42
    static let standingEye = 1.35
    static let headroom = 0.45

    static func eyeHeight(for layout: PreviewLayout, at point: PreviewLayout.Point) -> Double {
        max(0.9, min(standingEye, layout.clearHeight(above: point) - headroom))
    }

    /// Every stop this room supports, doorway first. A room with no door
    /// has no doorway stop; a room with no free floor has no inside stop.
    static func stops(for layout: PreviewLayout) -> [Stop] {
        guard layout.problems.isEmpty, layout.floor.count >= 3 else { return [] }
        var stops: [Stop] = []
        let entry = doorway(in: layout)
        if let entry { stops.append(entry) }
        if let second = inside(in: layout, awayFrom: entry?.plan) { stops.append(second) }
        stops.append(overhead(of: layout))
        return stops
    }

    /// The door the client walks in through: the first hinged door on the
    /// outline, or failing that any floor-level opening.
    static func entry(in layout: PreviewLayout) -> (wall: PreviewLayout.WallFace, void: PreviewLayout.Void)? {
        let floorLevel = layout.walls.flatMap { wall in wall.voids.filter { $0.sill < 0.05 }.map { (wall, $0) } }
        return floorLevel.first { $0.1.kind == .door } ?? floorLevel.first
    }

    /// Points on a fixture used to judge whether it is in the picture.
    private static func samples(of solid: PreviewLayout.Solid) -> [PreviewLayout.Point] {
        solid.corners + [solid.centre]
    }

    /// Share of the room's floor-standing fixtures inside the horizontal
    /// field of view from `eye`, counting only points farther than
    /// `nearest` and, when given, only sight lines `through` a doorway.
    static func coverage(of layout: PreviewLayout, from eye: PreviewLayout.Point, headingDegrees: Double,
                         fov: Double = interiorFOV, nearest: Double = 0.35,
                         through door: (wall: PreviewLayout.WallFace, void: PreviewLayout.Void)? = nil) -> Double {
        let forward = PreviewLayout.Point(x: cos(headingDegrees * .pi / 180), z: sin(headingDegrees * .pi / 180))
        let limit = cos((fov / 2 - 2) * .pi / 180)
        var seen = 0.0, total = 0.0
        for solid in layout.solids where solid.kind != .bulkhead {
            for point in samples(of: solid) {
                total += 1
                let ray = point - eye
                let distance = ray.length
                guard distance >= nearest, ray.dot(forward) / distance >= limit else { continue }
                if let door {
                    // Standing outside: the sight line must pass between the jambs.
                    let depthEye = (eye - door.wall.start).dot(door.wall.inward)
                    let depthPoint = (point - door.wall.start).dot(door.wall.inward)
                    if depthEye < 0, depthPoint > depthEye {
                        let t = -depthEye / (depthPoint - depthEye)
                        let along = ((eye + ray * t) - door.wall.start).dot(door.wall.direction)
                        guard along > door.void.from + 0.02, along < door.void.to - 0.02 else { continue }
                    }
                }
                seen += 1
            }
        }
        return total > 0 ? seen / total : 0
    }

    /// Stands on the door's centre line, from a short step back in the
    /// hall to a step inside, wherever most of the room is in the picture.
    static func doorway(in layout: PreviewLayout) -> Stop? {
        guard let door = entry(in: layout) else { return nil }
        let centre = door.wall.point(at: door.void.centre)
        let normal = atan2(door.wall.inward.z, door.wall.inward.x) * 180 / .pi
        var best: (score: Double, eye: PreviewLayout.Point, heading: Double)?
        for depth in stride(from: -0.35, through: 0.2501, by: 0.05) {
            let eye = centre + door.wall.inward * depth
            if depth > 0, layout.isInsideSolid(eye, margin: 0.1) { continue }
            for turn in stride(from: -25.0, through: 25.0, by: 2.5) {
                // Small penalties keep the camera near the wall line and
                // facing square into the room when the view is no better.
                let score = coverage(of: layout, from: eye, headingDegrees: normal + turn, through: door)
                    - abs(depth) * 0.05 - abs(turn) * 0.0005
                if best == nil || score > best!.score + 1e-9 { best = (score, eye, normal + turn) }
            }
        }
        guard let best else { return nil }
        let inside = centre + door.wall.inward * 0.3
        return Stop(kind: .doorway,
                    eye: .init(x: best.eye.x, y: eyeHeight(for: layout, at: inside), z: best.eye.z),
                    headingDegrees: best.heading, pitchDegrees: interiorPitch, horizontalFOV: interiorFOV,
                    verticalShift: interiorShift)
    }

    /// A second standing spot on clear floor, as far from the doorway as
    /// the room allows, turned to face the most fixtures.
    static func inside(in layout: PreviewLayout, awayFrom entry: PreviewLayout.Point?) -> Stop? {
        let xs = layout.floor.map(\.x), zs = layout.floor.map(\.z)
        guard let minX = xs.min(), let maxX = xs.max(), let minZ = zs.min(), let maxZ = zs.max() else { return nil }
        let reference = entry ?? PreviewLayout.Point(x: (minX + maxX) / 2, z: (minZ + maxZ) / 2)
        var best: (score: Double, eye: PreviewLayout.Point)?
        for x in stride(from: minX + 0.3, through: maxX - 0.3 + 1e-9, by: 0.1) {
            for z in stride(from: minZ + 0.3, through: maxZ - 0.3 + 1e-9, by: 0.1) {
                let point = PreviewLayout.Point(x: x, z: z)
                guard layout.contains(point), layout.clearance(from: point) >= 0.3,
                      !layout.isInsideSolid(point, margin: 0.2) else { continue }
                let score = entry == nil ? -(point - reference).length : (point - reference).length
                if best == nil || score > best!.score + 1e-9 { best = (score, point) }
            }
        }
        guard let eye = best?.eye else { return nil }
        if let entry, (eye - entry).length < 0.8 { return nil }
        var heading = (best: 0.0, score: -1.0)
        for degrees in stride(from: -180.0, to: 180.0, by: 5.0) {
            let score = coverage(of: layout, from: eye, headingDegrees: degrees, nearest: 0.6)
            if score > heading.score + 1e-9 { heading = (degrees, score) }
        }
        return Stop(kind: .inside, eye: .init(x: eye.x, y: eyeHeight(for: layout, at: eye), z: eye.z),
                    headingDegrees: heading.best, pitchDegrees: interiorPitch, horizontalFOV: interiorFOV,
                    verticalShift: interiorShift)
    }

    /// Straight down over the middle of the room, high enough to hold all
    /// of it, turned so the picture reads like the 2D plan (x to the
    /// right, z down the page).
    static func overhead(of layout: PreviewLayout) -> Stop {
        let xs = layout.floor.map(\.x), zs = layout.floor.map(\.z)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0, minZ = zs.min() ?? 0, maxZ = zs.max() ?? 0
        let fov = 40.0
        let halfWidth = (maxX - minX) / 2 + PreviewLayout.wallThickness + 0.15
        let halfDepth = (maxZ - minZ) / 2 + PreviewLayout.wallThickness + 0.15
        let tanHalf = tan(fov / 2 * .pi / 180)
        let rise = max(halfWidth / tanHalf, halfDepth / (tanHalf / aspect))
        return Stop(kind: .overhead,
                    eye: .init(x: (minX + maxX) / 2, y: layout.ceilingHeight + rise, z: (minZ + maxZ) / 2),
                    headingDegrees: 0, pitchDegrees: -90, horizontalFOV: fov, verticalShift: 0)
    }

    /// Whether the straight line between two standing stops stays clear of
    /// walls and fixtures, so the camera may glide rather than cut.
    static func glideIsClear(from a: Stop, to b: Stop, in layout: PreviewLayout) -> Bool {
        guard a.kind != .overhead, b.kind != .overhead else { return false }
        let door = entry(in: layout)
        for step in 0...40 {
            let t = Double(step) / 40
            let point = a.plan + (b.plan - a.plan) * t
            if layout.isInsideSolid(point, margin: 0.1) { return false }
            if layout.contains(point) { continue }
            // Outside the outline is only allowed in the doorway itself.
            guard let door else { return false }
            let along = (point - door.wall.start).dot(door.wall.direction)
            guard along > door.void.from + 0.1, along < door.void.to - 0.1 else { return false }
        }
        return true
    }
}
