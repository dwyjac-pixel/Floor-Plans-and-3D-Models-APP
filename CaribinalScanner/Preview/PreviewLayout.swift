import Foundation

/// The enclosed room a finished preview draws, as plain numbers.
///
/// Scene space is plan space minus the room's minimum corner, in metres,
/// with y up. The plan outline is the finished interior: every wall face
/// sits exactly on its plan line and the wall's thickness goes outward, so
/// a clear dimension measured in the preview equals the drawing.
///
/// Nothing here imports a renderer. The SceneKit preview is built from this
/// value, and so is any later renderer, which is what lets one set of
/// fidelity tests cover all of them.
struct PreviewLayout {
    struct Point: Equatable {
        var x: Double
        var z: Double

        static func + (a: Point, b: Point) -> Point { Point(x: a.x + b.x, z: a.z + b.z) }
        static func - (a: Point, b: Point) -> Point { Point(x: a.x - b.x, z: a.z - b.z) }
        static func * (a: Point, k: Double) -> Point { Point(x: a.x * k, z: a.z * k) }
        func dot(_ other: Point) -> Double { x * other.x + z * other.z }
        var length: Double { (x * x + z * z).squareRoot() }
    }

    /// A door, window or cased opening cut through a wall face.
    struct Void: Equatable {
        let id: UUID
        let kind: CornerRoom.Opening.Kind
        /// Metres along the face from its start corner.
        let from: Double
        let to: Double
        let sill: Double
        let head: Double
        let hingeAtEnd: Bool
        let swingsOutward: Bool

        var width: Double { to - from }
        var centre: Double { (from + to) / 2 }
    }

    /// One outline wall as seen from inside the room.
    struct WallFace {
        /// Outline wall index in the saved revision. Stable for the life of
        /// that revision, because a saved revision never changes.
        let wallIndex: Int
        let start: Point
        let end: Point
        /// Unit normal pointing into the room.
        let inward: Point
        /// Mitred outside corners, `Self.wallThickness` out from the plan line.
        let outerStart: Point
        let outerEnd: Point
        let voids: [Void]

        var length: Double { (end - start).length }
        var direction: Point { (end - start) * (1 / max(length, 1e-9)) }
        func point(at distance: Double) -> Point { start + direction * distance }
    }

    /// A fixture footprint. The fixture's own x axis runs along its width
    /// and its front faces its own +z, matching the plan editor.
    struct Solid: Equatable {
        let id: UUID
        let kind: CornerRoom.Fixture.Kind
        let centre: Point
        let width: Double
        let depth: Double
        /// Rotation about +y in degrees (the plan's rotation, negated).
        let yawDegrees: Double
        /// Bulkheads only: how far the underside sits below the ceiling.
        let drop: Double?

        var xAxis: Point {
            let r = -yawDegrees * .pi / 180
            return Point(x: cos(r), z: sin(r))
        }
        var zAxis: Point {
            let r = -yawDegrees * .pi / 180
            return Point(x: -sin(r), z: cos(r))
        }
        /// Footprint corners: back left, back right, front right, front left.
        var corners: [Point] {
            let hx = xAxis * (width / 2), hz = zAxis * (depth / 2)
            return [centre - hx - hz, centre + hx - hz, centre + hx + hz, centre - hx + hz]
        }
    }

    /// A number the picture needs that the saved plan does not hold, so a
    /// default was used. Every one of these is shown to the contractor and
    /// printed on any exported still.
    enum Assumption: Equatable {
        case ceilingHeight(CornerRoom.CeilingHeightSource?)
        case doorHeight(UUID)
        case windowHeight(UUID)
        case windowSill(UUID)
        case bulkheadDrop(UUID)
        case approximateOutline
        /// Drawn as a plain block because this release has no model for it.
        case genericFixture(UUID)
    }

    /// A reason this room cannot be drawn faithfully. The preview does not
    /// open while any of these stand.
    enum Problem: Equatable {
        case tooFewCorners
        case noCeilingHeight
        case openingOffWall(UUID)
        case openingAboveCeiling(UUID)
        case openingsOverlap(UUID, UUID)
        case interiorWallsNotDrawn(Int)
        /// A bulkhead is drawn with its underside at one height while the
        /// room's measured clearance says another.
        case bulkheadHeightConflict(drawn: Double, measured: Double)
        case fixtureThroughWall(UUID, depth: Double)
        case fixturesOverlap(UUID, UUID)
    }

