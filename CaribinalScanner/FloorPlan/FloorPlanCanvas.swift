import SwiftUI
import UIKit

/// Maps between plan coordinates (metres) and view coordinates (points),
/// fitting the plan bounds into the available size with padding.
struct PlanTransform {
    let scale: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat
    let bounds: CGRect

    /// `zoom` scales about the view centre — equivalent to a scaleEffect
    /// on the fitted plan, but applied in the drawing itself so strokes
    /// and text rasterise at full resolution instead of being blown up.
    init?(bounds: CGRect, size: CGSize, padding: CGFloat = 46, zoom: CGFloat = 1) {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let fitted = min((size.width - padding * 2) / bounds.width,
                         (size.height - padding * 2) / bounds.height)
        guard fitted > 0, fitted.isFinite, zoom > 0 else { return nil }
        scale = fitted * zoom
        offsetX = (size.width - bounds.width * scale) / 2
        offsetY = (size.height - bounds.height * scale) / 2
        self.bounds = bounds
    }

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - bounds.minX) * scale + offsetX,
                y: (p.y - bounds.minY) * scale + offsetY)
    }

    func toPlan(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offsetX) / scale + bounds.minX,
                y: (p.y - offsetY) / scale + bounds.minY)
    }
}

extension PlanMarkers.Marker.Kind {
    var sfSymbol: String {
        switch self {
        case .roomLabel: "textformat"
        case .mechanical: "gearshape.fill"
        case .electricalPanel: "bolt.fill"
        case .stairs: "stairs"
        case .beamPost: "circle.circle"
        case .note: "note.text"
        }
    }

    var color: Color {
        switch self {
        case .roomLabel: .gray
        case .mechanical: .brown
        case .electricalPanel: .red
        case .stairs: .purple
        case .beamPost: .gray
        case .note: .blue
        }
    }
}

/// Draws the 2D floor plan: walls as thick lines, doors and windows as
/// colour-coded segments cut into the walls, openings as gaps, detected
/// objects as grey footprints, wall lengths as labels, and user-placed
/// markers (room labels, mechanical, electrical, stairs, notes).
struct FloorPlanCanvas: View {
    let plan: FloorPlanModel
    var useImperial: Bool
    var markers: [PlanMarkers.Marker] = []
    var editHandles: [CGPoint] = []
    var draftSegment: (start: CGPoint, end: CGPoint)?
    var dragTipLabel: (anchor: CGPoint, lines: [String])?
    var roomLabels: [(name: String, area: String, center: CGPoint)] = []
    var showLabels: Bool = true
    var style: PlanStyle = .load()
    var layers: PlanLayers = .load()
    var exportBackground: Bool = false
    /// The view's zoom factor, applied inside the drawing rather than as
    /// a scaleEffect, so strokes and text stay sharp at any zoom. Labels
    /// grow with the plan up to 1.75× and then hold, so zooming in keeps
    /// the numbers legible without letting them take over the drawing.
    var zoom: CGFloat = 1
    /// View rotation and pan, also applied inside the drawing — the canvas
    /// renders exactly the visible window, so panning or rotating a zoomed
    /// plan never runs off the edge of a pre-rendered bitmap.
    var rotationRadians: Double = 0
    var panOffset: CGSize = .zero
    /// QA-057: during a corner drag the room's bounds change every frame, so
    /// re-fitting to plan.bounds re-centres the drawing and the dragged corner
    /// drifts from the finger. The editor passes the bounds captured at drag
    /// start so the fit stays frozen for the duration of the drag.
    var boundsOverride: CGRect? = nil

    /// A near-white wall colour would vanish on the white export page.
    private static func isTooLightForExport(_ hex: String) -> Bool {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let int = UInt64(value, radix: 16) else { return false }
        let red = Double((int >> 16) & 0xFF) / 255
        let green = Double((int >> 8) & 0xFF) / 255
        let blue = Double(int & 0xFF) / 255
        return (0.299 * red + 0.587 * green + 0.114 * blue) > 0.72
    }

