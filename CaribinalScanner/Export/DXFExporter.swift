import Foundation
import CoreGraphics

/// Writes the floor plan as a DXF R12 (AC1009) CAD file — the dialect
/// every CAD package, plan service, and city permit office accepts.
/// Geometry is 1:1 model space in millimetres, Y up, with walls, doors,
/// windows, fixtures, dimensions, and labels on their own layers.
enum DXFExporter {

    private static let layers: [(name: String, color: Int)] = [
        ("WALLS", 7),        // white/black
        ("DOORS", 3),        // green
        ("WINDOWS", 5),      // blue
        ("OPENINGS", 4),     // cyan
        ("FIXTURES", 8),     // grey
        ("DIMENSIONS", 1),   // red
        ("LABELS", 2),       // yellow
    ]

    private static let dimensionTextHeight = 150.0   // mm
    private static let fixtureTextHeight = 120.0
    private static let markerTextHeight = 200.0
    private static let roomTextHeight = 300.0

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

        func line(_ layer: String, _ a: CGPoint, _ b: CGPoint) {
            let p1 = point(a)
            let p2 = point(b)
            code(0, "LINE")
            code(8, layer)
            code(10, num(p1.x)); code(20, num(p1.y)); code(30, "0.0")
            code(11, num(p2.x)); code(21, num(p2.y)); code(31, "0.0")
        }

        func text(_ layer: String, _ string: String, atX x: Double, y: Double,
                  height: Double, rotation: Double = 0) {
            code(0, "TEXT")
            code(8, layer)
            code(10, num(x)); code(20, num(y)); code(30, "0.0")
            code(40, num(height))
            code(1, string)
            if rotation != 0 { code(50, num(rotation)) }
            code(72, "1")   // centred horizontally…
            code(11, num(x)); code(21, num(y)); code(31, "0.0")
            code(73, "2")   // …and vertically, on the alignment point
        }

        // MARK: Header

        code(999, "CaribinalScanner floor plan — millimetres, 1:1 model space")
        code(0, "SECTION"); code(2, "HEADER")
        code(9, "$ACADVER"); code(1, "AC1009")
        code(9, "$INSBASE"); code(10, "0.0"); code(20, "0.0"); code(30, "0.0")
        code(9, "$EXTMIN")
        code(10, num(Double(plan.bounds.minX) * 1000)); code(20, "0.0"); code(30, "0.0")
        code(9, "$EXTMAX")
        code(10, num(Double(plan.bounds.maxX) * 1000))
        code(20, num((maxY - Double(plan.bounds.minY)) * 1000)); code(30, "0.0")
        code(0, "ENDSEC")

        // MARK: Tables (linetype + layers)

        code(0, "SECTION"); code(2, "TABLES")
        code(0, "TABLE"); code(2, "LTYPE"); code(70, "1")
        code(0, "LTYPE"); code(2, "CONTINUOUS"); code(70, "0")
        code(3, "Solid line"); code(72, "65"); code(73, "0"); code(40, "0.0")
        code(0, "ENDTAB")
        code(0, "TABLE"); code(2, "LAYER"); code(70, String(layers.count))
        for layer in layers {
            code(0, "LAYER"); code(2, layer.name); code(70, "0")
            code(62, String(layer.color)); code(6, "CONTINUOUS")
        }
        code(0, "ENDTAB")
        code(0, "ENDSEC")

        // MARK: Entities

        code(0, "SECTION"); code(2, "ENTITIES")

        // Walls with a dimension at each wall's midpoint, rotated to read
        // along the wall.
        for wall in plan.walls {
            line("WALLS", wall.start, wall.end)
            guard wall.lengthMeters > 0.3 else { continue }
            let p1 = point(wall.start)
            let p2 = point(wall.end)
            let dx = p2.x - p1.x
            let dy = p2.y - p1.y
            var angle = atan2(dy, dx) * 180 / .pi
            if angle > 90 { angle -= 180 }
            if angle <= -90 { angle += 180 }
            let radians = angle * .pi / 180
            // Nudge the text off the wall line so it doesn't sit on it.
            let offsetX = -sin(radians) * (dimensionTextHeight * 1.2)
            let offsetY = cos(radians) * (dimensionTextHeight * 1.2)
            text("DIMENSIONS", Measure.length(wall.lengthMeters, imperial: useImperial),
                 atX: (p1.x + p2.x) / 2 + offsetX,
                 y: (p1.y + p2.y) / 2 + offsetY,
                 height: dimensionTextHeight, rotation: angle)
        }

        for door in plan.doors { line("DOORS", door.start, door.end) }
        for window in plan.windows { line("WINDOWS", window.start, window.end) }
        for opening in plan.openings { line("OPENINGS", opening.start, opening.end) }

        // Fixture footprints as closed outlines with a centred label.
        for object in plan.objects {
            let corners = object.corners
            guard corners.count >= 3 else { continue }
            for index in 0..<corners.count {
                line("FIXTURES", corners[index], corners[(index + 1) % corners.count])
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

        // Room names at each room's centroid on multi-room plans.
        if rooms.count > 1 {
            for entry in rooms where !entry.room.corners.isEmpty {
                let count = Double(entry.room.corners.count)
                let centroid = point(CGPoint(
                    x: entry.room.corners.map(\.x).reduce(0, +) / count,
                    y: entry.room.corners.map(\.z).reduce(0, +) / count))
                text("LABELS", entry.name.uppercased(),
                     atX: centroid.x, y: centroid.y, height: roomTextHeight)
            }
        }

        code(0, "ENDSEC")
        code(0, "EOF")
        return out.joined(separator: "\r\n") + "\r\n"
    }
}
