import Foundation
import CoreGraphics

/// Writes the floor plan as a DXF R12 (AC1009) CAD file — the dialect
/// every CAD package, plan service, and city permit office accepts.
/// Geometry is 1:1 model space in millimetres, Y up. Output is drafted,
/// not just traced: walls break at their openings, doors carry leaf +
/// swing arc, exterior walls get full dimension strings with extension
/// lines and tick marks, and rooms are labelled with their areas.
enum DXFExporter {

    private static let layers: [(name: String, color: Int)] = [
        ("WALLS", 7),        // white/black
        ("DOORS", 3),        // green
        ("WINDOWS", 5),      // blue
        ("OPENINGS", 4),     // cyan
        ("FIXTURES", 8),     // grey
        ("DIMENSIONS", 1),   // red
        ("LABELS", 2),       // yellow
        ("OUTLINE", 6),      // magenta — closed room boundaries
    ]

    private static let dimensionTextHeight = 150.0   // mm
    private static let fixtureTextHeight = 120.0
    private static let markerTextHeight = 200.0
    private static let roomTextHeight = 300.0
    private static let roomAreaTextHeight = 180.0
    private static let dimensionOffsetMeters = 0.5   // string offset off the wall

    static func make(plan: FloorPlanModel,
                     rooms: [RoomEntry],
                     markers: [PlanMarkers.Marker],
                     useImperial: Bool) -> String {
        var out: [String] = []

        func code(_ group: Int, _ value: String) {
            out.append(String(group))
            out.append(value)
        }
        func num(_ value: Double) -> String {
            String(format: "%.1f", value)
        }

        // Plan → CAD: metres → millimetres, Y flipped so the plan reads
        // the same way up as it does on screen.
        let maxY = Double(plan.bounds.maxY)
        func point(_ p: CGPoint) -> (x: Double, y: Double) {
            (Double(p.x) * 1000, (maxY - Double(p.y)) * 1000)
        }
        func planPoint(_ x: Double, _ z: Double) -> CGPoint {
            CGPoint(x: x, y: z)
        }

        func line(_ layer: String, _ a: CGPoint, _ b: CGPoint) {
            let p1 = point(a)
            let p2 = point(b)
            code(0, "LINE")
            code(8, layer)
            code(10, num(p1.x)); code(20, num(p1.y)); code(30, "0.0")
            code(11, num(p2.x)); code(21, num(p2.y)); code(31, "0.0")
        }

        func arc(_ layer: String, centerX: Double, centerY: Double,
                 radius: Double, startDegrees: Double, endDegrees: Double) {
            code(0, "ARC")
            code(8, layer)
            code(10, num(centerX)); code(20, num(centerY)); code(30, "0.0")
            code(40, num(radius))
            code(50, num(startDegrees))
            code(51, num(endDegrees))
        }

        func text(_ layer: String, _ string: String, atX x: Double, y: Double,
                  height: Double, rotation: Double = 0) {
            // R12 predates Unicode; keep values single-line ASCII so the
            // strictly alternating code/value stream can never desync.
            let sanitized = String(string
                .replacingOccurrences(of: "²", with: "2")
                .unicodeScalars.map { scalar -> Character in
                    if scalar == "\n" || scalar == "\r" || scalar == "\t" { return " " }
                    return scalar.isASCII ? Character(scalar) : "?"
                })
            code(0, "TEXT")
            code(8, layer)
            code(10, num(x)); code(20, num(y)); code(30, "0.0")
            code(40, num(height))
            code(1, sanitized)
            if rotation != 0 { code(50, num(rotation)) }
            code(72, "1")   // centred horizontally…
            code(11, num(x)); code(21, num(y)); code(31, "0.0")
            code(73, "2")   // …and vertically, on the alignment point
        }

        // MARK: Header

        code(999, "CaribinalScanner floor plan — millimetres, 1:1 model space")
        code(0, "SECTION"); code(2, "HEADER")
        code(9, "$ACADVER"); code(1, "AC1009")
        code(9, "$INSUNITS"); code(70, "4")   // millimetres
        code(9, "$INSBASE"); code(10, "0.0"); code(20, "0.0"); code(30, "0.0")
        // Extents include the dimension strings drawn outside the walls.
        let extentMargin = 850.0
        code(9, "$EXTMIN")
        code(10, num(Double(plan.bounds.minX) * 1000 - extentMargin))
        code(20, num(-extentMargin)); code(30, "0.0")
        code(9, "$EXTMAX")
        code(10, num(Double(plan.bounds.maxX) * 1000 + extentMargin))
        code(20, num((maxY - Double(plan.bounds.minY)) * 1000 + extentMargin)); code(30, "0.0")
        code(0, "ENDSEC")

        // MARK: Tables (linetype + layers)

        code(0, "SECTION"); code(2, "TABLES")
        code(0, "TABLE"); code(2, "LTYPE"); code(70, "1")
        code(0, "LTYPE"); code(2, "CONTINUOUS"); code(70, "0")
        code(3, "Solid line"); code(72, "65"); code(73, "0"); code(40, "0.0")
        code(0, "ENDTAB")
        code(0, "TABLE"); code(2, "LAYER"); code(70, String(layers.count + 1))
        code(0, "LAYER"); code(2, "0"); code(70, "0")   // the mandatory default layer
        code(62, "7"); code(6, "CONTINUOUS")
        for layer in layers {
            code(0, "LAYER"); code(2, layer.name); code(70, "0")
            code(62, String(layer.color)); code(6, "CONTINUOUS")
        }
        code(0, "ENDTAB")
        code(0, "ENDSEC")

        // MARK: Entities

        code(0, "SECTION"); code(2, "ENTITIES")

        if rooms.isEmpty {
            // Legacy plans (LiDAR / manual): straight segment export.
            for wall in plan.walls {
                line("WALLS", wall.start, wall.end)
                guard wall.lengthMeters > 0.3 else { continue }
                let p1 = point(wall.start)
                let p2 = point(wall.end)
                var angle = atan2(p2.y - p1.y, p2.x - p1.x) * 180 / .pi
                if angle > 90 { angle -= 180 }
                if angle <= -90 { angle += 180 }
                let radians = angle * .pi / 180
                text("DIMENSIONS", Measure.length(wall.lengthMeters, imperial: useImperial),
                     atX: (p1.x + p2.x) / 2 - sin(radians) * (dimensionTextHeight * 1.2),
                     y: (p1.y + p2.y) / 2 + cos(radians) * (dimensionTextHeight * 1.2),
                     height: dimensionTextHeight, rotation: angle)
            }
            for door in plan.doors { line("DOORS", door.start, door.end) }
            for window in plan.windows { line("WINDOWS", window.start, window.end) }
            for opening in plan.openings { line("OPENINGS", opening.start, opening.end) }
        }

        // Drafted per-room export: split walls, door symbology, dimension
        // strings — the drawing a CAD user expects to receive.
        // Probe points divide the dimension strings at every junction.
        var probePoints: [CGPoint] = []
        for entry in rooms {
            probePoints += entry.room.corners.map { planPoint($0.x, $0.z) }
            for interior in entry.room.interiorWalls {
                probePoints.append(planPoint(interior.start.x, interior.start.z))
                probePoints.append(planPoint(interior.end.x, interior.end.z))
            }
        }

        for entry in rooms {
            let room = entry.room
            let corners = room.corners
            guard corners.count >= 3 else { continue }
            let centroidX = corners.map(\.x).reduce(0, +) / Double(corners.count)
            let centroidZ = corners.map(\.z).reduce(0, +) / Double(corners.count)
            // Polygon winding decides the true interior side of every
            // outline edge — the centroid guess fails on L-shaped rooms.
            var doubledArea = 0.0
            for index in 0..<corners.count {
                let a = corners[index]
                let b = corners[(index + 1) % corners.count]
                doubledArea += a.x * b.z - b.x * a.z
            }
            let windingSign: Double = doubledArea > 0 ? 1 : -1

            func drawOpeningSymbol(_ opening: CornerRoom.Opening,
                                   startX: Double, startZ: Double,
                                   ux: Double, uz: Double,
                                   from: Double, to: Double,
                                   interiorNX: Double? = nil, interiorNZ: Double? = nil) {
                let width = to - from
                guard width >= 0.049 else { return }
                let fromPoint = planPoint(startX + ux * from, startZ + uz * from)
                let toPoint = planPoint(startX + ux * to, startZ + uz * to)
                let midX = (fromPoint.x + toPoint.x) / 2
                let midY = (fromPoint.y + toPoint.y) / 2
                // Perpendicular toward the room interior: exact (winding)
                // for outline walls, centroid heuristic for partitions.
                var nx: Double
                var nz: Double
                if let interiorNX, let interiorNZ {
                    nx = interiorNX
                    nz = interiorNZ
                } else {
                    nx = -uz
                    nz = ux
                    if nx * (centroidX - Double(midX)) + nz * (centroidZ - Double(midY)) < 0 {
                        nx = -nx
                        nz = -nz
                    }
                }
                if opening.swingsOutward ?? false {
                    nx = -nx
                    nz = -nz
                }

                func jambTicks(_ layer: String) {
                    for jamb in [fromPoint, toPoint] {
                        line(layer,
                             CGPoint(x: Double(jamb.x) + nx * 0.06, y: Double(jamb.y) + nz * 0.06),
                             CGPoint(x: Double(jamb.x) - nx * 0.06, y: Double(jamb.y) - nz * 0.06))
                    }
                }

                switch opening.kind {
                case .door:
                    let hingeAtEnd = opening.hingeOnEnd ?? false
                    let hinge = hingeAtEnd ? toPoint : fromPoint
                    let latch = hingeAtEnd ? fromPoint : toPoint
                    let leafTip = CGPoint(x: Double(hinge.x) + nx * width,
                                          y: Double(hinge.y) + nz * width)
                    line("DOORS", hinge, leafTip)
                    let hp = point(hinge)
                    let lp = point(latch)
                    let tp = point(leafTip)
                    let angleLeaf = atan2(tp.y - hp.y, tp.x - hp.x) * 180 / .pi
                    let angleLatch = atan2(lp.y - hp.y, lp.x - hp.x) * 180 / .pi
                    var sweep = angleLatch - angleLeaf
                    while sweep > 180 { sweep -= 360 }
                    while sweep < -180 { sweep += 360 }
                    if sweep >= 0 {
                        arc("DOORS", centerX: hp.x, centerY: hp.y, radius: width * 1000,
                            startDegrees: angleLeaf, endDegrees: angleLatch)
                    } else {
                        arc("DOORS", centerX: hp.x, centerY: hp.y, radius: width * 1000,
                            startDegrees: angleLatch, endDegrees: angleLeaf)
                    }
                case .closetDoor:
                    let depth = width / 4
                    let midOut = CGPoint(x: Double(midX) + nx * depth, y: Double(midY) + nz * depth)
                    line("DOORS", fromPoint, midOut)
                    line("DOORS", midOut, toPoint)
                case .window:
                    line("WINDOWS", fromPoint, toPoint)
                    jambTicks("WINDOWS")
                case .opening:
                    jambTicks("OPENINGS")
                }
            }

            // Outline walls: pieces between openings + a dimension string.
            for index in 0..<corners.count {
                let a = corners[index]
                let b = corners[(index + 1) % corners.count]
                let dx = b.x - a.x
                let dz = b.z - a.z
                let length = (dx * dx + dz * dz).squareRoot()
                guard length > 0.05 else { continue }
                let ux = dx / length
                let uz = dz / length

                let spans = room.openings
                    .filter { $0.interiorWallID == nil && $0.wallIndex == index }
                    .compactMap { opening -> (from: Double, to: Double, opening: CornerRoom.Opening)? in
                        let from = min(max(opening.offsetMeters, 0), length)
                        let to = min(from + max(opening.widthMeters, 0.05), length)
                        return to > from ? (from, to, opening) : nil
                    }
                    .sorted { $0.from < $1.from }

                var cursor = 0.0
                for span in spans {
                    let from = max(span.from, cursor)
                    if from > cursor + 0.01 {
                        line("WALLS",
                             planPoint(a.x + ux * cursor, a.z + uz * cursor),
                             planPoint(a.x + ux * from, a.z + uz * from))
                    }
                    drawOpeningSymbol(span.opening, startX: a.x, startZ: a.z,
                                      ux: ux, uz: uz, from: from, to: span.to,
                                      interiorNX: windingSign * -uz,
                                      interiorNZ: windingSign * ux)
                    cursor = max(cursor, span.to)
                }
                if length - cursor > 0.01 {
                    line("WALLS",
                         planPoint(a.x + ux * cursor, a.z + uz * cursor),
                         planPoint(a.x + ux * length, a.z + uz * length))
                }

                // Dimension string outside the wall (exact exterior side
                // from the winding), split at junctions.
                let nx = -(windingSign * -uz)
                let nz = -(windingSign * ux)
                var cuts: [Double] = [0]
                for probe in probePoints {
                    let t = ((Double(probe.x) - a.x) * dx + (Double(probe.y) - a.z) * dz)
                        / (length * length)
                    guard t > 0.02, t < 0.98 else { continue }
                    let px = a.x + dx * t
                    let pz = a.z + dz * t
                    let distance = ((Double(probe.x) - px) * (Double(probe.x) - px)
                        + (Double(probe.y) - pz) * (Double(probe.y) - pz)).squareRoot()
                    if distance < 0.08 { cuts.append(t) }
                }
                var merged: [Double] = []
                for t in cuts.sorted() where (t - (merged.last ?? -1)) * length > 0.05 {
                    merged.append(t)   // absolute 5 cm dedupe, not relative
                }
                if (merged.last ?? 0) < 0.999 { merged.append(1) }

                let offset = dimensionOffsetMeters
                line("DIMENSIONS",
                     planPoint(a.x + nx * offset, a.z + nz * offset),
                     planPoint(b.x + nx * offset, b.z + nz * offset))
                for t in merged {
                    let px = a.x + dx * t
                    let pz = a.z + dz * t
                    line("DIMENSIONS",
                         planPoint(px + nx * 0.08, pz + nz * 0.08),
                         planPoint(px + nx * (offset + 0.06), pz + nz * (offset + 0.06)))
                    // 45° tick across the dimension line.
                    let tickX = (ux + nx) / 1.414 * 0.06
                    let tickZ = (uz + nz) / 1.414 * 0.06
                    line("DIMENSIONS",
                         planPoint(px + nx * offset - tickX, pz + nz * offset - tickZ),
                         planPoint(px + nx * offset + tickX, pz + nz * offset + tickZ))
                }
                let p1 = point(planPoint(a.x, a.z))
                let p2 = point(planPoint(b.x, b.z))
                var textAngle = atan2(p2.y - p1.y, p2.x - p1.x) * 180 / .pi
                if textAngle > 90 { textAngle -= 180 }
                if textAngle <= -90 { textAngle += 180 }
                for k in 0..<(merged.count - 1) {
                    let subLength = length * (merged[k + 1] - merged[k])
                    guard subLength >= 0.15 else { continue }
                    let tMid = (merged[k] + merged[k + 1]) / 2
                    let anchor = point(planPoint(a.x + dx * tMid + nx * (offset + 0.16),
                                                 a.z + dz * tMid + nz * (offset + 0.16)))
                    text("DIMENSIONS", Measure.length(subLength, imperial: useImperial),
                         atX: anchor.x, y: anchor.y,
                         height: dimensionTextHeight, rotation: textAngle)
                }
            }

            // Interior walls: pieces between their openings.
            for interior in room.interiorWalls {
                let dx = interior.end.x - interior.start.x
                let dz = interior.end.z - interior.start.z
                let length = (dx * dx + dz * dz).squareRoot()
                guard length > 0.05 else { continue }
                let ux = dx / length
                let uz = dz / length
                let spans = room.openings
                    .filter { $0.interiorWallID == interior.id }
                    .compactMap { opening -> (from: Double, to: Double, opening: CornerRoom.Opening)? in
                        let from = min(max(opening.offsetMeters, 0), length)
                        let to = min(from + max(opening.widthMeters, 0.05), length)
                        return to > from ? (from, to, opening) : nil
                    }
                    .sorted { $0.from < $1.from }
                var cursor = 0.0
                for span in spans {
                    let from = max(span.from, cursor)
                    if from > cursor + 0.01 {
                        line("WALLS",
                             planPoint(interior.start.x + ux * cursor, interior.start.z + uz * cursor),
                             planPoint(interior.start.x + ux * from, interior.start.z + uz * from))
                    }
                    drawOpeningSymbol(span.opening,
                                      startX: interior.start.x, startZ: interior.start.z,
                                      ux: ux, uz: uz, from: from, to: span.to)
                    cursor = max(cursor, span.to)
                }
                if length - cursor > 0.01 {
                    line("WALLS",
                         planPoint(interior.start.x + ux * cursor, interior.start.z + uz * cursor),
                         planPoint(interior.start.x + ux * length, interior.start.z + uz * length))
                }
            }

            // The room boundary as one closed POLYLINE — a selectable
            // entity in CAD, and a round-trippable outline for imports.
            code(0, "POLYLINE")
            code(8, "OUTLINE")
            code(66, "1")
            code(70, "1")   // closed
            code(10, "0.0"); code(20, "0.0"); code(30, "0.0")   // spec dummy point
            for corner in corners {
                let vertex = point(planPoint(corner.x, corner.z))
                code(0, "VERTEX")
                code(8, "OUTLINE")
                code(10, num(vertex.x)); code(20, num(vertex.y)); code(30, "0.0")
            }
            code(0, "SEQEND")
            code(8, "OUTLINE")

            // Room name + area at the centroid.
            let labelAnchor = point(planPoint(centroidX, centroidZ))
            text("LABELS", entry.name.uppercased(),
                 atX: labelAnchor.x, y: labelAnchor.y, height: roomTextHeight)
            text("LABELS", Measure.area(room.floorAreaSquareMeters, imperial: useImperial),
                 atX: labelAnchor.x, y: labelAnchor.y - roomTextHeight - 120,
                 height: roomAreaTextHeight)
        }

        // Fixture footprints as closed outlines with a centred label.
        for object in plan.objects {
            let objectCorners = object.corners
            guard objectCorners.count >= 3 else { continue }
            for index in 0..<objectCorners.count {
                line("FIXTURES", objectCorners[index],
                     objectCorners[(index + 1) % objectCorners.count])
            }
            if !object.label.isEmpty {
                let center = point(object.center)
                text("FIXTURES", object.label, atX: center.x, y: center.y,
                     height: fixtureTextHeight)
            }
        }

        // Markers (mechanical, electrical, notes…).
        for marker in markers {
            let position = point(CGPoint(x: marker.x, y: marker.y))
            let string = marker.label.isEmpty
                ? marker.kind.rawValue
                : "\(marker.kind.rawValue): \(marker.label)"
            text("LABELS", string, atX: position.x, y: position.y,
                 height: markerTextHeight)
        }

        code(0, "ENDSEC")
        code(0, "EOF")
        return out.joined(separator: "\r\n") + "\r\n"
    }
}
