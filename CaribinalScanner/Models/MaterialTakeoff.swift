import Foundation

/// Automatic material takeoff computed from the captured room geometry:
/// framing, drywall, flooring, doors/windows, and fixture line items.
/// Quantities include a waste factor; all placeholder assumptions are
/// standard North American residential practice (16" o.c. framing,
/// 4x8 sheets) and are labelled in the UI.
struct MaterialTakeoff {
    struct Line: Identifiable {
        let id = UUID()
        let category: String
        let item: String
        let quantity: String
        let note: String

        /// Stable identity for user adjustments — quantities regenerate
        /// from geometry, but the category + item name persists.
        var key: String { "\(category)|\(item)" }
    }

    let lines: [Line]

    static func calculate(room: CornerRoom) -> MaterialTakeoff {
        calculate(rooms: [room])
    }

    /// Quantities summed across every room. Ceiling heights can differ per
    /// room, so wall areas are accumulated room by room.
    static func calculate(rooms: [CornerRoom]) -> MaterialTakeoff {
        var lines: [Line] = []
        let waste = 1.10                       // 10% waste factor
        let ftPerM = 3.28084

        var interiorM = 0.0
        var cornerCount = 0
        var interiorCount = 0
        var areaM2 = 0.0
        var outlineWallAreaM2 = 0.0            // one face per room (drywall)
        var interiorWallAreaM2 = 0.0           // both faces
        var doors = 0
        var closetDoors = 0
        var windows = 0
        var fixtures: [CornerRoom.Fixture] = []

        // Outline wall segments across every room, so a party wall shared by
        // two captured rooms can be counted once for framing/baseboard and
        // left out of the exterior-insulation line (QA-019).
        struct OutlineSegment {
            let a: CornerRoom.Point
            let b: CornerRoom.Point
            let length: Double
            let ceiling: Double
            let room: Int
        }
        var segments: [OutlineSegment] = []

        for (roomIndex, room) in rooms.enumerated() {
            let ceiling = room.ceilingHeightMeters > 0.5 ? room.ceilingHeightMeters : 2.4
            let count = room.corners.count
            for i in 0..<count {
                let a = room.corners[i]
                let b = room.corners[(i + 1) % count]
                let length = ((b.x - a.x) * (b.x - a.x) + (b.z - a.z) * (b.z - a.z)).squareRoot()
                segments.append(OutlineSegment(a: a, b: b, length: length, ceiling: ceiling, room: roomIndex))
                outlineWallAreaM2 += length * ceiling   // drywall finishes every room face
            }
            let interiorLength = room.interiorWalls.reduce(0.0) { $0 + $1.lengthMeters }
            interiorM += interiorLength
            cornerCount += count
            interiorCount += room.interiorWalls.count
            areaM2 += room.floorAreaSquareMeters
            interiorWallAreaM2 += interiorLength * ceiling * 2
            doors += room.openings.filter { $0.kind == .door }.count
            closetDoors += room.openings.filter { $0.kind == .closetDoor }.count
            windows += room.openings.filter { $0.kind == .window }.count
            fixtures += room.fixtures
        }

        // Two outline segments trace the same physical wall when their
        // endpoints coincide (within tolerance) in either order.
        let tol = 0.2
        func samePoint(_ p: CornerRoom.Point, _ q: CornerRoom.Point) -> Bool {
            abs(p.x - q.x) <= tol && abs(p.z - q.z) <= tol
        }
        func segmentsMatch(_ s: OutlineSegment, _ t: OutlineSegment) -> Bool {
            (samePoint(s.a, t.a) && samePoint(s.b, t.b)) ||
            (samePoint(s.a, t.b) && samePoint(s.b, t.a))
        }

        var outlineM = 0.0                     // framing length: shared walls once
        var exteriorWallAreaM2 = 0.0           // one face, non-shared walls only
        for (index, seg) in segments.enumerated() {
            let sharedWithOtherRoom = segments.contains { other in
                other.room != seg.room && segmentsMatch(seg, other)
            }
            let duplicateOfEarlier = segments[..<index].contains { other in
                other.room != seg.room && segmentsMatch(seg, other)
            }
            if !duplicateOfEarlier {
                outlineM += seg.length         // count each physical wall once
            }
            if !sharedWithOtherRoom {
                exteriorWallAreaM2 += seg.length * seg.ceiling
            }
        }

        let totalWallFt = (outlineM + interiorM) * ftPerM
        // Baseboard runs both faces of interior partitions (QA-052).
        let baseboardFt = (outlineM + interiorM * 2) * ftPerM
        let areaFt2 = areaM2 * 10.7639

        // FRAMING — studs 16" o.c. + top/bottom plates
        let studs = Int((totalWallFt * 12 / 16 + Double(cornerCount) + Double(interiorCount) * 2) * waste)
        lines.append(Line(category: "Framing", item: "2×4×8' studs",
                          quantity: "\(studs)", note: "16\" o.c. + corners, 10% waste"))
        let plateFt = Int(totalWallFt * 3 * waste)
        lines.append(Line(category: "Framing", item: "2×4 plate stock",
                          quantity: "\(plateFt) lin ft", note: "bottom + double top plate"))

        // DRYWALL — wall both faces for interior, one face outline + ceiling
        let wallSheetArea = (outlineWallAreaM2 + interiorWallAreaM2) * 10.7639
        let ceilingSheets = areaFt2 / 32
        let wallSheets = wallSheetArea / 32
        lines.append(Line(category: "Drywall", item: "1/2\" drywall 4×8 sheets",
                          quantity: "\(Int((wallSheets + ceilingSheets) * waste))",
                          note: "walls + ceiling, 10% waste"))
        lines.append(Line(category: "Drywall", item: "Insulation (exterior walls)",
                          quantity: "\(Int(exteriorWallAreaM2 * 10.7639)) sq ft", note: "R-value per code"))

        // FLOORING
        lines.append(Line(category: "Flooring", item: "Subfloor / underlay",
                          quantity: "\(Int(areaFt2 * waste)) sq ft", note: "10% waste"))
        lines.append(Line(category: "Flooring", item: "Finish flooring",
                          quantity: "\(Int(areaFt2 * waste)) sq ft", note: "type per estimate"))
        lines.append(Line(category: "Flooring", item: "Baseboard",
                          quantity: "\(Int(baseboardFt * waste)) lin ft", note: "both faces of partitions"))

        // OPENINGS
        if doors > 0 {
            lines.append(Line(category: "Openings", item: "Doors (pre-hung + casing)",
                              quantity: "\(doors)", note: ""))
        }
        if closetDoors > 0 {
            lines.append(Line(category: "Openings", item: "Closet doors (bifold / sliding)",
                              quantity: "\(closetDoors)", note: ""))
        }
        if windows > 0 {
            lines.append(Line(category: "Openings", item: "Windows (+ headers, sills, casing)",
                              quantity: "\(windows)", note: "verify egress sizing"))
        }

        // FIXTURES — aggregate same-kind fixtures into a single priced line so
        // the shared "Fixtures|<kind>" key holds one price per fixture type
        // rather than colliding across rows and double-counting it (QA-003).
        var fixtureOrder: [CornerRoom.Fixture.Kind] = []
        var fixtureGroups: [CornerRoom.Fixture.Kind: [CornerRoom.Fixture]] = [:]
        for fixture in fixtures {
            if fixtureGroups[fixture.kind] == nil { fixtureOrder.append(fixture.kind) }
            fixtureGroups[fixture.kind, default: []].append(fixture)
        }
        for kind in fixtureOrder {
            let group = fixtureGroups[kind] ?? []
            let first = group[0]
            let sizeText = String(format: "%.1f' × %.1f'",
                                  first.widthMeters * ftPerM,
                                  first.depthMeters * ftPerM)
            let quantity = group.count > 1 ? "\(group.count) @ \(sizeText)" : sizeText
            lines.append(Line(category: "Fixtures", item: kind.rawValue,
                              quantity: quantity, note: ""))
        }

        return MaterialTakeoff(lines: lines)
    }
}

/// User pricing decisions layered on the computed takeoff: which lines
/// count toward the total, and the price the user entered for each.
/// Keyed by Line.key so they survive geometry edits and regeneration.
struct TakeoffAdjustments: Codable {
    var excludedKeys: Set<String> = []
    var prices: [String: Double] = [:]

    func isIncluded(_ line: MaterialTakeoff.Line) -> Bool {
        !excludedKeys.contains(line.key)
    }

    func price(for line: MaterialTakeoff.Line) -> Double? {
        prices[line.key]
    }

    /// Sum of entered prices over the included lines.
    func total(for takeoff: MaterialTakeoff) -> Double {
        takeoff.lines.reduce(0) { sum, line in
            guard isIncluded(line), let price = prices[line.key] else { return sum }
            return sum + price
        }
    }
}
