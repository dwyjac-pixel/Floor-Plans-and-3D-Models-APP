import Foundation
import CoreGraphics
import RoomPlan
import simd

struct PlanSegment: Identifiable {
    enum Kind {
        case wall, door, closetDoor, window, opening
    }

    let id = UUID()
    let kind: Kind
    let start: CGPoint
    let end: CGPoint
    var hingeOnEnd = false      // doors: hinge at the `end` jamb
    var swingsOutward = false   // doors: swing away from the plan interior
    var colorHex: String?       // walls: per-wall paint; nil = plan style
    var isPerimeter = false     // walls: outline walls get exterior dimension strings
    var interiorNormal: CGPoint?   // openings: exact unit normal toward the room

    var lengthMeters: Double {
        Double(hypot(end.x - start.x, end.y - start.y))
    }
}

struct PlanObjectFootprint: Identifiable {
    let id = UUID()
    let corners: [CGPoint]
    var label: String = ""
    var fixtureKind: CornerRoom.Fixture.Kind?
    var center: CGPoint = .zero
    var size: CGSize = .zero          // width × depth in metres
    var rotationDegrees: Double = 0
}

/// Top-down 2D floor plan in metres. Built either from a RoomPlan scan or
/// from hand-entered measurements; everything downstream (canvas, summary,
/// PDF) treats both the same.
struct FloorPlanModel {
    let segments: [PlanSegment]
    let objects: [PlanObjectFootprint]
    let bounds: CGRect
    let ceilingHeightMeters: Double?
    let approxFloorAreaSquareMeters: Double?

    var walls: [PlanSegment] { segments.filter { $0.kind == .wall } }
    var doors: [PlanSegment] { segments.filter { $0.kind == .door || $0.kind == .closetDoor } }
    var windows: [PlanSegment] { segments.filter { $0.kind == .window } }
    var openings: [PlanSegment] { segments.filter { $0.kind == .opening } }

    // MARK: - From a RoomPlan scan

    init?(room: CapturedRoom) {
        var segments: [PlanSegment] = []
        segments += room.walls.map {
            var segment = Self.segment(from: $0, kind: .wall)
            segment.isPerimeter = true
            return segment
        }
        segments += room.doors.map { Self.segment(from: $0, kind: .door) }
        segments += room.windows.map { Self.segment(from: $0, kind: .window) }
        segments += room.openings.map { Self.segment(from: $0, kind: .opening) }
        let objects = room.objects.map(Self.footprint(from:))

        let points = segments.flatMap { [$0.start, $0.end] } + objects.flatMap { $0.corners }
        guard let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(),
              let maxY = points.map(\.y).max() else { return nil }

        self.segments = segments
        self.objects = objects
        self.bounds = CGRect(x: minX, y: minY,
                             width: max(maxX - minX, 0.5),
                             height: max(maxY - minY, 0.5))
        self.ceilingHeightMeters = room.walls.map { Double($0.dimensions.y) }.max()
        if let floor = room.floors.first {
            // Bounding-rectangle estimate; over-reports L-shaped rooms.
            self.approxFloorAreaSquareMeters = Double(floor.dimensions.x) * Double(floor.dimensions.y)
        } else {
            self.approxFloorAreaSquareMeters = nil
        }
    }

    // MARK: - From manual measurements

