import Foundation

@main
struct CeilingMeasurementTests {
    static func main() throws {
        func room(_ height: Double, _ source: CornerRoom.CeilingHeightSource) -> RoomEntry {
            RoomEntry(name: "Basement", room: CornerRoom(
                corners: [], ceilingHeightMeters: height, ceilingHeightSource: source))
        }

        func ceilingCheck(_ rooms: [RoomEntry], area: Double? = 60) -> SuiteCompliance.Check? {
            SuiteCompliance.evaluate(rooms: rooms, planAreaSquareMeters: area,
                                     planning: nil, estimate: nil).checks.first { $0.title == "Ceiling height" }
        }

        let confirmed = room(2.4, .fieldMeasured)
        let low = room(1.8, .fieldMeasured)
        let assumed = room(2.4, .assumed)
        let captured = room(2.4, .captured)
        let legacy = try JSONDecoder().decode(CornerRoom.self, from: Data(#"{"ceilingHeightMeters":2.4}"#.utf8))
        precondition(legacy.ceilingHeightMeters == 2.4 && legacy.ceilingHeightSource == nil)
        let legacyEntry = RoomEntry(name: "Legacy room", room: legacy)
        precondition(ceilingCheck([confirmed])?.status == .pass)
        precondition(ceilingCheck([low, assumed])?.status == .fail)
        for entry in [assumed, captured, legacyEntry, room(0, .fieldMeasured)] {
            precondition(ceilingCheck([entry])?.status == .warning)
            precondition(ceilingCheck([confirmed, entry])?.status == .warning)
            precondition(SuiteAssessment.verifiedCeiling(in: [confirmed, entry]) == nil)
        }
        precondition(ceilingCheck([])?.status == .warning)
        precondition(ceilingCheck([], area: nil) == nil)
        precondition(SuiteAssessment.verifiedCeiling(in: [confirmed, low]) == 1.8)
        let roundTrip = try JSONDecoder().decode(RoomEntry.self, from: JSONEncoder().encode(confirmed))
        precondition(roundTrip.room.fieldMeasuredCeilingMeters == 2.4)

        var manual = ManualRoom()
        manual.widthMeters = 4
        manual.lengthMeters = 4
        precondition(CornerRoom(manual: manual)?.ceilingHeightSource == .assumed)
        manual.ceilingHeightMeters = 2.4
        precondition(CornerRoom(manual: manual)?.fieldMeasuredCeilingMeters == nil)
        manual.ceilingMeasuredOnSite = true
        let restoredManual = try JSONDecoder().decode(ManualRoom.self, from: JSONEncoder().encode(manual))
        precondition(CornerRoom(manual: restoredManual)?.fieldMeasuredCeilingMeters == 2.4)
        try checkWalkReview()
        try checkPlanHistory()
        print("Ceiling measurements, suite checks, scan walk review, plan history, and quote cents passed.")
    }

    private static func checkPlanHistory() throws {
        let halfInchHeight = Measure.heightInFeetAndInches(87.5 * 0.0254)
        precondition(halfInchHeight.feet == 7 && halfInchHeight.inches == 3.5)
        let id = UUID()
        var room = CornerRoom(corners: [.init(x: 0, z: 0), .init(x: 4, z: 0), .init(x: 0, z: 3)],
                              ceilingHeightMeters: 2.3, ceilingHeightSource: .fieldMeasured)
        room.bulkheadClearanceMeters = 2.05
        var markers = PlanMarkers(markers: [.init(kind: .note, label: "Existing post", x: 2, y: 1)])
        let original = RoomEntry(id: id, name: "Basement", room: room, floorName: "Basement")
        var history = PlanHistory(existingConditions: .init(
            title: "Existing Conditions", rooms: [original], markers: markers))

        room.corners[1].x = 5
        markers.markers[0].label = "Proposed wall"
        history.saveRevision(named: "  Suite layout  ",
                             rooms: [.init(id: id, name: "Suite", room: room, floorName: "Basement")],
                             markers: markers)
        room.corners[1].x = 6
        history.saveRevision(named: "", rooms: [.init(id: id, name: "Suite", room: room)], markers: markers)

        let saved = try JSONDecoder().decode(PlanHistory.self, from: JSONEncoder().encode(history))
        precondition(saved.existingConditions.rooms[0].room.corners[1].x == 4)
        precondition(saved.existingConditions.rooms[0].room.fieldMeasuredCeilingMeters == 2.3)
        precondition(saved.existingConditions.markers.markers[0].label == "Existing post")
        precondition(saved.proposedRevisions.map(\.title) == ["Suite layout", "Revision 2"])
        precondition(saved.proposedRevisions[0].rooms[0].id == id)
        precondition(saved.proposedRevisions[0].rooms[0].room.corners[1].x == 5)
        precondition(saved.proposedRevisions[1].rooms[0].room.corners[1].x == 6)
        let export = ScannerRevisionExport(snapshot: saved.existingConditions, existingConditionsID: saved.existingConditions.id)
        let proposed = ScannerRevisionExport(snapshot: saved.proposedRevisions[0], existingConditionsID: saved.existingConditions.id)
        precondition(proposed.project_id == export.project_id && proposed.revision_id != export.revision_id)
        precondition(proposed.kind == "proposed")
        precondition(export.kind == "existing" && export.revision_id == saved.existingConditions.id)
        precondition(export.rooms[0].id == id && export.rooms[0].floor == "Basement")
        precondition(export.rooms[0].area_m2 == 6 && export.rooms[0].perimeter_m == 12)
        precondition(export.rooms[0].bulkhead_clearance_m == 2.05)
        precondition(export.rooms[0].ceiling_source == "fieldMeasured")
        if CommandLine.arguments.count == 2 {
            try JSONEncoder().encode(export).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        precondition(Set(([saved.existingConditions] + saved.proposedRevisions).map(\.id)).count == 3)
    }

    private static func checkWalkReview() throws {
        let firstID = UUID()
        let lastID = UUID()
        let review = ScanWalkReview(id: UUID(), floorName: "Basement", items: [
            .init(roomID: firstID), .init(roomID: nil), .init(roomID: lastID),
            .init(roomID: nil, interrupted: true)
        ])
        var first = CornerRoom(corners: [.init(x: 1, z: 1), .init(x: 3, z: 1), .init(x: 1, z: 3)],
                               ceilingHeightMeters: 2.4, ceilingHeightSource: .assumed)
        first.outlineNeedsVerification = true
        let last = first.translated(dx: 5, dz: 0)
        let rooms = review.additions(converted: [first, nil, last], alongside: [])
        precondition(rooms.map(\.id) == [firstID, lastID])
        precondition(rooms.allSatisfy { $0.floorDisplayName == "Basement" })
        precondition(rooms[1].room.corners[0].x - rooms[0].room.corners[0].x == 5)
        let storedReview = try JSONDecoder().decode(ScanWalkReview.self, from: JSONEncoder().encode(review))
        precondition(storedReview.items[1].roomID == nil)
        precondition(storedReview.items[3].interrupted == true)
        precondition(storedReview.additions(converted: [first, nil, last], alongside: rooms).isEmpty)
        let storedRoom = try JSONDecoder().decode(CornerRoom.self, from: JSONEncoder().encode(rooms[0].room))
        precondition(storedRoom.outlineNeedsVerification == true)
        let takeoff = MaterialTakeoff.calculate(room: storedRoom)
        precondition(takeoff.lines.contains {
            $0.category == "Drywall" && $0.note.contains("verify ceiling heights")
                && $0.note.contains("verify approximate outlines")
        })

        // Quote export cents. $1,193 with 10% markup is $1,312.30, and 5% GST
        // on that is exactly 6561.5 cents: half up is $65.62, where binary
        // floating point gives $65.61 and EstiMater refuses the file.
        let gst = QuoteSettings.exactPercent(5)!
        precondition(QuoteSettings.cents(119_300, percent: QuoteSettings.exactPercent(10)!) == 11_930)
        precondition(QuoteSettings.cents(131_230, percent: gst) == 6_562)
        precondition(Int((Double(131_230) / 100 * 5 / 100 * 100).rounded()) == 6_561)
        for (percent, thousandths) in [(5.0, 5_000), (13.0, 13_000), (15.0, 15_000), (12.5, 12_500),
                                       (9.975, 9_975), (14.975, 14_975)] {
            let rate = QuoteSettings.exactPercent(percent)!
            for amount in 0..<60_000 {
                precondition(QuoteSettings.cents(amount, percent: rate) == (amount * thousandths + 50_000) / 100_000)
            }
        }
        precondition(QuoteSettings.cents(100_000_000_000, percent: gst) == 5_000_000_000)
        precondition(QuoteSettings.exactPercent(.nan) == nil && QuoteSettings.exactPercent(.infinity) == nil)
        precondition(QuoteSettings.exactPercent(0.00001) == nil && QuoteSettings.exactPercent(1e16) == nil)
        struct Rate: Encodable { let tax_rate: Decimal }
        let written = String(decoding: try JSONEncoder().encode(Rate(tax_rate: QuoteSettings.exactPercent(14.975)!)), as: UTF8.self)
        precondition(written == #"{"tax_rate":14.975}"#)
    }
}
