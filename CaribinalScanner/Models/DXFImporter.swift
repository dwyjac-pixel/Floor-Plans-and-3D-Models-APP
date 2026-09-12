import Foundation
import CoreGraphics
import UIKit

/// Reads AutoCAD / BricsCAD DXF drawings (ASCII) into trace-ready
/// geometry: exact-scale segments, corner candidates, and ready-made
/// outline proposals from closed polylines. Parsing is pure Foundation so
/// it can be tested off-device; rendering the trace background is UIKit.
enum DXFImporter {
    struct ImportResult {
        var segments: [(start: CGPoint, end: CGPoint)] = []   // metres, y-down
        var closedPolylines: [[CGPoint]] = []                 // metres, y-down
        var metersPerUnit: Double = 1
        var unitsName = "unitless"
        var boundsMeters: CGRect = .zero
    }

    // MARK: - Parsing (Foundation-only)

    static func parse(_ text: String) -> ImportResult? {
        // DXF is strictly alternating group-code / value lines.
        let rawLines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var pairs: [(code: Int, value: String)] = []
        var lineIndex = 0
        while lineIndex + 1 < rawLines.count {
            let codeText = rawLines[lineIndex].trimmingCharacters(in: .whitespaces)
            guard let code = Int(codeText) else {
                lineIndex += 1   // resync on corrupt input
                continue
            }
            pairs.append((code, rawLines[lineIndex + 1].trimmingCharacters(in: .whitespaces)))
            lineIndex += 2
        }
        guard !pairs.isEmpty else { return nil }

        var insunits: Int?
        var rawSegments: [(CGPoint, CGPoint)] = []   // drawing units, y-up
        var rawClosed: [[CGPoint]] = []

        var currentSection = ""
        var lastHeaderVariable = ""

        // Entity accumulation: values gathered until the next 0 code.
        var entityType = ""
        var entityValues: [(code: Int, value: String)] = []

        // POLYLINE … VERTEX … SEQEND accumulation.
        var polylineVertices: [CGPoint] = []
        var polylineClosed = false
        var insidePolyline = false

        func double(_ code: Int, in values: [(code: Int, value: String)]) -> Double? {
            values.first(where: { $0.code == code }).flatMap { Double($0.value) }
        }

        func finite(_ point: CGPoint) -> Bool {
            point.x.isFinite && point.y.isFinite
        }

        func appendSegment(_ a: CGPoint, _ b: CGPoint) {
            guard finite(a), finite(b) else { return }
            rawSegments.append((a, b))
        }

        func appendArcSegments(center: CGPoint, radius: Double,
                               startDegrees: Double, endDegrees: Double) {
            // Corrupt files can carry nan/inf here — never trap or spin.
            guard center.x.isFinite, center.y.isFinite,
                  radius.isFinite, radius > 0,
                  startDegrees.isFinite, endDegrees.isFinite else { return }
            var sweep = (endDegrees - startDegrees).truncatingRemainder(dividingBy: 360)
            if sweep <= 0 { sweep += 360 }   // DXF arcs run CCW
            let steps = min(max(4, Int(sweep / 15)), 360)
            var previous: CGPoint?
            for step in 0...steps {
                let angle = (startDegrees + sweep * Double(step) / Double(steps)) * .pi / 180
                let point = CGPoint(x: center.x + CGFloat(cos(angle) * radius),
                                    y: center.y + CGFloat(sin(angle) * radius))
                if let previous { appendSegment(previous, point) }
                previous = point
            }
        }

        // Emits an open POLYLINE's accumulated vertices — called from
        // SEQEND, but also when a sloppy writer never emits one.
        func closeOpenPolyline() {
            guard insidePolyline else { return }
            insidePolyline = false
            let vertices = polylineVertices.filter { finite($0) }
            polylineVertices = []
            guard vertices.count >= 2 else { return }
            for index in 0..<(vertices.count - 1) {
                appendSegment(vertices[index], vertices[index + 1])
            }
            if polylineClosed {
                appendSegment(vertices[vertices.count - 1], vertices[0])
                if vertices.count >= 3 { rawClosed.append(vertices) }
            }
        }

        func flushEntity() {
            defer {
                entityType = ""
                entityValues = []
            }
            guard currentSection == "ENTITIES" else { return }
            switch entityType {
            case "LINE":
                if let x1 = double(10, in: entityValues), let y1 = double(20, in: entityValues),
                   let x2 = double(11, in: entityValues), let y2 = double(21, in: entityValues) {
                    appendSegment(CGPoint(x: x1, y: y1), CGPoint(x: x2, y: y2))
                }
            case "LWPOLYLINE":
                // Vertices arrive as ordered 10/20 pairs.
                var vertices: [CGPoint] = []
                var pendingX: Double?
                for entry in entityValues {
                    if entry.code == 10 {
                        pendingX = Double(entry.value)
                    } else if entry.code == 20, let x = pendingX, let y = Double(entry.value) {
                        let vertex = CGPoint(x: x, y: y)
                        if finite(vertex) { vertices.append(vertex) }
                        pendingX = nil
                    }
                }
                let closed = (Int(double(70, in: entityValues) ?? 0) & 1) == 1
                guard vertices.count >= 2 else { break }
                for index in 0..<(vertices.count - 1) {
                    appendSegment(vertices[index], vertices[index + 1])
                }
                if closed {
                    appendSegment(vertices[vertices.count - 1], vertices[0])
                    if vertices.count >= 3 { rawClosed.append(vertices) }
                }
            case "POLYLINE":
                closeOpenPolyline()   // a new one without SEQEND flushes the old
                insidePolyline = true
                polylineVertices = []
                polylineClosed = (Int(double(70, in: entityValues) ?? 0) & 1) == 1
            case "VERTEX":
                if insidePolyline,
                   let x = double(10, in: entityValues), let y = double(20, in: entityValues) {
                    polylineVertices.append(CGPoint(x: x, y: y))
                }
            case "SEQEND":
                closeOpenPolyline()
            case "ARC":
                if let cx = double(10, in: entityValues), let cy = double(20, in: entityValues),
                   let radius = double(40, in: entityValues),
                   let start = double(50, in: entityValues), let end = double(51, in: entityValues) {
                    appendArcSegments(center: CGPoint(x: cx, y: cy), radius: radius,
                                      startDegrees: start, endDegrees: end)
                }
            case "CIRCLE":
                if let cx = double(10, in: entityValues), let cy = double(20, in: entityValues),
                   let radius = double(40, in: entityValues) {
                    appendArcSegments(center: CGPoint(x: cx, y: cy), radius: radius,
                                      startDegrees: 0, endDegrees: 360)
                }
            default:
                break
            }
        }

        for pair in pairs {
            if pair.code == 0 {
                flushEntity()
                switch pair.value {
                case "SECTION":
                    currentSection = ""
                case "ENDSEC":
                    currentSection = ""
                default:
                    entityType = pair.value
                }
                continue
            }
            if pair.code == 2, currentSection.isEmpty, entityType.isEmpty {
                currentSection = pair.value   // the name following SECTION
                continue
            }
            if currentSection == "HEADER" {
                if pair.code == 9 {
                    lastHeaderVariable = pair.value
                } else if pair.code == 70, lastHeaderVariable == "$INSUNITS" {
                    insunits = Int(pair.value)
                }
                continue
            }
            entityValues.append((pair.code, pair.value))
        }
        flushEntity()
        closeOpenPolyline()   // sloppy writers omit the trailing SEQEND

        guard !rawSegments.isEmpty else { return nil }

        // Units: $INSUNITS when present, size heuristic otherwise.
        let allPoints = rawSegments.flatMap { [$0.0, $0.1] }
        let minX = allPoints.map(\.x).min() ?? 0
        let maxX = allPoints.map(\.x).max() ?? 1
        let minY = allPoints.map(\.y).min() ?? 0
        let maxY = allPoints.map(\.y).max() ?? 1
        let extent = Double(max(maxX - minX, maxY - minY))

        // This app's own exports carry a signature comment; treat it as a
        // millimetre hint for files written before $INSUNITS was emitted.
        let ownSignature = pairs.contains {
            $0.code == 999 && $0.value.contains("millimetres, 1:1 model space")
        }

        let metersPerUnit: Double
        let unitsName: String
        switch insunits {
        case 1: (metersPerUnit, unitsName) = (0.0254, "inches")
        case 2: (metersPerUnit, unitsName) = (0.3048, "feet")
        case 4: (metersPerUnit, unitsName) = (0.001, "millimetres")
        case 5: (metersPerUnit, unitsName) = (0.01, "centimetres")
        case 6: (metersPerUnit, unitsName) = (1, "metres")
        case nil where ownSignature:
            (metersPerUnit, unitsName) = (0.001, "millimetres")
        default:
            if extent < 18 {
                (metersPerUnit, unitsName) = (1, "metres, assumed")
            } else if extent < 60 {
                (metersPerUnit, unitsName) = (0.3048, "feet, assumed")
            } else if extent < 3000 {
                (metersPerUnit, unitsName) = (0.0254, "inches, assumed")
            } else {
                (metersPerUnit, unitsName) = (0.001, "millimetres, assumed")
            }
        }

        // Y-flip (DXF is y-up, the plan space is y-down), normalise the
        // min corner to the origin, and convert to metres.
        func converted(_ p: CGPoint) -> CGPoint {
            CGPoint(x: Double(p.x - minX) * metersPerUnit,
                    y: Double(maxY - p.y) * metersPerUnit)
        }

        var result = ImportResult()
        result.metersPerUnit = metersPerUnit
        result.unitsName = unitsName
        result.segments = rawSegments.map { (converted($0.0), converted($0.1)) }
        result.closedPolylines = rawClosed.map { $0.map(converted) }
        result.boundsMeters = CGRect(x: 0, y: 0,
                                     width: Double(maxX - minX) * metersPerUnit,
                                     height: Double(maxY - minY) * metersPerUnit)
        return result
    }

    // MARK: - Trace background rendering (UIKit)

    static func renderImage(_ result: ImportResult,
                            maxPixels: CGFloat = 2400) -> (image: UIImage, metersPerPixel: Double)? {
        let bounds = result.boundsMeters
        guard bounds.width > 0.2, bounds.height > 0.2 else { return nil }
        let pixelsPerMeter = maxPixels / max(bounds.width, bounds.height)
        let size = CGSize(width: max(bounds.width * pixelsPerMeter, 40),
                          height: max(bounds.height * pixelsPerMeter, 40))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1   // point == pixel, matching the trace screen's math
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            cg.setStrokeColor(UIColor.black.cgColor)
            cg.setLineWidth(2)
            for segment in result.segments {
                cg.move(to: CGPoint(x: segment.start.x * pixelsPerMeter,
                                    y: segment.start.y * pixelsPerMeter))
                cg.addLine(to: CGPoint(x: segment.end.x * pixelsPerMeter,
                                       y: segment.end.y * pixelsPerMeter))
            }
            cg.strokePath()
        }
        return (image, Double(1 / pixelsPerMeter))
    }
}
