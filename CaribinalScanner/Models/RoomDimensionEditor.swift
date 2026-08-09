import Foundation

/// Applies a corrected wall length to a captured room outline. The walls
/// running in the opposite direction absorb the change proportionally so
/// the outline stays closed — correcting one wall of a rectangle adjusts
/// its opposite wall, and L-shapes distribute across their parallel walls.
enum RoomDimensionEditor {
    static func settingWallLength(_ newLength: Double, at index: Int, in room: CornerRoom) -> CornerRoom? {
        let points = room.corners
        let count = points.count
        guard count >= 3, index >= 0, index < count, newLength > 0.05 else { return nil }

        var directions: [(x: Double, z: Double)] = []
        var lengths: [Double] = []
        for i in 0..<count {
            let a = points[i]
            let b = points[(i + 1) % count]
            let dx = b.x - a.x
            let dz = b.z - a.z
            let length = (dx * dx + dz * dz).squareRoot()
            guard length > 0.01 else { return nil }
            directions.append((dx / length, dz / length))
            lengths.append(length)
        }

        let edited = directions[index]
        let delta = newLength - lengths[index]
        guard abs(delta) > 0.0005 else { return room }

        // Walls running the opposite way absorb the change. Only near-exact
        // antiparallel walls preserve closure when their length changes;
        // accepting merely "opposing" walls (dot < -0.7) dumps the closure
        // residual into the implicit last edge and corrupts angled outlines.
        let opposite = (0..<count).filter { i in
            i != index && (directions[i].x * edited.x + directions[i].z * edited.z) < -0.999
        }
        guard !opposite.isEmpty else { return nil }
        let oppositeTotal = opposite.reduce(0.0) { $0 + lengths[$1] }
        guard oppositeTotal > 0.05 else { return nil }

        lengths[index] = newLength
        for i in opposite {
            lengths[i] += delta * (lengths[i] / oppositeTotal)
            guard lengths[i] > 0.05 else { return nil }
        }

        // Rebuild the outline from the first corner with fixed directions.
        // The loop reconstructs the first count-1 edges; the last edge
        // (from rebuilt[count-1] back to points[0]) is implicit.
        var rebuilt = [points[0]]
        for i in 0..<(count - 1) {
            let last = rebuilt[i]
            rebuilt.append(CornerRoom.Point(x: last.x + directions[i].x * lengths[i],
                                            z: last.z + directions[i].z * lengths[i]))
        }

        // The implicit closing edge must still match the last wall's fixed
        // direction and (possibly edited) length. If the antiparallel
        // redistribution didn't close the polygon within tolerance — the
        // outline isn't rectilinear enough to adjust automatically, or the
        // edited wall is the last one and nothing absorbed its change —
        // bail out so the caller surfaces the manual-adjust message.
        let closeActual = (x: points[0].x - rebuilt[count - 1].x,
                           z: points[0].z - rebuilt[count - 1].z)
        let closeExpected = (x: directions[count - 1].x * lengths[count - 1],
                             z: directions[count - 1].z * lengths[count - 1])
        let closeError = (((closeActual.x - closeExpected.x) * (closeActual.x - closeExpected.x))
                          + ((closeActual.z - closeExpected.z) * (closeActual.z - closeExpected.z))).squareRoot()
        guard closeError < 0.01 else { return nil }

        var updated = room
        updated.corners = rebuilt

        // Interior walls and fixtures store absolute plan positions, so they
        // must follow the outline they were placed against — converted LiDAR
        // scans snap partition ends exactly onto outline corners.
        let snapTolerance = 0.05

        // Displacement of the nearest point on the old outline, interpolated
        // between that wall's corner displacements. Corner displacements
        // differ only along the wall direction, so perpendicular offsets
        // (a fixture's inset from its wall) are preserved.
        func displacement(near p: CornerRoom.Point) -> (dx: Double, dz: Double) {
            var best = (distance: Double.infinity, dx: 0.0, dz: 0.0)
            for i in 0..<count {
                let a = points[i]
                let b = points[(i + 1) % count]
                let abx = b.x - a.x
                let abz = b.z - a.z
                let lengthSquared = abx * abx + abz * abz
                var t = lengthSquared > 0 ? ((p.x - a.x) * abx + (p.z - a.z) * abz) / lengthSquared : 0
                t = min(max(t, 0), 1)
                let nx = a.x + abx * t
                let nz = a.z + abz * t
                let distance = ((p.x - nx) * (p.x - nx) + (p.z - nz) * (p.z - nz)).squareRoot()
                if distance < best.distance {
                    let next = (i + 1) % count
                    let da = (x: rebuilt[i].x - a.x, z: rebuilt[i].z - a.z)
                    let db = (x: rebuilt[next].x - points[next].x, z: rebuilt[next].z - points[next].z)
                    best = (distance, da.x + (db.x - da.x) * t, da.z + (db.z - da.z) * t)
                }
            }
            return (best.dx, best.dz)
        }

        // An endpoint sitting on an old corner stays pinned to that corner.
        func moved(_ p: CornerRoom.Point) -> CornerRoom.Point {
            var nearest: (index: Int, distance: Double)?
            for i in 0..<count {
                let dx = p.x - points[i].x
                let dz = p.z - points[i].z
                let distance = (dx * dx + dz * dz).squareRoot()
                if distance < snapTolerance, distance < (nearest?.distance ?? .infinity) {
                    nearest = (i, distance)
                }
            }
            if let nearest {
                return CornerRoom.Point(x: rebuilt[nearest.index].x + (p.x - points[nearest.index].x),
                                        z: rebuilt[nearest.index].z + (p.z - points[nearest.index].z))
            }
            let d = displacement(near: p)
            return CornerRoom.Point(x: p.x + d.dx, z: p.z + d.dz)
        }

        updated.interiorWalls = room.interiorWalls.map { wall in
            var adjusted = wall
            adjusted.start = moved(wall.start)
            adjusted.end = moved(wall.end)
            return adjusted
        }
        updated.fixtures = room.fixtures.map { fixture in
            var adjusted = fixture
            let d = displacement(near: CornerRoom.Point(x: fixture.x, z: fixture.z))
            adjusted.x += d.dx
            adjusted.z += d.dz
            return adjusted
        }
        // Openings ride along with their wall; keep them on it if it shrank.
        for i in updated.openings.indices {
            guard let host = updated.hostWall(for: updated.openings[i]) else { continue }
            let maxOffset = max(host.length - updated.openings[i].widthMeters, 0)
            updated.openings[i].offsetMeters = min(max(updated.openings[i].offsetMeters, 0), maxOffset)
        }
        return updated
    }
}
