import Foundation

/// Pulls a fixture flush and square against the nearest wall so a tub or
/// vanity dropped near a wall lands parallel to it, touching it, and never
/// inside it. Pure geometry so it can be exercised without the UI.
extension CornerRoom {

    struct WallSnap {
        var fixture: Fixture
        /// The fixture also slid along the wall into a corner or wall end.
        var tuckedIntoCorner: Bool
    }

    private struct SnapWall {
        var start: Point
        var ux: Double
        var uz: Double
        var length: Double
        /// Unit normal pointing to the side the fixture belongs on.
        var nx: Double
        var nz: Double
    }

    /// Snaps `fixture` to the nearest outline or interior wall.
    /// - maxDistance: how far (metres) the fixture's nearest edge may be from
    ///   the wall, on either side, before it stops attracting.
    /// - maxAngleDegrees: how far the fixture may be from wall-parallel before
    ///   its rotation is left alone (360 forces squaring up).
    /// Returns nil when no wall qualifies.
    func fixtureSnappedToWall(_ fixture: Fixture,
                              maxDistance: Double = 0.3,
                              maxAngleDegrees: Double = 30) -> WallSnap? {
        let walls = snapWalls(for: fixture)
        guard !walls.isEmpty else { return nil }

        struct Candidate {
            var wall: SnapWall
            var along: Double
            var perp: Double
            var rotation: Double
            var halfPerp: Double
            var halfAlong: Double
            var gap: Double
        }
        var best: Candidate?
        for wall in walls {
            let dx = fixture.x - wall.start.x
            let dz = fixture.z - wall.start.z
            let along = dx * wall.ux + dz * wall.uz
            let perp = dx * wall.nx + dz * wall.nz
            // Only walls the fixture actually sits beside.
            guard along > -maxDistance, along < wall.length + maxDistance else { continue }

            let wallAngle = atan2(wall.uz, wall.ux) * 180 / .pi
            var bestTurn: (rotation: Double, delta: Double, quarterTurns: Int)?
            // Parallel orientations first so a tie squares the long side
            // to the wall rather than sticking it out into the room.
            for quarter in [0, 2, 1, 3] {
                let candidate = Self.normalizedDegrees(wallAngle + Double(quarter) * 90)
                var delta = abs(candidate - fixture.rotationDegrees).truncatingRemainder(dividingBy: 360)
                if delta > 180 { delta = 360 - delta }
                if delta < (bestTurn?.delta ?? .infinity) {
                    bestTurn = (candidate, delta, quarter)
                }
            }
            guard let turn = bestTurn, turn.delta <= maxAngleDegrees else { continue }

            // Width runs along the wall when the fixture is parallel to it.
            let parallel = turn.quarterTurns % 2 == 0
            let halfPerp = (parallel ? fixture.depthMeters : fixture.widthMeters) / 2
            let halfAlong = (parallel ? fixture.widthMeters : fixture.depthMeters) / 2
            let gap = perp - halfPerp
            guard gap <= maxDistance else { continue }
            if abs(gap) < abs(best?.gap ?? .infinity) {
                best = Candidate(wall: wall, along: along, perp: perp, rotation: turn.rotation,
                                 halfPerp: halfPerp, halfAlong: halfAlong, gap: gap)
            }
        }
        guard let hit = best else { return nil }

        // Corners attract over a short reach regardless of how far the
        // caller let the wall itself attract.
        let tuckReach = min(maxDistance, 0.3)
        var along = hit.along
        var tucked = false
        if hit.halfAlong * 2 <= hit.wall.length + 0.01 {
            if abs(along - hit.halfAlong) <= tuckReach {
                along = hit.halfAlong
                tucked = true
            } else if abs(along + hit.halfAlong - hit.wall.length) <= tuckReach {
                along = hit.wall.length - hit.halfAlong
                tucked = true
            }
        }
        var snapped = fixture
        snapped.x = hit.wall.start.x + hit.wall.ux * along + hit.wall.nx * hit.halfPerp
        snapped.z = hit.wall.start.z + hit.wall.uz * along + hit.wall.nz * hit.halfPerp
        snapped.rotationDegrees = hit.rotation
        return WallSnap(fixture: snapped, tuckedIntoCorner: tucked)
    }

    private func snapWalls(for fixture: Fixture) -> [SnapWall] {
        var walls: [SnapWall] = []
        if corners.count >= 3 {
            for index in 0..<corners.count {
                let a = corners[index]
                let b = corners[(index + 1) % corners.count]
                guard var wall = Self.snapWall(from: a, to: b) else { continue }
                // Inward is whichever side of the wall the room lies on.
                let probe = Point(x: a.x + wall.ux * wall.length / 2 + wall.nx * 0.05,
                                  z: a.z + wall.uz * wall.length / 2 + wall.nz * 0.05)
                if !contains(probe) {
                    wall.nx = -wall.nx
                    wall.nz = -wall.nz
                }
                walls.append(wall)
            }
        }
        for interior in interiorWalls {
            guard var wall = Self.snapWall(from: interior.start, to: interior.end) else { continue }
            // A partition has a room on both sides; keep the fixture on its own.
            let side = (fixture.x - interior.start.x) * wall.nx + (fixture.z - interior.start.z) * wall.nz
            if side < 0 {
                wall.nx = -wall.nx
                wall.nz = -wall.nz
            }
            walls.append(wall)
        }
        return walls
    }

    private static func snapWall(from a: Point, to b: Point) -> SnapWall? {
        let dx = b.x - a.x
        let dz = b.z - a.z
        let length = (dx * dx + dz * dz).squareRoot()
        guard length > 0.05 else { return nil }
        let ux = dx / length
        let uz = dz / length
        return SnapWall(start: a, ux: ux, uz: uz, length: length, nx: -uz, nz: ux)
    }

    /// Ray-cast point-in-polygon test on the outline corners.
    func contains(_ point: Point) -> Bool {
        guard corners.count >= 3 else { return false }
        var inside = false
        var j = corners.count - 1
        for i in 0..<corners.count {
            let a = corners[i]
            let b = corners[j]
            if (a.z > point.z) != (b.z > point.z) {
                let crossX = (b.x - a.x) * (point.z - a.z) / (b.z - a.z) + a.x
                if point.x < crossX { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    private static func normalizedDegrees(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        if abs(value - 360) < 0.0001 { value = 0 }
        return value
    }
}