    enum WallSurface: Equatable {
        case paint
        /// Wall beside a shower or tub, tiled floor to ceiling.
        case wetTile
    }

    /// A rectangle of finished wall, in metres along the face and up.
    struct WallCell: Equatable {
        let wallIndex: Int
        let u0: Double
        let u1: Double
        let v0: Double
        let v1: Double
        let surface: WallSurface

        var area: Double { (u1 - u0) * (v1 - v0) }
    }

    static let wallThickness = 0.1
    static let defaultDoorHead = 2.03
    static let defaultWindowHeight = 1.07
    static let defaultWindowSill = 0.91
    static let defaultBulkheadDrop = 0.4
    /// Fixtures this release draws as finished models. Anything else is a
    /// plain block and is listed as such.
    static let detailedKinds: Set<CornerRoom.Fixture.Kind> = [.vanity, .toilet, .shower, .tubShower, .bulkhead, .baseCabinets, .upperCabinets, .shortUpperCabinet, .island, .fridge, .stove, .kitchenSink, .microwave, .dishwasher]

    /// Plan-space point that became the scene origin.
    let origin: Point
    /// Floor outline in scene space, in the saved corner order.
    let floor: [Point]
    let ceilingHeight: Double
    let walls: [WallFace]
    let solids: [Solid]
    let assumptions: [Assumption]
    private(set) var problems: [Problem]

    var floorArea: Double { abs(Self.signedArea(floor)) }

