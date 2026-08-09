import Foundation

/// A named room in a multi-room project. Every room's geometry lives in a
/// shared plan space (metres), so merged 2D/3D views simply draw each room
/// where it sits. Capture sessions have arbitrary world origins, so new
/// rooms are auto-placed beside the existing plan when they are saved.
struct RoomEntry: Codable, Identifiable {
    var id = UUID()
    var name: String
    var room: CornerRoom
}

/// Container for rooms.json — wrapped in a struct so future project-level
/// fields can ride along without a format break.
struct RoomsFile: Codable {
    var rooms: [RoomEntry] = []
}

/// A user-saved group of fixtures ("Standard 3-pc bath") reusable across
/// every project — the mobile take on CAD blocks. Fixture positions are
/// kept as saved; placement recentres the group in the target room.
struct FixtureAssembly: Codable, Identifiable {
    var id = UUID()
    var name: String
    var fixtures: [CornerRoom.Fixture]
}

enum AssemblyStore {
    static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("fixture_assemblies.json")
    }

    static func load() -> [FixtureAssembly] {
        guard let data = try? Data(contentsOf: url),
              let assemblies = try? JSONDecoder().decode([FixtureAssembly].self, from: data) else {
            return []
        }
        return assemblies
    }

    static func save(_ assemblies: [FixtureAssembly]) {
        if let data = try? JSONEncoder().encode(assemblies) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

extension CornerRoom {
    /// Exact floor area of the outline polygon (shoelace), m².
    var floorAreaSquareMeters: Double {
        var doubled = 0.0
        for index in 0..<corners.count {
            let a = corners[index]
            let b = corners[(index + 1) % corners.count]
            doubled += a.x * b.z - b.x * a.z
        }
        return abs(doubled) / 2
    }

    /// True when two non-adjacent outline edges cross — a bow-tie / figure-8
    /// outline whose shoelace `floorAreaSquareMeters` under-reports (the two
    /// lobes' signed areas partly cancel). Callers use this to warn on a bad
    /// corner drag or capture; the area formula itself is left unchanged.
    var isSelfIntersecting: Bool {
        let pts = corners
        let n = pts.count
        guard n >= 4 else { return false }
        for i in 0..<n {
            let a1 = pts[i]
            let a2 = pts[(i + 1) % n]
            for j in (i + 1)..<n {
                // Skip edges that share a vertex (adjacent, incl. the
                // first/last wrap-around pair) — they touch but don't cross.
                if (i + 1) % n == j || (j + 1) % n == i { continue }
                let b1 = pts[j]
                let b2 = pts[(j + 1) % n]
                if CornerRoom.edgesProperlyCross(a1, a2, b1, b2) { return true }
            }
        }
        return false
    }

    /// Strict segment-crossing test (interiors intersect); shared endpoints
    /// and collinear touching do not count.
    fileprivate static func edgesProperlyCross(_ p1: Point, _ p2: Point,
                                               _ p3: Point, _ p4: Point) -> Bool {
        func cross(_ o: Point, _ a: Point, _ b: Point) -> Double {
            (a.x - o.x) * (b.z - o.z) - (a.z - o.z) * (b.x - o.x)
        }
        let d1 = cross(p3, p4, p1)
        let d2 = cross(p3, p4, p2)
        let d3 = cross(p1, p2, p3)
        let d4 = cross(p1, p2, p4)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0))
            && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }

    var planBounds: (minX: Double, maxX: Double, minZ: Double, maxZ: Double)? {
        guard let minX = corners.map(\.x).min(),
              let maxX = corners.map(\.x).max(),
              let minZ = corners.map(\.z).min(),
              let maxZ = corners.map(\.z).max() else { return nil }
        return (minX, maxX, minZ, maxZ)
    }

    /// The room translated in plan space. Openings ride along for free —
    /// they are stored relative to their wall.
    func translated(dx: Double, dz: Double) -> CornerRoom {
        var moved = self
        moved.corners = corners.map { Point(x: $0.x + dx, z: $0.z + dz) }
        moved.interiorWalls = interiorWalls.map { wall in
            var updated = wall
            updated.start = Point(x: wall.start.x + dx, z: wall.start.z + dz)
            updated.end = Point(x: wall.end.x + dx, z: wall.end.z + dz)
            return updated
        }
        moved.fixtures = fixtures.map { fixture in
            var updated = fixture
            updated.x += dx
            updated.z += dz
            return updated
        }
        return moved
    }

    /// The room scaled independently along each axis about its min corner —
    /// the Overall Size editor. Fixture and opening SIZES are kept true;
    /// opening offsets follow their wall's new length.
    func resized(xFactor: Double, zFactor: Double) -> CornerRoom {
        guard let bounds = planBounds, xFactor > 0, zFactor > 0 else { return self }
        func sx(_ x: Double) -> Double { bounds.minX + (x - bounds.minX) * xFactor }
        func sz(_ z: Double) -> Double { bounds.minZ + (z - bounds.minZ) * zFactor }

        let oldHostLengths = openings.map { hostWall(for: $0)?.length ?? 1 }
        var result = self
        result.corners = corners.map { Point(x: sx($0.x), z: sz($0.z)) }
        result.interiorWalls = interiorWalls.map { wall in
            var updated = wall
            updated.start = Point(x: sx(wall.start.x), z: sz(wall.start.z))
            updated.end = Point(x: sx(wall.end.x), z: sz(wall.end.z))
            return updated
        }
        result.fixtures = fixtures.map { fixture in
            var updated = fixture
            updated.x = sx(fixture.x)
            updated.z = sz(fixture.z)
            return updated
        }
        for index in openings.indices {
            guard let newHost = result.hostWall(for: result.openings[index]) else { continue }
            let ratio = newHost.length / max(oldHostLengths[index], 0.001)
            var offset = openings[index].offsetMeters * ratio
            offset = min(max(offset, 0), max(newHost.length - openings[index].widthMeters, 0))
            result.openings[index].offsetMeters = offset
        }
        return result
    }

    /// Places a freshly captured room in the project's plan space: the
    /// first room is normalised to the origin; later rooms sit to the right
    /// of the existing plan with a half-metre gap, avoiding accidental
    /// overlap between captures with unrelated world origins.
    func placedAlongside(_ existing: [RoomEntry]) -> CornerRoom {
        guard let own = planBounds else { return self }
        var maxX = -Double.infinity
        var minZ = Double.infinity
        for entry in existing {
            guard let bounds = entry.room.planBounds else { continue }
            maxX = max(maxX, bounds.maxX)
            minZ = min(minZ, bounds.minZ)
        }
        guard maxX.isFinite, minZ.isFinite else {
            return translated(dx: -own.minX, dz: -own.minZ)
        }
        return translated(dx: maxX + 0.5 - own.minX, dz: minZ - own.minZ)
    }

    /// The room scaled uniformly about its min corner — used by the tape
    /// accuracy check to stretch the whole capture to a site measurement.
    /// Fixture sizes stay true (a toilet is a toilet); opening offsets and
    /// widths scale with their walls.
    func scaled(by factor: Double) -> CornerRoom {
        guard let bounds = planBounds, factor > 0 else { return self }
        func sx(_ x: Double) -> Double { bounds.minX + (x - bounds.minX) * factor }
        func sz(_ z: Double) -> Double { bounds.minZ + (z - bounds.minZ) * factor }
        var scaled = self
        scaled.corners = corners.map { Point(x: sx($0.x), z: sz($0.z)) }
        scaled.interiorWalls = interiorWalls.map { wall in
            var updated = wall
            updated.start = Point(x: sx(wall.start.x), z: sz(wall.start.z))
            updated.end = Point(x: sx(wall.end.x), z: sz(wall.end.z))
            return updated
        }
        scaled.fixtures = fixtures.map { fixture in
            var updated = fixture
            updated.x = sx(fixture.x)
            updated.z = sz(fixture.z)
            return updated
        }
        scaled.openings = openings.map { opening in
            var updated = opening
            updated.offsetMeters = opening.offsetMeters * factor
            updated.widthMeters = opening.widthMeters * factor
            return updated
        }
        return scaled
    }

    /// Places recaptured geometry where the old room sat, so the rest of
    /// the plan keeps its arrangement.
    func placedOver(_ previous: CornerRoom) -> CornerRoom {
        guard let own = planBounds, let old = previous.planBounds else { return self }
        return translated(dx: old.minX - own.minX, dz: old.minZ - own.minZ)
    }

    /// Converts hand-entered measurements into an editable corner room:
    /// the rectangle (with bump-out detours) becomes the outline polygon
    /// and the manual doors/windows land on the matching outline walls.
    /// A feature that sits where a bump-out opens up moves onto the
    /// bump-out's outer wall.
    init?(manual: ManualRoom) {
        let width = manual.widthMeters
        let length = manual.lengthMeters
        guard width > 0.1, length > 0.1 else { return nil }
        // Clockwise from the top-left, matching FloorPlanModel(manual:).
        let rect = [(0.0, 0.0), (width, 0.0), (width, length), (0.0, length)]

        // A straight run of an original wall that survives in the outline,
        // remembered by the polygon index it will occupy.
        struct WallPiece {
            let rectWall: Int
            let startPointIndex: Int
            let from: Double
            let to: Double
        }

        var points: [Point] = []
        var basePieces: [WallPiece] = []
        var outerPieces: [WallPiece] = []

        func append(_ x: Double, _ z: Double) {
            if let last = points.last,
               abs(last.x - x) < 0.01, abs(last.z - z) < 0.01 { return }
            points.append(Point(x: x, z: z))
        }

        for wall in 0..<4 {
            let a = rect[wall]
            let b = rect[(wall + 1) % 4]
            let dx = b.0 - a.0
            let dz = b.1 - a.1
            let wallLength = (dx * dx + dz * dz).squareRoot()
            let ux = dx / wallLength
            let uz = dz / wallLength
            // Outward normal: the outline runs clockwise, interior right.
            let nx = uz
            let nz = -ux

            append(a.0, a.1)
            var cursor = 0.0
            // Merged intervals are sorted and non-overlapping, so overlapping
            // bump-outs can't emit a self-crossing detour (QA-011/041).
            for bump in manual.mergedBumpOuts(forWall: wall, wallLength: wallLength) {
                let from = bump.from
                let to = bump.to
                let depth = bump.depth
                if from > cursor + 0.01 {
                    basePieces.append(WallPiece(rectWall: wall,
                                                startPointIndex: points.count - 1,
                                                from: cursor, to: from))
                }
                append(a.0 + ux * from, a.1 + uz * from)
                append(a.0 + ux * from + nx * depth, a.1 + uz * from + nz * depth)
                outerPieces.append(WallPiece(rectWall: wall,
                                             startPointIndex: points.count - 1,
                                             from: from, to: to))
                append(a.0 + ux * to + nx * depth, a.1 + uz * to + nz * depth)
                append(a.0 + ux * to, a.1 + uz * to)
                cursor = to
            }
            if wallLength > cursor + 0.01 {
                basePieces.append(WallPiece(rectWall: wall,
                                            startPointIndex: points.count - 1,
                                            from: cursor, to: wallLength))
            }
        }
        // A bump-out ending exactly at the last corner would close the
        // polygon onto its own first point.
        if points.count > 1, let last = points.last,
           abs(last.x - points[0].x) < 0.01, abs(last.z - points[0].z) < 0.01 {
            points.removeLast()
        }
        guard points.count >= 3 else { return nil }

        self.init(corners: points,
                  ceilingHeightMeters: manual.ceilingHeightMeters > 0 ? manual.ceilingHeightMeters : 2.4)

        func overlap(_ aFrom: Double, _ aTo: Double, _ bFrom: Double, _ bTo: Double) -> Double {
            max(0, min(aTo, bTo) - max(aFrom, bFrom))
        }
        for feature in manual.features {
            let wall = min(max(feature.wallIndex, 0), 3)
            let kind: Opening.Kind
            switch feature.kind {
            case .door: kind = .door
            case .closetDoor: kind = .closetDoor
            case .window: kind = .window
            case .opening: kind = .opening
            }
            let width = max(feature.widthMeters, 0.05)
            let start = feature.offsetMeters
            let end = start + width
            // Assign the feature to the wall piece it overlaps most, rather
            // than the first piece its start falls in — a feature straddling
            // a bump-out boundary was otherwise clamped to a sliver on the
            // wrong piece or dropped entirely (QA-010).
            let candidates = (basePieces + outerPieces).filter { $0.rectWall == wall }
            guard let piece = candidates.max(by: {
                overlap(start, end, $0.from, $0.to) < overlap(start, end, $1.from, $1.to)
            }) else { continue }
            let pieceWidth = piece.to - piece.from
            let fittedWidth = min(width, pieceWidth)
            guard fittedWidth > 0.05 else { continue }
            // Shift the start so the full opening fits inside the chosen piece.
            let offset = min(max(start - piece.from, 0), pieceWidth - fittedWidth)
            openings.append(Opening(kind: kind, wallIndex: piece.startPointIndex,
                                    offsetMeters: offset, widthMeters: fittedWidth))
        }
    }
}
