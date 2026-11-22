import Foundation

/// Model to drawing fidelity for the finished preview. The expected
/// numbers below are typed in by hand from the reference bathroom's
/// dimensions, not derived from the code under test.
@main
struct PreviewGeometryTests {
    static var failures = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        if !condition() {
            failures += 1
            print("FAIL line \(line): \(message)")
        }
    }

    static func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.001) -> Bool { abs(a - b) <= tolerance }
    static func near(_ a: PreviewLayout.Point, _ x: Double, _ z: Double, _ tolerance: Double = 0.001) -> Bool {
        near(a.x, x, tolerance) && near(a.z, z, tolerance)
    }

    static func main() {
        referenceRoom()
        blockingProblems()
        assumptions()
        shapes()
        camera()
        catalog()
        if failures > 0 {
            print("\(failures) preview check(s) failed.")
            exit(1)
        }
        print("Preview layout, fit checks, camera stops, finish catalog and captions passed.")
    }

    // MARK: Reference bathroom, 2.800 x 1.600 m, drawn at (10, 20)

    static func referenceRoom() {
        let room = PreviewReferenceRoom.bathroom()
        let layout = PreviewLayout(room: room)
        expect(layout.problems.isEmpty, "reference room has problems: \(layout.problems)")
        expect(layout.assumptions.isEmpty, "reference room has assumptions: \(layout.assumptions)")
        expect(near(layout.origin, 10, 20), "origin")
        expect(near(layout.ceilingHeight, 2.134), "ceiling height")
        expect(near(layout.floorArea, 4.480), "floor area")

        // PF1: every wall face on its drawn line, facing into the room.
        let corners: [(Double, Double)] = [(0, 0), (2.8, 0), (2.8, 1.6), (0, 1.6)]
        let inward: [(Double, Double)] = [(0, 1), (-1, 0), (0, -1), (1, 0)]
        let lengths = [2.8, 1.6, 2.8, 1.6]
        let outer: [(Double, Double)] = [(-0.1, -0.1), (2.9, -0.1), (2.9, 1.7), (-0.1, 1.7)]
        expect(layout.walls.count == 4, "four walls")
        for (i, wall) in layout.walls.enumerated() where layout.walls.count == 4 {
            let next = (i + 1) % 4
            expect(near(wall.start, corners[i].0, corners[i].1), "wall \(i) start")
            expect(near(wall.end, corners[next].0, corners[next].1), "wall \(i) end")
            expect(near(wall.length, lengths[i]), "wall \(i) length")
            expect(near(wall.inward, inward[i].0, inward[i].1, 1e-9), "wall \(i) faces inward")
            // PF2: outside corners mitre at the wall thickness.
            expect(near(wall.outerStart, outer[i].0, outer[i].1), "wall \(i) outer start")
            expect(near(wall.outerEnd, outer[next].0, outer[next].1), "wall \(i) outer end")
        }
        // Clear spans between opposite faces equal the drawing.
        expect(near(layout.walls[2].start.z - layout.walls[0].start.z, 1.600), "clear depth")
        expect(near(layout.walls[1].start.x - layout.walls[3].end.x, 2.800), "clear width")

        // PF5: door on wall 3, 150 mm from the corner at (0, 1.6).
        let door = layout.walls[3].voids.first
        expect(layout.walls[3].voids.count == 1, "one door")
        if let door {
            let a = layout.walls[3].point(at: door.from), b = layout.walls[3].point(at: door.to)
            expect(near(a, 0, 1.450, 0.002) && near(b, 0, 0.688, 0.002), "door jambs at z 1.450 and 0.688")
            expect(near(door.width, 0.762, 0.002), "door clear width")
            expect(near(door.sill, 0) && near(door.head, 1.930, 0.002), "door head 1.930")
            expect(!door.hingeAtEnd && !door.swingsOutward, "door hinge and swing defaults")
        }
        // PF6: window on wall 2, 1.000 m from the corner at (2.8, 1.6).
        let window = layout.walls[2].voids.first
        expect(layout.walls[2].voids.count == 1, "one window")
        if let window {
            let a = layout.walls[2].point(at: window.from), b = layout.walls[2].point(at: window.to)
            expect(near(a, 1.800, 1.6, 0.002) && near(b, 1.200, 1.6, 0.002), "window jambs at x 1.800 and 1.200")
            expect(near(window.sill, 1.600, 0.002) && near(window.head, 2.000, 0.002), "window sill and head")
        }

        // PF8: fixtures where the plan puts them, turned the plan's way.
        func solid(_ kind: CornerRoom.Fixture.Kind) -> PreviewLayout.Solid? { layout.solids.first { $0.kind == kind } }
        if let vanity = solid(.vanity), let toilet = solid(.toilet), let shower = solid(.shower), let bulkhead = solid(.bulkhead) {
            expect(near(vanity.centre, 0.530, 0.275, 0.002) && near(vanity.yawDegrees, 0), "vanity position")
            expect(near(toilet.centre, 1.400, 0.355, 0.002) && near(toilet.yawDegrees, 0), "toilet position")
            expect(near(shower.centre, 2.400, 0.800, 0.002) && near(shower.yawDegrees, -90), "shower position")
            // Vanity and toilet back onto the z = 0 wall and face +z.
            expect(near(vanity.zAxis, 0, 1, 1e-9) && near(vanity.xAxis, 1, 0, 1e-9), "vanity faces the room")
            // The shower's width runs along z and its front faces the door (-x).
            expect(near(shower.xAxis, 0, 1, 1e-9) && near(shower.zAxis, -1, 0, 1e-9), "shower faces the door")
            let xs = shower.corners.map(\.x), zs = shower.corners.map(\.z)
            expect(near(xs.min()!, 2.000, 0.002) && near(xs.max()!, 2.800, 0.002)
                   && near(zs.min()!, 0, 0.002) && near(zs.max()!, 1.600, 0.002), "shower box x 2.0 to 2.8, z 0 to 1.6")
            // PF11: bulkhead underside at the measured clearance.
            expect(near(layout.ceilingHeight - (bulkhead.drop ?? 0), 1.934, 0.002), "bulkhead underside 1.934")
            expect(near(layout.clearHeight(above: .init(x: 0.5, z: 0.1)), 1.934, 0.002), "clear height under bulkhead")
            expect(near(layout.clearHeight(above: .init(x: 0.5, z: 1.0)), 2.134, 0.002), "clear height in open room")
        } else {
            expect(false, "missing a reference fixture")
        }

        // Wet walls: only the three walls around the shower, only beside it.
        func wet(_ index: Int) -> [ClosedRange<Double>] { layout.wetIntervals(on: layout.walls[index]) }
        expect(wet(0).count == 1 && near(wet(0)[0].lowerBound, 2.0, 0.002) && near(wet(0)[0].upperBound, 2.8, 0.002), "wall 0 wet 2.0 to 2.8")
        expect(wet(1).count == 1 && near(wet(1)[0].lowerBound, 0, 0.002) && near(wet(1)[0].upperBound, 1.6, 0.002), "wall 1 fully wet")
        expect(wet(2).count == 1 && near(wet(2)[0].lowerBound, 0, 0.002) && near(wet(2)[0].upperBound, 0.8, 0.002), "wall 2 wet 0 to 0.8")
        expect(wet(3).isEmpty, "door wall is not wet")

        // Finished wall areas: wall less openings, split paint and tile.
        func area(_ index: Int, _ surface: PreviewLayout.WallSurface) -> Double {
            layout.cells(for: layout.walls[index]).filter { $0.surface == surface }.reduce(0) { $0 + $1.area }
        }
        expect(near(area(0, .paint), 4.2680, 0.0005) && near(area(0, .wetTile), 1.7072, 0.0005), "wall 0 areas")
        expect(near(area(1, .paint), 0, 0.0005) && near(area(1, .wetTile), 3.4144, 0.0005), "wall 1 areas")
        expect(near(area(2, .paint), 4.0280, 0.0005) && near(area(2, .wetTile), 1.7072, 0.0005), "wall 2 areas less window")
        expect(near(area(3, .paint), 1.94374, 0.0005) && near(area(3, .wetTile), 0, 0.0005), "wall 3 area less door")
        // No cell covers an opening.
        for wall in layout.walls {
            for cell in layout.cells(for: wall) {
                let u = (cell.u0 + cell.u1) / 2, v = (cell.v0 + cell.v1) / 2
                expect(!wall.voids.contains { u > $0.from && u < $0.to && v > $0.sill && v < $0.head }, "cell inside an opening")
            }
        }

        // Baseboard skips the door, the vanity and the shower.
        let gaps0 = layout.baseboardGaps(on: layout.walls[0]).sorted { $0.lowerBound < $1.lowerBound }
        expect(gaps0.count == 2 && near(gaps0[0].lowerBound, 0.15, 0.002) && near(gaps0[0].upperBound, 0.91, 0.002)
               && near(gaps0[1].lowerBound, 2.0, 0.002), "baseboard gaps on the vanity wall")
        expect(layout.baseboardGaps(on: layout.walls[3]).count == 1, "baseboard gap at the door")

        // PF14: same drawing, same picture; a 10 mm move is a different one.
        expect(PreviewLayout(room: room).signature == layout.signature, "signature is stable")
        var moved = room
        moved.fixtures[0].x += 0.010
        expect(PreviewLayout(room: moved).signature != layout.signature, "signature sees a 10 mm move")

        // Floor triangles cover the floor exactly.
        let triangles = layout.floorTriangles()
        expect(triangles.count == 6, "two floor triangles")
    }

    // MARK: Nothing is silently clipped (PF4, PF7, PF10, PF11)

    static func blockingProblems() {
        let base = PreviewReferenceRoom.bathroom()
        func problems(_ edit: (inout CornerRoom) -> Void) -> [PreviewLayout.Problem] {
            var room = base
            edit(&room)
            let layout = PreviewLayout(room: room)
            if !layout.problems.isEmpty { expect(PreviewCamera.stops(for: layout).isEmpty, "a blocked room offers no camera") }
            return layout.problems
        }
        expect(problems { $0.ceilingHeightMeters = 0 }.contains(.noCeilingHeight), "zero ceiling blocks")
        expect(problems { $0.ceilingHeightMeters = 0.4 }.contains(.noCeilingHeight), "0.4 m ceiling blocks")
        let windowID = base.openings[1].id, doorID = base.openings[0].id
        expect(problems { $0.openings[1].sillMeters = 1.9 } == [.openingAboveCeiling(windowID)], "window above ceiling blocks")
        expect(problems { $0.openings[0].offsetMeters = 1.2 } == [.openingOffWall(doorID)], "door past wall end blocks")
        let extra = CornerRoom.Opening(kind: .window, wallIndex: 2, offsetMeters: 1.5, widthMeters: 0.6,
                                       sillMeters: 1.6, heightMeters: 0.4)
        expect(problems { $0.openings.append(extra) } == [.openingsOverlap(windowID, extra.id)], "overlapping openings block")
        let conflict = problems { $0.bulkheadClearanceMeters = 1.850 }
        if case .bulkheadHeightConflict(let drawn, let measured)? = conflict.first {
            expect(conflict.count == 1 && near(drawn, 1.934, 0.002) && near(measured, 1.850), "bulkhead conflict 84 mm")
        } else {
            expect(false, "bulkhead conflict not reported: \(conflict)")
        }
        let vanityID = base.fixtures[0].id, toiletID = base.fixtures[1].id
        let through = problems { $0.fixtures[0].z -= 0.050 }
        if case .fixtureThroughWall(let id, let depth)? = through.first {
            expect(through.count == 1 && id == vanityID && near(depth, 0.050, 0.002), "vanity 50 mm into the wall")
        } else {
            expect(false, "fixture through wall not reported: \(through)")
        }
        expect(problems { $0.fixtures[1].x = 10.95 } == [.fixturesOverlap(vanityID, toiletID)], "overlapping fixtures block")
        expect(problems { $0.fixtures[0].z -= 0.003 }.isEmpty, "3 mm is within fit tolerance")
        expect(problems { $0.interiorWalls = [.init(start: .init(x: 11, z: 20), end: .init(x: 11, z: 21))] }
            == [.interiorWallsNotDrawn(1)], "interior walls block for now")
        expect(problems { $0.corners = [] }.contains(.tooFewCorners), "empty outline blocks")
        for problem in [PreviewLayout.Problem.tooFewCorners, .noCeilingHeight, .openingOffWall(doorID),
                        .openingAboveCeiling(doorID), .openingsOverlap(doorID, windowID), .interiorWallsNotDrawn(2),
                        .bulkheadHeightConflict(drawn: 1.934, measured: 1.85), .fixtureThroughWall(vanityID, depth: 0.05),
                        .fixturesOverlap(vanityID, toiletID)] {
            for imperial in [false, true] {
                let text = PreviewCaption.problemText(problem, useImperial: imperial)
                expect(!text.isEmpty && !text.contains("\u{2014}") && !text.contains("\u{2013}"), "problem wording: \(text)")
            }
        }
    }

    // MARK: Defaults are named, never silent (H gates)

    static func assumptions() {
        var room = PreviewReferenceRoom.bathroom()
        room.ceilingHeightSource = .assumed
        room.openings[0].heightMeters = nil
        room.openings[1].sillMeters = nil
        room.openings[1].heightMeters = nil
        room.fixtures[3].dropMeters = nil
        room.bulkheadClearanceMeters = nil
        room.outlineNeedsVerification = true
        room.fixtures.append(.init(kind: .dresser, x: 10.9, z: 21.3, widthMeters: 0.6, depthMeters: 0.4))
        let layout = PreviewLayout(room: room)
        expect(layout.problems.isEmpty, "defaults alone do not block: \(layout.problems)")
        let doorID = room.openings[0].id, windowID = room.openings[1].id
        let expected: [PreviewLayout.Assumption] = [
            .ceilingHeight(.assumed), .approximateOutline, .windowSill(windowID), .windowHeight(windowID),
            .doorHeight(doorID), .bulkheadDrop(room.fixtures[3].id), .genericFixture(room.fixtures[4].id),
        ]
        for item in expected { expect(layout.assumptions.contains(item), "missing assumption \(item)") }
        expect(layout.assumptions.count == expected.count, "unexpected assumptions \(layout.assumptions)")
        expect(near(layout.walls[3].voids[0].head, 2.03), "default door head 2.03")
        expect(near(layout.walls[2].voids[0].sill, 0.91) && near(layout.walls[2].voids[0].head, 1.98), "default window 0.91 to 1.98")
        expect(near(layout.clearHeight(above: .init(x: 1.4, z: 0.1)), 1.734, 0.002), "default bulkhead drop 0.4")

        let text = PreviewCaption.assumptionText(layout.assumptions) ?? ""
        for word in ["ceiling height", "door height", "window height", "window sill height", "bulkhead height", "room outline"] {
            expect(text.contains(word), "caption names \(word)")
        }
        let lines = PreviewCaption.lines(revisionTitle: "Revision 2", savedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                         roomName: "Bathroom", look: "Warm Modern", layout: layout, useImperial: true)
        expect(lines.count == 4, "caption has four lines when things are assumed and blocked out")
        expect(lines[0].hasPrefix("Illustration from the drawing: Bathroom, Revision 2"), "caption says illustration first")
        for line in lines {
            expect(!line.contains("\u{2014}") && !line.contains("\u{2013}"), "no dashes in caption: \(line)")
        }
        let clean = PreviewLayout(room: PreviewReferenceRoom.bathroom())
        expect(PreviewCaption.assumptionText(clean.assumptions) == nil, "nothing assumed, nothing printed")
        // A scan estimate is not a site measurement.
        var scanned = PreviewReferenceRoom.bathroom()
        scanned.ceilingHeightSource = .captured
        expect(PreviewLayout(room: scanned).assumptions == [.ceilingHeight(.captured)], "scan estimate is flagged")
    }

    // MARK: Other outlines (PF2)

    static func shapes() {
        // Clockwise outline: faces must still point into the room.
        var clockwise = PreviewReferenceRoom.bathroom()
        clockwise.corners.reverse()
        clockwise.openings = []
        clockwise.fixtures = []
        clockwise.bulkheadClearanceMeters = nil
        let reversed = PreviewLayout(room: clockwise)
        for wall in reversed.walls {
            let mid = wall.point(at: wall.length / 2)
            expect(reversed.contains(mid + wall.inward * 0.05), "clockwise wall \(wall.wallIndex) faces inward")
            expect(!reversed.contains(wall.outerStart) && !reversed.contains(wall.outerEnd), "outer corners are outside")
        }
        // A 400 mm chamfered corner and an L shape: mitres stay one wall
        // thickness off both neighbouring faces.
        let chamfer: [CornerRoom.Point] = [.init(x: 0, z: 0), .init(x: 2.8, z: 0), .init(x: 2.8, z: 1.2),
                                           .init(x: 2.4, z: 1.6), .init(x: 0, z: 1.6)]
        let ell: [CornerRoom.Point] = [.init(x: 0, z: 0), .init(x: 4, z: 0), .init(x: 4, z: 2), .init(x: 2, z: 2),
                                       .init(x: 2, z: 3.5), .init(x: 0, z: 3.5)]
        for (name, corners, area) in [("chamfer", chamfer, 4.40), ("L", ell, 11.0)] {
            let layout = PreviewLayout(room: CornerRoom(corners: corners, ceilingHeightMeters: 2.4, ceilingHeightSource: .fieldMeasured))
            expect(layout.problems.isEmpty && near(layout.floorArea, area), "\(name) area")
            let count = layout.walls.count
            for (i, wall) in layout.walls.enumerated() {
                let previous = layout.walls[(i + count - 1) % count]
                expect(near((wall.outerStart - wall.start).dot(wall.inward), -PreviewLayout.wallThickness),
                       "\(name) corner \(i) is one thickness outside its wall")
                expect(near((wall.outerStart - previous.start).dot(previous.inward), -PreviewLayout.wallThickness),
                       "\(name) corner \(i) is one thickness outside the previous wall")
                expect(near(wall.outerStart, previous.outerEnd.x, previous.outerEnd.z, 1e-9), "\(name) corner \(i) closes")
                expect(layout.contains(wall.point(at: wall.length / 2) + wall.inward * 0.05), "\(name) wall \(i) faces inward")
            }
            // Triangles tile the floor: areas add up and each lies inside.
            let t = layout.floorTriangles()
            var sum = 0.0
            for i in stride(from: 0, to: t.count, by: 3) {
                let a = layout.floor[t[i]], b = layout.floor[t[i + 1]], c = layout.floor[t[i + 2]]
                sum += abs(PreviewLayout.signedArea([a, b, c]))
                expect(layout.contains(.init(x: (a.x + b.x + c.x) / 3, z: (a.z + b.z + c.z) / 3)), "\(name) triangle inside")
            }
            expect(t.count == (corners.count - 2) * 3 && near(sum, area, 1e-6), "\(name) triangles cover the floor")
            expect(PreviewCamera.stops(for: layout).map(\.kind) == [.inside, .overhead], "\(name) with no door has no doorway stop")
        }
    }

    // MARK: Camera stops (PF16)

    static func camera() {
        let layout = PreviewLayout(room: PreviewReferenceRoom.bathroom())
        let stops = PreviewCamera.stops(for: layout)
        expect(stops.map(\.kind) == [.doorway, .inside, .overhead], "three stops, doorway first")
        guard stops.count == 3 else { return }
        let doorway = stops[0], inside = stops[1], overhead = stops[2]

        // On the door's centre line (z = 1.069), within a step of the wall.
        expect(near(doorway.eye.z, 1.069, 0.002), "doorway camera on the door centre line")
        expect(doorway.eye.x >= -0.351 && doorway.eye.x <= 0.301, "doorway camera within a step of the wall face")
        expect(near(doorway.eye.y, 1.35), "doorway eye height 1.35")
        expect(abs(doorway.headingDegrees) <= 25.001, "doorway looks into the room")
        expect(near(doorway.pitchDegrees, 0) && near(doorway.horizontalFOV, 70) && near(doorway.verticalShift, 0.42), "doorway lens")
        // Level camera, shifted lens: the floor shows from under 2 m away
        // and the picture still reaches the bulkhead and ceiling.
        let reach = doorway.verticalReach
        expect(doorway.eye.y / reach.down < 2.0, "floor in the picture within 2 m")
        expect(reach.up > 0.25, "picture reaches above eye level")
        expect(near(overhead.verticalShift, 0), "overhead lens is centred")
        let door = PreviewCamera.entry(in: layout)
        let seen = PreviewCamera.coverage(of: layout, from: doorway.plan, headingDegrees: doorway.headingDegrees, through: door)
        expect(seen >= 0.7, "doorway view holds at least 70 percent of fixture points, got \(seen)")
        if doorway.eye.x > 0 { expect(!layout.isInsideSolid(doorway.plan, margin: 0.1), "doorway camera clear of fixtures") }

        expect(layout.contains(inside.plan) && layout.clearance(from: inside.plan) >= 0.299, "inside stop is 0.3 m off every wall")
        expect(!layout.isInsideSolid(inside.plan, margin: 0.199), "inside stop is 0.2 m off every fixture")
        expect((inside.plan - doorway.plan).length >= 0.8, "inside stop is a real second view")
        expect(inside.eye.y <= layout.clearHeight(above: inside.plan) - 0.449, "inside stop has headroom")
        expect(PreviewCamera.coverage(of: layout, from: inside.plan, headingDegrees: inside.headingDegrees, nearest: 0.6) >= 0.4,
               "inside view holds fixtures")
        expect(PreviewCamera.glideIsClear(from: doorway, to: inside, in: layout), "doorway to inside glide is clear")
        expect(!PreviewCamera.glideIsClear(from: doorway, to: overhead, in: layout), "overhead is a cut, not a glide")

        // Overhead: centred, straight down, whole room and walls in frame.
        expect(near(overhead.eye.x, 1.4) && near(overhead.eye.z, 0.8) && near(overhead.pitchDegrees, -90), "overhead centred")
        let rise = overhead.eye.y - layout.ceilingHeight
        let halfWidth = rise * tan(overhead.horizontalFOV / 2 * .pi / 180)
        expect(halfWidth >= 1.5 && halfWidth / PreviewCamera.aspect >= 0.9, "overhead holds the room and its walls")

        // Low ceilings lower the eye, never below a seated height.
        var low = PreviewReferenceRoom.bathroom()
        low.ceilingHeightMeters = 1.70
        low.fixtures.removeLast()
        low.bulkheadClearanceMeters = nil
        low.openings[0].heightMeters = 1.6
        low.openings[1].sillMeters = 1.2
        let lowStops = PreviewCamera.stops(for: PreviewLayout(room: low))
        expect(lowStops.first.map { near($0.eye.y, 1.25) } == true, "1.70 m ceiling gives a 1.25 m eye")
    }

    // MARK: Finish catalog and true scale (PF13, FS5)

    static func catalog() {
        let ids = PreviewFinish.catalog.map(\.id)
        expect(Set(ids).count == ids.count, "finish ids are unique")
        expect(PreviewFinish.looks.count >= 2, "two curated looks")
        for look in PreviewFinish.looks {
            for slot in PreviewFinish.Slot.allCases {
                let finish = look.finishes[slot].flatMap(PreviewFinish.finish)
                expect(finish?.slot == slot, "\(look.name) has a finish for \(slot.rawValue)")
            }
        }
        for slot in PreviewFinish.Slot.choices {
            expect(PreviewFinish.finishes(for: slot).count >= 2, "\(slot.rawValue) offers a choice")
            expect(!slot.title.isEmpty && slot.title != slot.rawValue, "\(slot.rawValue) has a title")
        }
        for text in PreviewFinish.catalog.map(\.name) + PreviewFinish.looks.map(\.name) {
            expect(!text.contains("\u{2014}") && !text.contains("\u{2013}"), "no dashes in \(text)")
        }
        // Looks differ in every slot a client can see change.
        let a = PreviewFinish.looks[0].finishes, b = PreviewFinish.looks[1].finishes
        for slot in PreviewFinish.Slot.choices { expect(a[slot] != b[slot], "looks differ in \(slot.rawValue)") }

        // A changed slot overrides the look; a wrong or unknown id does not.
        var selection = PreviewFinish.Selection(lookID: "warm-modern")
        selection.overrides[.floor] = "floor.charcoal-24x24"
        selection.overrides[.wall] = "floor.grey-12x24"
        selection.overrides[.hardware] = "gone"
        let resolved = selection.resolved
        expect(resolved[.floor] == "floor.charcoal-24x24", "override applies")
        expect(resolved[.wall] == "wall.warm-white" && resolved[.hardware] == "metal.brushed-brass", "bad overrides fall back")
        expect(PreviewFinish.Selection(lookID: "missing").resolved == PreviewFinish.looks[0].finishes, "unknown look falls back")
        if let data = try? JSONEncoder().encode(selection),
           let back = try? JSONDecoder().decode(PreviewFinish.Selection.self, from: data) {
            expect(back == selection, "selection round trips")
        } else {
            expect(false, "selection does not encode")
        }

        // True scale: a texture repeat is a whole number of tile pitches.
        for finish in PreviewFinish.catalog {
            guard case .tile(let tile) = finish.surface else { continue }
            expect(near(tile.repeatWidth * 1000, Double(tile.columns) * (tile.width + tile.grout), 1e-6), "\(finish.id) repeat width")
            expect(near(tile.repeatHeight * 1000, Double(tile.rows) * (tile.height + tile.grout), 1e-6), "\(finish.id) repeat height")
            expect(tile.rows % tile.rowsPerRepeat == 0, "\(finish.id) pattern closes")
            expect(tile.repeatWidth > 0.5 && tile.repeatWidth < 1.9 && tile.repeatHeight > 0.5 && tile.repeatHeight < 1.9, "\(finish.id) repeat near 1.2 m")
        }
        if case .tile(let greige)? = PreviewFinish.finish("floor.greige-12x24")?.surface {
            // 610 x 305 mm with 3 mm joints: 2 across and 4 up in 1.226 x 1.232 m.
            expect(greige.columns == 2 && greige.rows == 3 && greige.rowsPerRepeat == 3, "greige repeat is 2 by 3")
            expect(near(greige.repeatWidth, 1.226, 1e-9) && near(greige.repeatHeight, 0.924, 1e-9), "greige repeat size")
        }
        if case .tile(let subway)? = PreviewFinish.finish("wet.white-3x6")?.surface {
            expect(subway.columns == 8 && subway.rows == 16, "subway repeat is 8 by 16")
            expect(near(subway.repeatWidth, 1.216, 1e-9) && near(subway.repeatHeight, 1.232, 1e-9), "subway repeat size")
        }
    }
}