    init(room: CornerRoom) {
        let planCorners = room.corners.map { Point(x: $0.x, z: $0.z) }
        let origin = Point(x: planCorners.map(\.x).min() ?? 0, z: planCorners.map(\.z).min() ?? 0)
        let floor = planCorners.map { $0 - origin }
        var assumptions: [Assumption] = []
        var problems: [Problem] = []

        self.origin = origin
        self.floor = floor

        let height = room.ceilingHeightMeters
        let hasHeight = height.isFinite && height > 0.5
        ceilingHeight = hasHeight ? height : 0
        if !hasHeight {
            problems.append(.noCeilingHeight)
        } else if room.ceilingHeightSource != .fieldMeasured {
            assumptions.append(.ceilingHeight(room.ceilingHeightSource))
        }
        if room.outlineNeedsVerification == true { assumptions.append(.approximateOutline) }
        if !room.interiorWalls.isEmpty { problems.append(.interiorWallsNotDrawn(room.interiorWalls.count)) }

        guard floor.count >= 3, abs(Self.signedArea(floor)) > 0.01 else {
            problems.append(.tooFewCorners)
            walls = []
            solids = []
            self.assumptions = assumptions
            self.problems = problems
            return
        }

        // Interior is on the left of each edge when the outline winds
        // counter-clockwise in (x, z), on the right otherwise.
        let leftIsInside = Self.signedArea(floor) > 0
        let count = floor.count
        func edge(_ i: Int) -> Point { floor[(i + 1) % count] - floor[i] }
        func inward(_ i: Int) -> Point {
            let d = edge(i), length = max(d.length, 1e-9)
            let left = Point(x: -d.z / length, z: d.x / length)
            return leftIsInside ? left : left * -1
        }
        // Outside corner of the wall shell at corner i: where the two
        // neighbouring walls' outer lines meet.
        func outerCorner(_ i: Int) -> Point {
            let before = inward((i + count - 1) % count) * -1
            let after = inward(i) * -1
            let spread = 1 + before.dot(after)
            guard spread > 0.05 else { return floor[i] + after * Self.wallThickness }
            return floor[i] + (before + after) * (Self.wallThickness / spread)
        }

        var faces: [WallFace] = []
        for i in 0..<count {
            let length = edge(i).length
            var voids: [Void] = []
            for opening in room.openings where opening.interiorWallID == nil && opening.wallIndex == i {
                let isWindow = opening.kind == .window
                let sill: Double
                let head: Double
                if isWindow {
                    if opening.sillMeters == nil { assumptions.append(.windowSill(opening.id)) }
                    if opening.heightMeters == nil { assumptions.append(.windowHeight(opening.id)) }
                    sill = opening.sillMeters ?? Self.defaultWindowSill
                    head = sill + (opening.heightMeters ?? Self.defaultWindowHeight)
                } else {
                    if opening.heightMeters == nil { assumptions.append(.doorHeight(opening.id)) }
                    sill = 0
                    head = opening.heightMeters ?? Self.defaultDoorHead
                }
                let from = opening.offsetMeters
                let to = opening.offsetMeters + opening.widthMeters
                guard from >= -0.001, to <= length + 0.001, opening.widthMeters > 0.05 else {
                    problems.append(.openingOffWall(opening.id))
                    continue
                }
                guard !hasHeight || head <= height + 0.001 else {
                    problems.append(.openingAboveCeiling(opening.id))
                    continue
                }
                voids.append(Void(id: opening.id, kind: opening.kind, from: max(from, 0), to: min(to, length),
                                  sill: sill, head: head, hingeAtEnd: opening.hingeOnEnd == true,
                                  swingsOutward: opening.swingsOutward == true))
            }
            voids.sort { $0.from < $1.from }
            for (a, b) in zip(voids, voids.dropFirst()) where b.from < a.to - 0.001 {
                problems.append(.openingsOverlap(a.id, b.id))
            }
            faces.append(WallFace(wallIndex: i, start: floor[i], end: floor[(i + 1) % count], inward: inward(i),
                                  outerStart: outerCorner(i), outerEnd: outerCorner((i + 1) % count), voids: voids))
        }
        walls = faces

        solids = room.fixtures.map { fixture in
            if fixture.kind == .bulkhead, fixture.dropMeters == nil { assumptions.append(.bulkheadDrop(fixture.id)) }
            if !Self.detailedKinds.contains(fixture.kind) { assumptions.append(.genericFixture(fixture.id)) }
            return Solid(id: fixture.id, kind: fixture.kind,
                         centre: Point(x: fixture.x, z: fixture.z) - origin,
                         width: fixture.widthMeters, depth: fixture.depthMeters,
                         yawDegrees: -fixture.rotationDegrees,
                         drop: fixture.kind == .bulkhead ? (fixture.dropMeters ?? Self.defaultBulkheadDrop) : nil)
        }
        self.assumptions = assumptions
        self.problems = problems

        // Checks that need the finished walls and solids.
        var late: [Problem] = []
        if hasHeight, let measured = room.bulkheadClearanceMeters,
           let lowest = solids.compactMap(\.drop).max() {
            let drawn = height - lowest
            if abs(drawn - measured) > 0.01 {
                late.append(.bulkheadHeightConflict(drawn: drawn, measured: measured))
            }
        }
        for solid in solids {
            let depth = solid.corners.map { contains($0) ? 0 : clearance(from: $0) }.max() ?? 0
            if depth > Self.fitTolerance { late.append(.fixtureThroughWall(solid.id, depth: depth)) }
        }
        func heightBand(_ solid: Solid) -> Int {
            switch solid.kind {
            case .bulkhead: 2
            case .microwave, .upperCabinets, .shortUpperCabinet: 1
            default: 0
            }
        }
        for (index, a) in solids.enumerated() where heightBand(a) != 2 {
            for b in solids.dropFirst(index + 1) where heightBand(a) == heightBand(b) && Self.overlap(a, b) > Self.fitTolerance {
                if Set([a.kind, b.kind]) == [.shortUpperCabinet, .microwave] { continue }
                late.append(.fixturesOverlap(a.id, b.id))
            }
        }
        self.problems = problems + late
    }

    /// How far a fixture may sit into a wall or another fixture before the
    /// preview refuses to draw it. Looser than the 2 mm drawing tolerance
    /// because plan snapping rounds to the millimetre.
    static let fitTolerance = 0.005