    var body: some View {
        Canvas { context, size in
            let z = max(0.25, min(zoom, 12))
            guard let transform = PlanTransform(bounds: boundsOverride ?? plan.bounds, size: size, zoom: z) else { return }
            let ls = min(z, 1.75)

            // Pan + rotation about the view centre, applied per point —
            // the same mapping the screen's gesture code uses. Labels are
            // drawn after this mapping, so they stay horizontal even when
            // the plan is rotated.
            let viewCenter = CGPoint(x: size.width / 2, y: size.height / 2)
            let cosF = CGFloat(cos(rotationRadians))
            let sinF = CGFloat(sin(rotationRadians))
            func view(_ p: CGPoint) -> CGPoint {
                let q = transform.toView(p)
                let dx = q.x - viewCenter.x
                let dy = q.y - viewCenter.y
                return CGPoint(x: viewCenter.x + dx * cosF - dy * sinF + panOffset.width,
                               y: viewCenter.y + dx * sinF + dy * cosF + panOffset.height)
            }
            /// Rotates a plan-space direction into view space.
            func viewDirection(_ d: CGPoint) -> CGPoint {
                CGPoint(x: d.x * cosF - d.y * sinF, y: d.x * sinF + d.y * cosF)
            }

            // Everything is drawn in final screen coordinates, so culling
            // is a plain pane-rect test, padded for strokes and label
            // standoffs — deep zooms only pay for what's on screen.
            let cullRect = CGRect(origin: .zero, size: size)
                .insetBy(dx: -120 * ls - 8 * z, dy: -120 * ls - 8 * z)
            func onScreen(_ a: CGPoint, _ b: CGPoint) -> Bool {
                cullRect.intersects(CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                           width: abs(a.x - b.x), height: abs(a.y - b.y)))
            }
            let visibleWalls = plan.walls.filter { $0.isPerimeter || layers.interiorWalls }
            let baseWallColor: Color = (exportBackground && Self.isTooLightForExport(style.wallHex))
                ? .black : style.wallColor

            func strokeSegment(_ segment: PlanSegment, color: Color, lineWidth: CGFloat,
                               cap: CGLineCap = .round) {
                let a = view(segment.start)
                let b = view(segment.end)
                guard onScreen(a, b) else { return }
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                context.stroke(path, with: .color(color),
                               style: StrokeStyle(lineWidth: lineWidth, lineCap: cap))
            }

            if layers.fixtures {
            for object in plan.objects {
                guard object.corners.count >= 3 else { continue }
                var path = Path()
                path.move(to: view(object.corners[0]))
                for corner in object.corners.dropFirst() {
                    path.addLine(to: view(corner))
                }
                path.closeSubpath()
                guard cullRect.intersects(path.boundingRect) else { continue }
                context.fill(path, with: .color(.gray.opacity(0.12)))
                context.stroke(path, with: .color(.gray.opacity(0.4)), lineWidth: z)

                // Kind-specific plan symbols.
                let rad = object.rotationDegrees * .pi / 180
                let w = object.size.width
                let d = object.size.height
                func localPoint(_ lx: CGFloat, _ ly: CGFloat) -> CGPoint {
                    let px = object.center.x + lx * cos(rad) - ly * sin(rad)
                    let py = object.center.y + lx * sin(rad) + ly * cos(rad)
                    return view(CGPoint(x: px, y: py))
                }
                func localLine(_ ax: CGFloat, _ ay: CGFloat, _ bx: CGFloat, _ by: CGFloat) {
                    var line = Path()
                    line.move(to: localPoint(ax, ay))
                    line.addLine(to: localPoint(bx, by))
                    context.stroke(line, with: .color(.gray.opacity(0.7)), lineWidth: z)
                }
                func localCircle(_ cx: CGFloat, _ cy: CGFloat, radiusMeters: CGFloat) {
                    let center = localPoint(cx, cy)
                    let radius = radiusMeters * transform.scale
                    let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                        width: radius * 2, height: radius * 2))
                    context.stroke(circle, with: .color(.gray.opacity(0.7)), lineWidth: z)
                }

                switch object.fixtureKind {
                case .stairs:
                    let treads = max(3, Int(w / 0.25))
                    for tread in 1..<treads {
                        let x = -w / 2 + w * CGFloat(tread) / CGFloat(treads)
                        localLine(x, -d / 2, x, d / 2)
                    }
                    localLine(-w / 2 + 0.15, 0, w / 2 - 0.15, 0)
                    localLine(w / 2 - 0.32, -0.1, w / 2 - 0.15, 0)
                    localLine(w / 2 - 0.32, 0.1, w / 2 - 0.15, 0)
                case .toilet:
                    localLine(-w / 2, -d / 2 + 0.18, w / 2, -d / 2 + 0.18)
                    localCircle(0, d * 0.15, radiusMeters: min(w, d) * 0.28)
                case .vanity:
                    localCircle(0, 0, radiusMeters: min(w, d) * 0.28)
                case .bedQueen, .bedSingle:
                    localLine(-w / 2 + 0.08, -d / 2 + 0.45, w / 2 - 0.08, -d / 2 + 0.45)
                case .washer, .dryer, .waterHeater:
                    localCircle(0, 0, radiusMeters: min(w, d) * 0.32)
                case .sofa:
                    localLine(-w / 2 + 0.05, -d / 2 + 0.2, w / 2 - 0.05, -d / 2 + 0.2)
                case .tubShower:
                    var inner = Path()
                    inner.move(to: localPoint(-w / 2 + 0.07, -d / 2 + 0.07))
                    inner.addLine(to: localPoint(w / 2 - 0.07, -d / 2 + 0.07))
                    inner.addLine(to: localPoint(w / 2 - 0.07, d / 2 - 0.07))
                    inner.addLine(to: localPoint(-w / 2 + 0.07, d / 2 - 0.07))
                    inner.closeSubpath()
                    context.stroke(inner, with: .color(.gray.opacity(0.7)), lineWidth: z)
                case .bulkhead:
                    // Overhead object convention: dashed outline + label.
                    var dashed = Path()
                    dashed.move(to: localPoint(-w / 2 + 0.02, -d / 2 + 0.02))
                    dashed.addLine(to: localPoint(w / 2 - 0.02, -d / 2 + 0.02))
                    dashed.addLine(to: localPoint(w / 2 - 0.02, d / 2 - 0.02))
                    dashed.addLine(to: localPoint(-w / 2 + 0.02, d / 2 - 0.02))
                    dashed.closeSubpath()
                    context.stroke(dashed, with: .color(.gray.opacity(0.8)),
                                   style: StrokeStyle(lineWidth: 1.2, dash: [6, 4]))
                    context.draw(Text("BULKHEAD")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.secondary), at: localPoint(0, 0))
                case .shower:
                    var stall = Path()
                    stall.move(to: localPoint(-w / 2 + 0.06, -d / 2 + 0.06))
                    stall.addLine(to: localPoint(w / 2 - 0.06, -d / 2 + 0.06))
                    stall.addLine(to: localPoint(w / 2 - 0.06, d / 2 - 0.06))
                    stall.addLine(to: localPoint(-w / 2 + 0.06, d / 2 - 0.06))
                    stall.closeSubpath()
                    context.stroke(stall, with: .color(.gray.opacity(0.7)), lineWidth: z)
                    localCircle(0, 0, radiusMeters: 0.05)
                    localLine(-w / 2 + 0.06, -d / 2 + 0.06, 0, 0)
                default:
                    if !object.label.isEmpty {
                        let cx = object.corners.map(\.x).reduce(0, +) / CGFloat(object.corners.count)
                        let cy = object.corners.map(\.y).reduce(0, +) / CGFloat(object.corners.count)
                        context.draw(Text(object.label).font(.system(size: 9 * ls)).foregroundStyle(.secondary),
                                     at: view(CGPoint(x: cx, y: cy)))
                    }
                }
            }
            }

            let background = exportBackground ? Color.white : style.backgroundColor
            let wallWidth = CGFloat(style.wallWidth) * z
            let gapWidth = wallWidth + 2 * z
            let accentWidth = max(wallWidth - 2 * z, 2 * z)

            // Walls end flat at their endpoints so a partition teeing into
            // another wall can't bleed across it; corners where two walls
            // actually meet get a round join disc instead.
            for wall in visibleWalls {
                var color = wall.colorHex.flatMap { Color(hexString: $0) } ?? baseWallColor
                if exportBackground, let hex = wall.colorHex, Self.isTooLightForExport(hex) {
                    color = .black
                }
                strokeSegment(wall, color: color, lineWidth: wallWidth, cap: .butt)
            }
            var jointPoints: [String: CGPoint] = [:]
            var jointCounts: [String: Int] = [:]
            for wall in visibleWalls {
                for endpoint in [wall.start, wall.end] {
                    let key = "\(Int((endpoint.x * 50).rounded())),\(Int((endpoint.y * 50).rounded()))"
                    jointPoints[key] = endpoint
                    jointCounts[key, default: 0] += 1
                }
            }
            for (key, count) in jointCounts where count >= 2 {
                guard let point = jointPoints[key] else { continue }
                let center = view(point)
                guard cullRect.contains(center) else { continue }
                let radius = wallWidth / 2
                let disc = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                  width: radius * 2, height: radius * 2))
                context.fill(disc, with: .color(baseWallColor))
            }

            // Drafting-style double-line walls: hollow out the stroke so
            // every wall reads as two parallel lines, like a drawn plan.
            if style.doubleLineWalls, wallWidth >= 4 * z {
                let hollowWidth = wallWidth - 2.4 * z
                for wall in visibleWalls {
                    strokeSegment(wall, color: background, lineWidth: hollowWidth, cap: .butt)
                }
                for (key, count) in jointCounts where count >= 2 {
                    guard let point = jointPoints[key] else { continue }
                    let center = view(point)
                    guard cullRect.contains(center) else { continue }
                    let radius = hollowWidth / 2
                    let disc = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                      width: radius * 2, height: radius * 2))
                    context.fill(disc, with: .color(background))
                }
            }
            // Interior direction for symbols: toward the middle of the plan.
            let planCenter = view(CGPoint(x: plan.bounds.midX, y: plan.bounds.midY))
            func interiorNormal(_ s: CGPoint, _ e: CGPoint) -> CGPoint {
                let dx = e.x - s.x
                let dy = e.y - s.y
                let length = max(hypot(dx, dy), 0.001)
                var nx = -dy / length
                var ny = dx / length
                let mid = CGPoint(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2)
                if nx * (planCenter.x - mid.x) + ny * (planCenter.y - mid.y) < 0 {
                    nx = -nx
                    ny = -ny
                }
                return CGPoint(x: nx, y: ny)
            }

            if layers.openings {
            for opening in plan.openings {
                let s = view(opening.start)
                let e = view(opening.end)
                guard onScreen(s, e) else { continue }
                strokeSegment(opening, color: background, lineWidth: gapWidth)
                // Jamb ticks so a cased opening reads as intentional.
                let n = opening.interiorNormal ?? interiorNormal(s, e)
                for end in [s, e] {
                    var tick = Path()
                    tick.move(to: CGPoint(x: end.x + n.x * (gapWidth / 2 + 2 * z),
                                          y: end.y + n.y * (gapWidth / 2 + 2 * z)))
                    tick.addLine(to: CGPoint(x: end.x - n.x * (gapWidth / 2 + 2 * z),
                                             y: end.y - n.y * (gapWidth / 2 + 2 * z)))
                    context.stroke(tick, with: .color(baseWallColor.opacity(0.7)), lineWidth: 1.2 * z)
                }
            }
            for door in plan.doors {
                let s = view(door.start)
                let e = view(door.end)
                let width = hypot(e.x - s.x, e.y - s.y)
                // The swing arc reaches a leaf-width past the jamb.
                guard cullRect.insetBy(dx: -width, dy: -width)
                    .intersects(CGRect(x: min(s.x, e.x), y: min(s.y, e.y),
                                       width: abs(s.x - e.x), height: abs(s.y - e.y))) else { continue }
                strokeSegment(door, color: background, lineWidth: gapWidth)
                guard width > 4 * z else {
                    strokeSegment(door, color: style.doorColor, lineWidth: accentWidth)
                    continue
                }
                var n = door.interiorNormal ?? interiorNormal(s, e)
                if door.swingsOutward {
                    n = CGPoint(x: -n.x, y: -n.y)
                }
                if door.kind == .closetDoor {
                    // Bifold pair: two V folds projecting to the swing side.
                    let depth = min(width / 4, 26 * z)
                    var folds = Path()
                    folds.move(to: s)
                    folds.addLine(to: CGPoint(x: s.x + (e.x - s.x) * 0.25 + n.x * depth,
                                              y: s.y + (e.y - s.y) * 0.25 + n.y * depth))
                    folds.addLine(to: CGPoint(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2))
                    folds.addLine(to: CGPoint(x: s.x + (e.x - s.x) * 0.75 + n.x * depth,
                                              y: s.y + (e.y - s.y) * 0.75 + n.y * depth))
                    folds.addLine(to: e)
                    context.stroke(folds, with: .color(style.doorColor), lineWidth: 1.5 * z)
                } else {
                    // Standard swing: door leaf perpendicular at the hinge
                    // jamb plus the quarter-circle arc to the latch side.
                    let hinge = door.hingeOnEnd ? e : s
                    let latch = door.hingeOnEnd ? s : e
                    let leafTip = CGPoint(x: hinge.x + n.x * width, y: hinge.y + n.y * width)
                    var leaf = Path()
                    leaf.move(to: hinge)
                    leaf.addLine(to: leafTip)
                    context.stroke(leaf, with: .color(style.doorColor), lineWidth: 1.5 * z)

                    let startAngle = atan2(leafTip.y - hinge.y, leafTip.x - hinge.x)
                    let endAngle = atan2(latch.y - hinge.y, latch.x - hinge.x)
                    var sweep = endAngle - startAngle
                    while sweep > .pi { sweep -= 2 * .pi }
                    while sweep < -.pi { sweep += 2 * .pi }
                    var arc = Path()
                    let steps = 14
                    for step in 0...steps {
                        let angle = startAngle + sweep * CGFloat(step) / CGFloat(steps)
                        let point = CGPoint(x: hinge.x + cos(angle) * width,
                                            y: hinge.y + sin(angle) * width)
                        if step == 0 {
                            arc.move(to: point)
                        } else {
                            arc.addLine(to: point)
                        }
                    }
                    context.stroke(arc, with: .color(style.doorColor),
                                   style: StrokeStyle(lineWidth: 1.2 * z, dash: [4 * z, 3 * z]))
                }
            }
            for window in plan.windows {
                strokeSegment(window, color: background, lineWidth: gapWidth)
                strokeSegment(window, color: style.windowColor, lineWidth: accentWidth)
            }
            }

            if showLabels && (layers.dimensions || layers.rightAngles) {
                let walls = visibleWalls

                // Junctions split a wall's dimension into the segment
                // lengths a builder needs: wherever another wall (or the
                // one being sketched) tees into or crosses this wall, the
                // label divides at that point.
                func projectionT(_ p: CGPoint, onto wall: PlanSegment) -> (t: CGFloat, distance: CGFloat)? {
                    let dx = wall.end.x - wall.start.x
                    let dy = wall.end.y - wall.start.y
                    let lengthSq = dx * dx + dy * dy
                    guard lengthSq > 0.0001 else { return nil }
                    let t = ((p.x - wall.start.x) * dx + (p.y - wall.start.y) * dy) / lengthSq
                    let px = wall.start.x + dx * t
                    let py = wall.start.y + dy * t
                    return (t, hypot(p.x - px, p.y - py))
                }
                func crossingT(of probe: (start: CGPoint, end: CGPoint),
                               on wall: PlanSegment) -> CGFloat? {
                    let rx = wall.end.x - wall.start.x
                    let ry = wall.end.y - wall.start.y
                    let sx = probe.end.x - probe.start.x
                    let sy = probe.end.y - probe.start.y
                    let denom = rx * sy - ry * sx
                    guard abs(denom) > 0.000001 else { return nil }
                    let qpx = probe.start.x - wall.start.x
                    let qpy = probe.start.y - wall.start.y
                    let t = (qpx * sy - qpy * sx) / denom
                    let u = (qpx * ry - qpy * rx) / denom
                    guard u > 0.02, u < 0.98 else { return nil }
                    return t
                }

                var probes: [(start: CGPoint, end: CGPoint)] = walls.map { ($0.start, $0.end) }
                if let draftSegment {
                    probes.append(draftSegment)
                }

                // True 90° junctions get the drafting right-angle square.
                var rightAngles: [(anchor: CGPoint, u: CGPoint, v: CGPoint)] = []
                func unitVector(_ from: CGPoint, _ to: CGPoint) -> CGPoint? {
                    let dx = to.x - from.x
                    let dy = to.y - from.y
                    let length = hypot(dx, dy)
                    guard length > 0.05 else { return nil }
                    return CGPoint(x: dx / length, y: dy / length)
                }
                func addRightAngle(at anchor: CGPoint, _ a: CGPoint?, _ b: CGPoint?) {
                    guard let a, let b, abs(a.x * b.x + a.y * b.y) < 0.04 else { return }
                    rightAngles.append((anchor, a, b))
                }

                var divisions: [[CGFloat]] = Array(repeating: [], count: walls.count)
                for (index, wall) in walls.enumerated() {
                    let hostUnit = unitVector(wall.start, wall.end)
                    for (probeIndex, probe) in probes.enumerated() where probeIndex != index {
                        for (endpoint, farEnd) in [(probe.start, probe.end), (probe.end, probe.start)] {
                            if let hit = projectionT(endpoint, onto: wall),
                               hit.distance < 0.08, hit.t > 0.02, hit.t < 0.98 {
                                divisions[index].append(hit.t)
                                addRightAngle(at: endpoint, hostUnit, unitVector(endpoint, farEnd))
                            }
                        }
                        if let t = crossingT(of: probe, on: wall), t > 0.02, t < 0.98 {
                            divisions[index].append(t)
                            if probeIndex > index {
                                let crossing = CGPoint(x: wall.start.x + (wall.end.x - wall.start.x) * t,
                                                       y: wall.start.y + (wall.end.y - wall.start.y) * t)
                                addRightAngle(at: crossing, hostUnit,
                                              unitVector(probe.start, probe.end))
                            }
                        }
                    }
                }

                // Corners where two walls share an endpoint (room corners,
                // partitions landing on corners).
                for i in 0..<walls.count {
                    for j in (i + 1)..<walls.count {
                        for (pa, paFar) in [(walls[i].start, walls[i].end), (walls[i].end, walls[i].start)] {
                            for (pb, pbFar) in [(walls[j].start, walls[j].end), (walls[j].end, walls[j].start)] {
                                if hypot(pa.x - pb.x, pa.y - pb.y) < 0.02 {
                                    addRightAngle(at: pa, unitVector(pa, paFar), unitVector(pb, pbFar))
                                }
                            }
                        }
                    }
                }

                // Exterior dimension string, drafting style: extension
                // lines out from the wall, a dimension line with 45° ticks
                // at every junction, and the lengths reading along it —
                // keeps the numbers out of small rooms.
                func drawDimensionString(_ wall: PlanSegment, cuts: [CGFloat]) {
                    let s = view(wall.start)
                    let e = view(wall.end)
                    guard onScreen(s, e) else { return }
                    let dx = e.x - s.x
                    let dy = e.y - s.y
                    let viewLength = max(hypot(dx, dy), 0.001)
                    let ux = dx / viewLength
                    let uy = dy / viewLength
                    var nx = -uy
                    var ny = ux
                    let mid = CGPoint(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2)
                    if nx * (planCenter.x - mid.x) + ny * (planCenter.y - mid.y) > 0 {
                        nx = -nx
                        ny = -ny
                    }
                    let lineColor = baseWallColor.opacity(0.55)
                    let offset: CGFloat = 22 * ls

                    var dimLine = Path()
                    dimLine.move(to: CGPoint(x: s.x + nx * offset, y: s.y + ny * offset))
                    dimLine.addLine(to: CGPoint(x: e.x + nx * offset, y: e.y + ny * offset))
                    context.stroke(dimLine, with: .color(lineColor), lineWidth: 0.8 * ls)

                    for t in cuts {
                        let px = s.x + dx * t
                        let py = s.y + dy * t
                        var extension_ = Path()
                        extension_.move(to: CGPoint(x: px + nx * 4 * ls, y: py + ny * 4 * ls))
                        extension_.addLine(to: CGPoint(x: px + nx * (offset + 5 * ls), y: py + ny * (offset + 5 * ls)))
                        context.stroke(extension_, with: .color(lineColor), lineWidth: 0.8 * ls)

                        let cx = px + nx * offset
                        let cy = py + ny * offset
                        let tx = (ux + nx) / 1.414 * 5 * ls
                        let ty = (uy + ny) / 1.414 * 5 * ls
                        var tick = Path()
                        tick.move(to: CGPoint(x: cx - tx, y: cy - ty))
                        tick.addLine(to: CGPoint(x: cx + tx, y: cy + ty))
                        context.stroke(tick, with: .color(baseWallColor.opacity(0.8)), lineWidth: 1.3 * ls)
                    }

                    var angle = atan2(dy, dx)
                    if angle > .pi / 2 { angle -= .pi }
                    if angle <= -.pi / 2 { angle += .pi }
                    for k in 0..<(cuts.count - 1) {
                        let subLength = wall.lengthMeters * Double(cuts[k + 1] - cuts[k])
                        guard subLength >= 0.15 else { continue }
                        let tMid = (cuts[k] + cuts[k + 1]) / 2
                        var rotated = context
                        rotated.translateBy(x: s.x + dx * tMid + nx * (offset + 9 * ls),
                                            y: s.y + dy * tMid + ny * (offset + 9 * ls))
                        rotated.rotate(by: Angle(radians: Double(angle)))
                        rotated.draw(Text(Measure.length(subLength, imperial: useImperial))
                            .font(.system(size: 9 * ls))
                            .foregroundStyle(.secondary), at: .zero)
                    }
                }

                for (index, wall) in walls.enumerated() {
                    guard layers.dimensions else { break }
                    var cuts: [CGFloat] = [0]
                    for t in divisions[index].sorted() where t - (cuts.last ?? 0) > 0.02 {
                        cuts.append(t)
                    }
                    cuts.append(1)

                    if wall.isPerimeter {
                        drawDimensionString(wall, cuts: cuts)
                        continue
                    }

                    // Interior walls keep their labels beside the wall.
                    let s = view(wall.start)
                    let e = view(wall.end)
                    let dx = e.x - s.x
                    let dy = e.y - s.y
                    let viewLength = max(hypot(dx, dy), 0.001)
                    let nx = -dy / viewLength
                    let ny = dx / viewLength

                    func drawLength(_ meters: Double, atT t: CGFloat) {
                        let point = CGPoint(x: s.x + dx * t + nx * 14 * ls,
                                            y: s.y + dy * t + ny * 14 * ls)
                        guard cullRect.contains(point) else { return }
                        context.draw(Text(Measure.length(meters, imperial: useImperial))
                            .font(.system(size: 11 * ls))
                            .foregroundStyle(.secondary), at: point)
                    }

                    if cuts.count == 2 {
                        guard wall.lengthMeters >= 0.6 else { continue }
                        drawLength(wall.lengthMeters, atT: 0.5)
                        continue
                    }
                    for k in 0..<(cuts.count - 1) {
                        let subLength = wall.lengthMeters * Double(cuts[k + 1] - cuts[k])
                        guard subLength >= 0.25 else { continue }
                        drawLength(subLength, atT: (cuts[k] + cuts[k + 1]) / 2)
                    }
                    for k in 1..<(cuts.count - 1) {
                        let cx = s.x + dx * cuts[k]
                        let cy = s.y + dy * cuts[k]
                        var tick = Path()
                        tick.move(to: CGPoint(x: cx + nx * 6 * ls, y: cy + ny * 6 * ls))
                        tick.addLine(to: CGPoint(x: cx - nx * 6 * ls, y: cy - ny * 6 * ls))
                        context.stroke(tick, with: .color(.gray.opacity(0.7)), lineWidth: ls)
                    }
                }

                // The right-angle squares: drawn in the angle between the
                // two wall directions, drafting style, rotated into view
                // space with the plan.
                let squareSide: CGFloat = 7 * ls
                for marker in rightAngles where layers.rightAngles {
                    let origin = view(marker.anchor)
                    guard cullRect.contains(origin) else { continue }
                    let u = viewDirection(marker.u)
                    let v = viewDirection(marker.v)
                    let ux = u.x * squareSide
                    let uy = u.y * squareSide
                    let vx = v.x * squareSide
                    let vy = v.y * squareSide
                    var square = Path()
                    square.move(to: CGPoint(x: origin.x + ux, y: origin.y + uy))
                    square.addLine(to: CGPoint(x: origin.x + ux + vx, y: origin.y + uy + vy))
                    square.addLine(to: CGPoint(x: origin.x + vx, y: origin.y + vy))
                    context.stroke(square, with: .color(.green.opacity(0.85)), lineWidth: 1.2 * ls)
                }
            }

            // Wall being sketched: dashed preview from start to finger.
            if let draft = draftSegment {
                var path = Path()
                path.move(to: view(draft.start))
                path.addLine(to: view(draft.end))
                context.stroke(path, with: .color(.orange),
                               style: StrokeStyle(lineWidth: max(wallWidth - z, 2 * z),
                                                  lineCap: .round, dash: [6 * z, 4 * z]))
            }

            // Open-ring handles: the vertex, the wall angle, and the 90°
            // square stay visible through the middle; the pin dot marks
            // the exact endpoint.
            for handle in editHandles {
                let position = view(handle)
                guard cullRect.contains(position) else { continue }
                let ringRadius = 8 * ls
                let ring = Path(ellipseIn: CGRect(x: position.x - ringRadius, y: position.y - ringRadius,
                                                  width: ringRadius * 2, height: ringRadius * 2))
                context.stroke(ring, with: .color(.orange), lineWidth: 1.8 * ls)
                let dotRadius = 2 * ls
                let dot = Path(ellipseIn: CGRect(x: position.x - dotRadius, y: position.y - dotRadius,
                                                 width: dotRadius * 2, height: dotRadius * 2))
                context.fill(dot, with: .color(.orange))
            }

            // Live lengths pinned beside the point being dragged, so a
            // zoomed-in edit never needs a zoom-out to check the number.
            // The drag readout is a screen-space HUD pinned to the finger —
            // constant size regardless of zoom.
            if let dragTipLabel {
                let anchor = view(dragTipLabel.anchor)
                var lineY = anchor.y - 22
                for line in dragTipLabel.lines {
                    let resolved = context.resolve(Text(line)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.orange))
                    let textSize = resolved.measure(in: CGSize(width: 220, height: 40))
                    var rect = CGRect(x: anchor.x + 14,
                                      y: lineY - textSize.height / 2 - 2,
                                      width: textSize.width + 12,
                                      height: textSize.height + 5)
                    if rect.maxX > size.width - 4 {
                        rect.origin.x = anchor.x - 14 - rect.width
                    }
                    if rect.minY < 4 {
                        rect.origin.y = anchor.y + 16
                        lineY = rect.midY
                    }
                    context.fill(Path(roundedRect: rect, cornerRadius: 5),
                                 with: .color(Color(uiColor: .systemBackground).opacity(0.9)))
                    context.stroke(Path(roundedRect: rect, cornerRadius: 5),
                                   with: .color(.orange.opacity(0.5)), lineWidth: 1)
                    context.draw(resolved, at: CGPoint(x: rect.midX, y: rect.midY))
                    lineY = rect.minY - textSize.height / 2 - 6
                }
            }

            // Room names at each room's centre, drafting style.
            if showLabels {
                for label in roomLabels {
                    let position = view(label.center)
                    guard cullRect.contains(position) else { continue }
                    context.draw(Text(label.name.uppercased())
                        .font(.system(size: 10 * ls, weight: .semibold))
                        .foregroundStyle(.primary), at: position)
                    context.draw(Text(label.area)
                        .font(.system(size: 8 * ls))
                        .foregroundStyle(.secondary),
                                 at: CGPoint(x: position.x, y: position.y + 12 * ls))
                }
            }

            for marker in markers where layers.markers {
                let position = view(CGPoint(x: marker.x, y: marker.y))
                guard cullRect.contains(position) else { continue }
                if marker.kind == .roomLabel {
                    let text = Text(marker.label.isEmpty ? "Room" : marker.label)
                        .font(.system(size: 11 * ls, weight: .semibold))
                    context.draw(text, at: position)
                } else {
                    let radius = 8 * ls
                    let circle = Path(ellipseIn: CGRect(x: position.x - radius, y: position.y - radius,
                                                        width: radius * 2, height: radius * 2))
                    context.fill(circle, with: .color(marker.kind.color))
                    context.draw(Text(Image(systemName: marker.kind.sfSymbol))
                        .font(.system(size: 8 * ls, weight: .bold))
                        .foregroundStyle(.white), at: position)
                    if !marker.label.isEmpty {
                        context.draw(Text(marker.label)
                            .font(.system(size: 11 * ls))
                            .foregroundStyle(.secondary),
                                     at: CGPoint(x: position.x, y: position.y + 16 * ls))
                    }
                }
            }
        }
    }
}