    /// A main rectangle with optional bump-outs. Bump-outs cut a gap in
    /// their host wall and add three outer walls; the floor area is the sum
    /// of all rectangles. Walls run clockwise from the top-left corner.
    init?(manual: ManualRoom) {
        let width = manual.widthMeters
        let length = manual.lengthMeters
        guard width > 0.1, length > 0.1 else { return nil }

        let corners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: width, y: 0),
            CGPoint(x: width, y: length),
            CGPoint(x: 0, y: length),
        ]

        func wallVector(_ index: Int) -> (start: CGPoint, ux: Double, uy: Double, length: Double)? {
            let start = corners[index]
            let end = corners[(index + 1) % 4]
            let dx = Double(end.x - start.x)
            let dy = Double(end.y - start.y)
            let wallLength = (dx * dx + dy * dy).squareRoot()
            guard wallLength > 0 else { return nil }
            return (start, dx / wallLength, dy / wallLength, wallLength)
        }

        func point(_ start: CGPoint, _ ux: Double, _ uy: Double, _ distance: Double,
                   _ nx: Double = 0, _ ny: Double = 0, _ depth: Double = 0) -> CGPoint {
            CGPoint(x: Double(start.x) + ux * distance + nx * depth,
                    y: Double(start.y) + uy * distance + ny * depth)
        }

        var segments: [PlanSegment] = []
        var bumpOutArea = 0.0

        // One pass per wall over merged (non-overlapping) bump intervals:
        // emit each bump's three outer walls, the base-wall segments in the
        // gaps between them, and sum area from the merged intervals. Merging
        // first keeps overlapping bump-outs from producing phantom walls or
        // double-counted area, and keeps this in step with CornerRoom(manual:)
        // which consumes the same merge (QA-011/041).
        for index in 0..<4 {
            guard let wall = wallVector(index) else { continue }
            // Outward normal: walls run clockwise, interior on the right.
            let nx = wall.uy
            let ny = -wall.ux
            var cursor = 0.0
            for bump in manual.mergedBumpOuts(forWall: index, wallLength: wall.length) {
                let from = bump.from
                let to = bump.to
                let depth = bump.depth
                if from > cursor + 0.01 {
                    segments.append(PlanSegment(kind: .wall,
                                                start: point(wall.start, wall.ux, wall.uy, cursor),
                                                end: point(wall.start, wall.ux, wall.uy, from),
                                                isPerimeter: true))
                }
                let a = point(wall.start, wall.ux, wall.uy, from)
                let b = point(wall.start, wall.ux, wall.uy, to)
                let aOut = point(wall.start, wall.ux, wall.uy, from, nx, ny, depth)
                let bOut = point(wall.start, wall.ux, wall.uy, to, nx, ny, depth)
                segments.append(PlanSegment(kind: .wall, start: a, end: aOut, isPerimeter: true))
                segments.append(PlanSegment(kind: .wall, start: aOut, end: bOut, isPerimeter: true))
                segments.append(PlanSegment(kind: .wall, start: bOut, end: b, isPerimeter: true))
                bumpOutArea += (to - from) * depth
                cursor = to
            }
            if cursor < wall.length - 0.01 {
                segments.append(PlanSegment(kind: .wall,
                                            start: point(wall.start, wall.ux, wall.uy, cursor),
                                            end: point(wall.start, wall.ux, wall.uy, wall.length),
                                            isPerimeter: true))
            }
        }

        for feature in manual.features {
            let index = min(max(feature.wallIndex, 0), 3)
            guard let wall = wallVector(index) else { continue }
            let from = min(max(feature.offsetMeters, 0), wall.length)
            let to = min(from + max(feature.widthMeters, 0.05), wall.length)
            guard to > from else { continue }

            let kind: PlanSegment.Kind
            switch feature.kind {
            case .door: kind = .door
            case .closetDoor: kind = .closetDoor
            case .window: kind = .window
            case .opening: kind = .opening
            }
            segments.append(PlanSegment(kind: kind,
                                        start: point(wall.start, wall.ux, wall.uy, from),
                                        end: point(wall.start, wall.ux, wall.uy, to)))
        }

        let points = segments.flatMap { [$0.start, $0.end] }
        guard let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(),
              let maxY = points.map(\.y).max() else { return nil }

        self.segments = segments
        self.objects = []
        self.bounds = CGRect(x: minX, y: minY,
                             width: max(maxX - minX, 0.5),
                             height: max(maxY - minY, 0.5))
        self.ceilingHeightMeters = manual.ceilingHeightMeters > 0 ? manual.ceilingHeightMeters : nil
        self.approxFloorAreaSquareMeters = width * length + bumpOutArea
    }

    // MARK: - From AR corner capture

    /// Closed polygon of captured floor corners; exact area via shoelace.
    init?(cornerRoom: CornerRoom) {
        let points = cornerRoom.corners
        guard points.count >= 3 else { return nil }

        var segments: [PlanSegment] = []
        for index in 0..<points.count {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            let start = CGPoint(x: a.x, y: a.z)
            let end = CGPoint(x: b.x, y: b.z)
            guard hypot(end.x - start.x, end.y - start.y) > 0.05 else { continue }
            segments.append(PlanSegment(kind: .wall, start: start, end: end,
                                        colorHex: cornerRoom.outlineWallHex[index],
                                        isPerimeter: true))
        }
        guard segments.count >= 3 else { return nil }

        // Winding decides the true interior side of every outline wall —
        // a centroid guess is wrong on L-shaped rooms.
        var windingDoubled = 0.0
        for index in 0..<points.count {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            windingDoubled += a.x * b.z - b.x * a.z
        }
        let windingSign: Double = windingDoubled > 0 ? 1 : -1

        // Doors, windows, and cased openings — on outline or interior walls.
        for opening in cornerRoom.openings {
            guard let host = cornerRoom.hostWall(for: opening) else { continue }
            let from = min(max(opening.offsetMeters, 0), host.length)
            let to = min(from + max(opening.widthMeters, 0.05), host.length)
            guard to > from else { continue }
            let interiorNormal: CGPoint? = opening.interiorWallID == nil
                ? CGPoint(x: windingSign * -host.uz, y: windingSign * host.ux)
                : nil

            let kind: PlanSegment.Kind
            switch opening.kind {
            case .door: kind = .door
            case .closetDoor: kind = .closetDoor
            case .window: kind = .window
            case .opening: kind = .opening
            }
            segments.append(PlanSegment(kind: kind,
                                        start: CGPoint(x: host.start.x + host.ux * from,
                                                       y: host.start.z + host.uz * from),
                                        end: CGPoint(x: host.start.x + host.ux * to,
                                                     y: host.start.z + host.uz * to),
                                        hingeOnEnd: opening.hingeOnEnd ?? false,
                                        swingsOutward: opening.swingsOutward ?? false,
                                        interiorNormal: interiorNormal))
        }

        // Interior walls (partitions, closets).
        for wall in cornerRoom.interiorWalls {
            let start = CGPoint(x: wall.start.x, y: wall.start.z)
            let end = CGPoint(x: wall.end.x, y: wall.end.z)
            guard hypot(end.x - start.x, end.y - start.y) > 0.05 else { continue }
            segments.append(PlanSegment(kind: .wall, start: start, end: end,
                                        colorHex: wall.paintHex))
        }

        // Fixture footprints.
        var objects: [PlanObjectFootprint] = []
        for fixture in cornerRoom.fixtures {
            let radians = fixture.rotationDegrees * .pi / 180
            let ax = cos(radians)
            let az = sin(radians)
            let bx = -sin(radians)
            let bz = cos(radians)
            let hw = fixture.widthMeters / 2
            let hd = fixture.depthMeters / 2
            let corners = [
                CGPoint(x: fixture.x + ax * hw + bx * hd, y: fixture.z + az * hw + bz * hd),
                CGPoint(x: fixture.x + ax * hw - bx * hd, y: fixture.z + az * hw - bz * hd),
                CGPoint(x: fixture.x - ax * hw - bx * hd, y: fixture.z - az * hw - bz * hd),
                CGPoint(x: fixture.x - ax * hw + bx * hd, y: fixture.z - az * hw + bz * hd),
            ]
            objects.append(PlanObjectFootprint(corners: corners,
                                               label: fixture.kind.shortLabel,
                                               fixtureKind: fixture.kind,
                                               center: CGPoint(x: fixture.x, y: fixture.z),
                                               size: CGSize(width: fixture.widthMeters, height: fixture.depthMeters),
                                               rotationDegrees: fixture.rotationDegrees))
        }

        var doubledArea = 0.0
        for index in 0..<points.count {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            doubledArea += a.x * b.z - b.x * a.z
        }

        let allPoints = segments.flatMap { [$0.start, $0.end] } + objects.flatMap { $0.corners }
        guard let minX = allPoints.map(\.x).min(),
              let maxX = allPoints.map(\.x).max(),
              let minY = allPoints.map(\.y).min(),
              let maxY = allPoints.map(\.y).max() else { return nil }

        self.segments = segments
        self.objects = objects
        self.bounds = CGRect(x: minX, y: minY,
                             width: max(maxX - minX, 0.5),
                             height: max(maxY - minY, 0.5))
        self.ceilingHeightMeters = cornerRoom.ceilingHeightMeters > 0 ? cornerRoom.ceilingHeightMeters : nil
        self.approxFloorAreaSquareMeters = abs(doubledArea) / 2
    }

    // MARK: - Merged multi-room plan

    /// Every room drawn together in the shared plan space: the floor area
    /// is the sum of the rooms and the ceiling is the tallest.
    init?(rooms: [CornerRoom]) {
        var segments: [PlanSegment] = []
        var objects: [PlanObjectFootprint] = []
        var totalArea = 0.0
        var maxCeiling = 0.0
        for room in rooms {
            guard let sub = FloorPlanModel(cornerRoom: room) else { continue }
            segments += sub.segments
            objects += sub.objects
            totalArea += sub.approxFloorAreaSquareMeters ?? 0
            maxCeiling = max(maxCeiling, sub.ceilingHeightMeters ?? 0)
        }

        let points = segments.flatMap { [$0.start, $0.end] } + objects.flatMap { $0.corners }
        guard let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(),
              let maxY = points.map(\.y).max() else { return nil }

        self.segments = segments
        self.objects = objects
        self.bounds = CGRect(x: minX, y: minY,
                             width: max(maxX - minX, 0.5),
                             height: max(maxY - minY, 0.5))
        self.ceilingHeightMeters = maxCeiling > 0 ? maxCeiling : nil
        self.approxFloorAreaSquareMeters = totalArea > 0 ? totalArea : nil
    }

    // MARK: - Summary

    func summaryItems(useImperial: Bool) -> [(label: String, value: String)] {
        var items: [(label: String, value: String)] = []
        if let ceilingHeightMeters {
            items.append(("Ceiling height (max)", Measure.length(ceilingHeightMeters, imperial: useImperial)))
        }
        if let approxFloorAreaSquareMeters {
            items.append(("Approx. floor area", Measure.area(approxFloorAreaSquareMeters, imperial: useImperial)))
        }
        items.append(("Walls", "\(walls.count)"))
        items.append(("Doors", "\(doors.count)"))
        items.append(("Windows", "\(windows.count)"))
        items.append(("Openings", "\(openings.count)"))
        return items
    }

    // MARK: - Scan projection helpers

    private static func segment(from surface: CapturedRoom.Surface, kind: PlanSegment.Kind) -> PlanSegment {
        let t = surface.transform
        let center = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        var xAxis = simd_float3(t.columns.0.x, t.columns.0.y, t.columns.0.z)
        if simd_length(xAxis) > 0 { xAxis = simd_normalize(xAxis) }
        let half = surface.dimensions.x / 2
        let a = center - xAxis * half
        let b = center + xAxis * half
        return PlanSegment(kind: kind, start: planPoint(a), end: planPoint(b))
    }

    private static func footprint(from object: CapturedRoom.Object) -> PlanObjectFootprint {
        let t = object.transform
        let center = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        var xAxis = simd_float3(t.columns.0.x, t.columns.0.y, t.columns.0.z)
        var zAxis = simd_float3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        if simd_length(xAxis) > 0 { xAxis = simd_normalize(xAxis) }
        if simd_length(zAxis) > 0 { zAxis = simd_normalize(zAxis) }
        let hx = object.dimensions.x / 2
        let hz = object.dimensions.z / 2
        let corners = [
            center + xAxis * hx + zAxis * hz,
            center + xAxis * hx - zAxis * hz,
            center - xAxis * hx - zAxis * hz,
            center - xAxis * hx + zAxis * hz,
        ].map(planPoint)
        return PlanObjectFootprint(corners: corners)
    }

    private static func planPoint(_ v: simd_float3) -> CGPoint {
        CGPoint(x: CGFloat(v.x), y: CGFloat(v.z))
    }
}