    /// Depth by which two footprints interpenetrate, or 0 when they are
    /// apart (separating axis test on the four edge directions).
    static func overlap(_ a: Solid, _ b: Solid) -> Double {
        var least = Double.infinity
        for axis in [a.xAxis, a.zAxis, b.xAxis, b.zAxis] {
            let pa = a.corners.map { $0.dot(axis) }, pb = b.corners.map { $0.dot(axis) }
            let depth = min(pa.max()! - pb.min()!, pb.max()! - pa.min()!)
            if depth <= 0 { return 0 }
            least = min(least, depth)
        }
        return least
    }

    static func signedArea(_ polygon: [Point]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        var sum = 0.0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            sum += a.x * b.z - b.x * a.z
        }
        return sum / 2
    }

    func contains(_ point: Point) -> Bool {
        var inside = false
        var j = floor.count - 1
        for i in floor.indices {
            let a = floor[i], b = floor[j]
            if (a.z > point.z) != (b.z > point.z),
               point.x < (b.x - a.x) * (point.z - a.z) / (b.z - a.z) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Shortest distance from a point to any wall face.
    func clearance(from point: Point) -> Double {
        walls.map { wall in
            let d = wall.end - wall.start
            let t = max(0, min(1, (point - wall.start).dot(d) / max(d.dot(d), 1e-12)))
            return (point - (wall.start + d * t)).length
        }.min() ?? 0
    }

    /// Whether a point lies inside any floor-standing fixture footprint,
    /// grown by `margin`.
    func isInsideSolid(_ point: Point, margin: Double = 0) -> Bool {
        solids.contains { solid in
            guard solid.kind != .bulkhead else { return false }
            let local = point - solid.centre
            return abs(local.dot(solid.xAxis)) <= solid.width / 2 + margin
                && abs(local.dot(solid.zAxis)) <= solid.depth / 2 + margin
        }
    }

    /// The stretch of a wall face that a fixture stands flat against, in
    /// metres from the face's start corner.
    func contact(of solid: Solid, on wall: WallFace, tolerance: Double = 0.03) -> ClosedRange<Double>? {
        let corners = solid.corners
        for i in corners.indices {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            guard abs((a - wall.start).dot(wall.inward)) <= tolerance,
                  abs((b - wall.start).dot(wall.inward)) <= tolerance else { continue }
            let ta = (a - wall.start).dot(wall.direction), tb = (b - wall.start).dot(wall.direction)
            let from = max(0, min(ta, tb)), to = min(wall.length, max(ta, tb))
            if to - from >= 0.05 { return from...to }
        }
        return nil
    }

    /// Whether a straight edge lies flat against any wall face.
    func touchesWall(_ a: Point, _ b: Point, tolerance: Double = 0.03) -> Bool {
        walls.contains { wall in
            abs((a - wall.start).dot(wall.inward)) <= tolerance && abs((b - wall.start).dot(wall.inward)) <= tolerance
                && min((a - wall.start).dot(wall.direction), (b - wall.start).dot(wall.direction)) >= -tolerance
                && max((a - wall.start).dot(wall.direction), (b - wall.start).dot(wall.direction)) <= wall.length + tolerance
        }
    }

    /// Wall stretches beside a shower or tub.
    func wetIntervals(on wall: WallFace) -> [ClosedRange<Double>] {
        solids.filter { $0.kind == .shower || $0.kind == .tubShower }
            .compactMap { contact(of: $0, on: wall) }
    }

    /// Wall stretches a baseboard should skip: doorways, wet walls and
    /// cabinets that stand against the wall.
    func baseboardGaps(on wall: WallFace) -> [ClosedRange<Double>] {
        let doors = wall.voids.filter { $0.sill < 0.05 }.map { $0.from...$0.to }
        let cabinets = solids.filter { [.vanity, .baseCabinets, .shower, .tubShower].contains($0.kind) }
            .compactMap { contact(of: $0, on: wall) }
        return doors + cabinets
    }

    /// The finished surface of one wall face, cut around its openings and
    /// split where paint meets tile. Cell areas add up to the wall area
    /// less its openings.
    func cells(for wall: WallFace) -> [WallCell] {
        let wet = wetIntervals(on: wall)
        var us: [Double] = [0, wall.length]
        var vs: [Double] = [0, ceilingHeight]
        for void in wall.voids {
            us += [void.from, void.to]
            vs += [void.sill, void.head]
        }
        for range in wet { us += [range.lowerBound, range.upperBound] }
        func breaks(_ values: [Double], upTo limit: Double) -> [Double] {
            var out: [Double] = []
            for value in values.map({ min(max($0, 0), limit) }).sorted() where out.last.map({ value - $0 > 1e-6 }) ?? true {
                out.append(value)
            }
            return out
        }
        let u = breaks(us, upTo: wall.length), v = breaks(vs, upTo: ceilingHeight)
        var cells: [WallCell] = []
        for (u0, u1) in zip(u, u.dropFirst()) {
            for (v0, v1) in zip(v, v.dropFirst()) {
                let cu = (u0 + u1) / 2, cv = (v0 + v1) / 2
                if wall.voids.contains(where: { cu > $0.from && cu < $0.to && cv > $0.sill && cv < $0.head }) { continue }
                let isWet = wet.contains { $0.contains(cu) }
                cells.append(WallCell(wallIndex: wall.wallIndex, u0: u0, u1: u1, v0: v0, v1: v1,
                                      surface: isWet ? .wetTile : .paint))
            }
        }
        return cells
    }

    /// Lowest thing overhead at a point: the ceiling, or a bulkhead's
    /// underside where one hangs there.
    func clearHeight(above point: Point) -> Double {
        var height = ceilingHeight
        for solid in solids {
            guard let drop = solid.drop else { continue }
            let local = point - solid.centre
            if abs(local.dot(solid.xAxis)) <= solid.width / 2, abs(local.dot(solid.zAxis)) <= solid.depth / 2 {
                height = min(height, ceilingHeight - drop)
            }
        }
        return height
    }

    /// Triangles covering the floor outline, as index triples into `floor`,
    /// wound the same way as the outline (ear clipping).
    func floorTriangles() -> [Int] {
        var remaining = Array(floor.indices)
        var triangles: [Int] = []
        let positive = Self.signedArea(floor) > 0
        func cross(_ a: Point, _ b: Point, _ c: Point) -> Double {
            (b.x - a.x) * (c.z - a.z) - (b.z - a.z) * (c.x - a.x)
        }
        var guardCount = 0
        while remaining.count > 3, guardCount < 10_000 {
            guardCount += 1
            var clipped = false
            for i in remaining.indices {
                let ia = remaining[(i + remaining.count - 1) % remaining.count]
                let ib = remaining[i]
                let ic = remaining[(i + 1) % remaining.count]
                let a = floor[ia], b = floor[ib], c = floor[ic]
                let turn = cross(a, b, c)
                guard positive ? turn > 1e-12 : turn < -1e-12 else { continue }
                let blocked = remaining.contains { index in
                    guard index != ia, index != ib, index != ic else { return false }
                    let p = floor[index]
                    let d1 = cross(a, b, p), d2 = cross(b, c, p), d3 = cross(c, a, p)
                    return positive ? (d1 >= 0 && d2 >= 0 && d3 >= 0) : (d1 <= 0 && d2 <= 0 && d3 <= 0)
                }
                if blocked { continue }
                triangles += [ia, ib, ic]
                remaining.remove(at: i)
                clipped = true
                break
            }
            if !clipped { break }
        }
        if remaining.count == 3 { triangles += remaining }
        return triangles
    }

    /// A short, stable description of the drawn geometry in millimetres.
    /// Two layouts with the same signature draw the same room.
    var signature: String {
        func mm(_ value: Double) -> String { String(Int((value * 1000).rounded())) }
        var parts = ["h" + mm(ceilingHeight)]
        parts += floor.map { "c" + mm($0.x) + "," + mm($0.z) }
        for wall in walls {
            for void in wall.voids {
                parts.append("o\(wall.wallIndex):" + [void.from, void.to, void.sill, void.head].map(mm).joined(separator: ","))
            }
        }
        for solid in solids {
            parts.append("f\(solid.kind.rawValue):" + ([solid.centre.x, solid.centre.z, solid.width, solid.depth,
                                                          solid.yawDegrees / 1000, solid.drop ?? 0].map(mm).joined(separator: ",")))
        }
        return parts.joined(separator: " ")
    }
}
