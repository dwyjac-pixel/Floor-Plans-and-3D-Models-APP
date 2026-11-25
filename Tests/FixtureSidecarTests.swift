import Foundation

/// Fixture kinds added after 1.0.2 must survive a device that still runs
/// 1.0.2. With no arguments this runs the unit checks. "write <folder>"
/// and "check <folder>" are the two halves of the cross version test in
/// test-fixture-sidecar.sh, which lets the real 1.0.2 model read and
/// rewrite the files in between.
@main
struct FixtureSidecarTests {
    static var failures = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        if !condition() {
            failures += 1
            print("FAIL line \(line): \(message)")
        }
    }

    static let kitchenID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    static let bathID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    static let newKinds: [CornerRoom.Fixture.Kind] = [.kitchenSink, .dishwasher, .microwave, .shortUpperCabinet]
    static let future = #"{"id":"99999999-0000-0000-0000-000000000001","kind":"Wine Fridge","x":3.3,"z":0.3,"widthMeters":0.6,"depthMeters":0.6}"#

    static func kitchen() -> RoomEntry {
        var room = CornerRoom(corners: [.init(x: 10, z: 20), .init(x: 14, z: 20), .init(x: 14, z: 23), .init(x: 10, z: 23)],
                              ceilingHeightMeters: 2.3, ceilingHeightSource: .fieldMeasured)
        room.fixtures = [
            .init(kind: .stove, x: 11.2, z: 20.33, widthMeters: 0.76, depthMeters: 0.66),
            .init(kind: .fridge, x: 13.4, z: 20.38, widthMeters: 0.91, depthMeters: 0.76),
            .init(kind: .kitchenSink, x: 12.1, z: 20.305, widthMeters: 0.9, depthMeters: 0.61),
            // A value that is not a short decimal, to prove numbers pass through exactly.
            .init(kind: .dishwasher, x: 0.1 + 0.2 + 12.5, z: 20.305, widthMeters: 0.6, depthMeters: 0.61, rotationDegrees: 180),
            .init(kind: .microwave, x: 11.2, z: 20.2, widthMeters: 0.76, depthMeters: 0.4),
            .init(kind: .shortUpperCabinet, x: 11.2, z: 20.165, widthMeters: 0.76, depthMeters: 0.33),
        ]
        return RoomEntry(id: kitchenID, name: "Kitchen", room: room)
    }

    static func bathroom() -> RoomEntry {
        var room = CornerRoom(corners: [.init(x: 0, z: 0), .init(x: 2.8, z: 0), .init(x: 2.8, z: 1.6), .init(x: 0, z: 1.6)],
                              ceilingHeightMeters: 2.134, ceilingHeightSource: .fieldMeasured)
        room.fixtures = [.init(kind: .toilet, x: 1.4, z: 0.355, widthMeters: 0.5, depthMeters: 0.71)]
        return RoomEntry(id: bathID, name: "Bathroom", room: room)
    }

    static func encode(_ rooms: [RoomEntry]) -> Data { try! JSONEncoder().encode(RoomsFile(rooms: rooms)) }
    static func rooms(_ data: Data) -> [RoomEntry] { (try? JSONDecoder().decode(RoomsFile.self, from: data))?.rooms ?? [] }
    static func text(_ data: Data?) -> String { data.flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    static func holdsNewKind(_ data: Data?) -> Bool { newKinds.contains { text(data).contains("\"\($0.rawValue)\"") } }
    static func same(_ a: [CornerRoom.Fixture], _ b: [CornerRoom.Fixture]) -> Bool {
        a.count == b.count && zip(a.sorted { $0.id.uuidString < $1.id.uuidString }, b.sorted { $0.id.uuidString < $1.id.uuidString })
            .allSatisfy { $0.id == $1.id && $0.kind == $1.kind && $0.x == $1.x && $0.z == $1.z && $0.widthMeters == $1.widthMeters
                && $0.depthMeters == $1.depthMeters && $0.rotationDegrees == $1.rotationDegrees }
    }
    static func withFuture(_ sidecar: Data?) -> Data {
        var root = (try? JSONSerialization.jsonObject(with: sidecar ?? Data("{}".utf8))) as? [String: Any] ?? [:]
        var all = root["rooms"] as? [String: Any] ?? [:]
        var list = all[kitchenID.uuidString] as? [Any] ?? []
        list.append(try! JSONSerialization.jsonObject(with: Data(future.utf8)))
        all[kitchenID.uuidString] = list
        root["rooms"] = all
        root["version"] = 1
        if root["revisions"] == nil { root["revisions"] = [String: Any]() }
        return try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "write" {
            writeProject(to: URL(fileURLWithPath: arguments[2]))
        } else if arguments.count == 3, arguments[1] == "check" {
            checkProject(at: URL(fileURLWithPath: arguments[2]))
        } else {
            unit()
        }
        if failures > 0 {
            print("\(failures) fixture sidecar check(s) failed.")
            exit(1)
        }
    }

    // MARK: Unit checks

    static func unit() {
        // The list of kinds 1.0.2 reads is exactly the nineteen it shipped with.
        let all = CornerRoom.Fixture.Kind.allCases
        expect(FixtureSidecar.legacyKinds.count == 19, "nineteen legacy kinds")
        expect(FixtureSidecar.legacyKinds.allSatisfy { CornerRoom.Fixture.Kind(rawValue: $0) != nil }, "every legacy kind still exists")
        expect(Set(all.filter { !FixtureSidecar.legacyKinds.contains($0.rawValue) }) == Set(newKinds), "the newer kinds are the four kitchen kinds")
        expect(Set(CornerRoom.Fixture.Kind.placeable) == Set(all), "every kind can be placed in the plan editor")

        let original = [kitchen(), bathroom()]
        let encoded = encode(original)
        guard let first = FixtureSidecar.splitRooms(encoded, sidecar: nil, mode: .replace) else {
            expect(false, "rooms did not split")
            return
        }
        // What an older version may rewrite holds none of the newer kinds.
        expect(!holdsNewKind(first.file) && holdsNewKind(first.sidecar), "newer kinds are in the sidecar, not in rooms.json")
        expect(rooms(first.file).map { $0.room.fixtures.count } == [2, 1], "rooms.json keeps the kinds 1.0.2 reads")
        let back = rooms(FixtureSidecar.mergeRooms(first.file, sidecar: first.sidecar))
        expect(back.count == 2 && same(back[0].room.fixtures, original[0].room.fixtures) && same(back[1].room.fixtures, original[1].room.fixtures),
               "every fixture comes back exactly, numbers included")
        expect(back[0].name == "Kitchen" && back[0].id == kitchenID && back[0].room.ceilingHeightMeters == 2.3, "the rest of the room is untouched")

        // A plan with only older kinds never gets a sidecar.
        let plain = FixtureSidecar.splitRooms(encode([bathroom()]), sidecar: nil, mode: .replace)
        expect(plain?.sidecar == nil && rooms(plain?.file ?? Data()).first?.room.fixtures.count == 1, "no newer kinds, no sidecar")
        // Saving the same rooms again changes nothing.
        let again = FixtureSidecar.splitRooms(encoded, sidecar: first.sidecar, mode: .replace)
        expect(again?.sidecar == FixtureSidecar.canonical(first.sidecar), "an unchanged save leaves the sidecar bytes alone")

        // Deleting a fixture in the editor removes it for good, but only
        // when the rooms were read together with this sidecar.
        var edited = original
        edited[0].room.fixtures.removeAll { $0.kind == .dishwasher }
        let deleted = FixtureSidecar.splitRooms(encode(edited), sidecar: first.sidecar, mode: .replace)
        expect(!text(deleted?.sidecar).contains("\"Dishwasher\"") && text(deleted?.sidecar).contains("\"Kitchen Sink Cabinet\""), "a deleted fixture is gone")
        let cautious = FixtureSidecar.splitRooms(encode(edited), sidecar: first.sidecar, mode: .keepStored)
        expect(text(cautious?.sidecar).contains("\"Dishwasher\""), "when the sidecar was not the one read, nothing stored is dropped")
        let kept = rooms(FixtureSidecar.mergeRooms(cautious?.file ?? Data(), sidecar: cautious?.sidecar))
        expect(kept.first?.room.fixtures.count == 6, "and nothing is doubled")

        // A room that is gone takes its fixtures with it, on the same rule.
        let gone = FixtureSidecar.splitRooms(encode([bathroom()]), sidecar: first.sidecar, mode: .replace)
        expect(!holdsNewKind(gone?.sidecar), "a deleted room's fixtures are removed")
        let unsure = FixtureSidecar.splitRooms(encode([bathroom()]), sidecar: first.sidecar, mode: .keepStored)
        expect(holdsNewKind(unsure?.sidecar), "unless the rooms cannot be trusted to be complete")

        // A kind from a later version: this version cannot draw it, and never drops it.
        let later = withFuture(first.sidecar)
        let seen = rooms(FixtureSidecar.mergeRooms(first.file, sidecar: later))
        expect(seen.first?.room.fixtures.count == 6, "a kind this version cannot read is skipped on reading")
        for mode in [FixtureSidecar.Mode.replace, .keepStored] {
            let saved = FixtureSidecar.splitRooms(encode(seen), sidecar: later, mode: mode)
            expect(text(saved?.sidecar).contains("\"Wine Fridge\"") && text(saved?.sidecar).contains("\"Dishwasher\""), "and is carried through a save")
        }

        // A sidecar that cannot be parsed is never overwritten or trusted.
        let broken = Data("not json".utf8)
        expect(FixtureSidecar.splitRooms(encoded, sidecar: broken, mode: .replace) == nil, "an unreadable sidecar stops the split")
        expect(FixtureSidecar.mergeRooms(first.file, sidecar: broken) == first.file, "and merging with it changes nothing")
        expect(FixtureSidecar.mergeRooms(first.file, sidecar: nil) == first.file, "no sidecar, no change")

        // A file written before the sidecar existed already holds the
        // newer kinds. Reading it with a sidecar must not double them.
        let doubled = rooms(FixtureSidecar.mergeRooms(encoded, sidecar: first.sidecar))
        expect(doubled.first.map { same($0.room.fixtures, original[0].room.fixtures) } == true, "a fixture in both places appears once")

        history(original, roomsSidecar: first.sidecar)
        if failures == 0 { print("Fixture sidecar: split, merge, deletion, later kinds and plan history passed.") }
    }

    static func history(_ original: [RoomEntry], roomsSidecar: Data?) {
        var plan = PlanHistory(existingConditions: .init(title: "Existing Conditions", rooms: original, markers: PlanMarkers()))
        plan.saveRevision(named: "Option 1", rooms: original, markers: PlanMarkers())
        let encoded = try! JSONEncoder().encode(plan)
        guard let split = FixtureSidecar.splitHistory(encoded, sidecar: roomsSidecar) else {
            expect(false, "history did not split")
            return
        }
        expect(!holdsNewKind(split.file), "plan_history.json holds none of the newer kinds")
        let merged = try? JSONDecoder().decode(PlanHistory.self, from: FixtureSidecar.mergeHistory(split.file, sidecar: split.sidecar))
        let snapshots = [merged?.existingConditions].compactMap { $0 } + (merged?.proposedRevisions ?? [])
        expect(snapshots.count == 2 && snapshots.allSatisfy { same($0.rooms[0].room.fixtures, original[0].room.fixtures) },
               "every saved revision gets its fixtures back")
        expect(snapshots.map(\.id) == [plan.existingConditions.id] + plan.proposedRevisions.map(\.id), "revision ids are unchanged")
        expect(merged?.existingConditions.savedAt == plan.existingConditions.savedAt, "revision dates are unchanged")
        // The live rooms' fixtures and the revisions' fixtures share one
        // file and neither save disturbs the other.
        let live = rooms(FixtureSidecar.mergeRooms(FixtureSidecar.splitRooms(encode(original), sidecar: nil, mode: .replace)!.file, sidecar: split.sidecar))
        expect(live.first?.room.fixtures.count == 6, "a history save keeps the live rooms' fixtures")
        let afterRooms = FixtureSidecar.splitRooms(encode([bathroom()]), sidecar: split.sidecar, mode: .replace)
        let stillThere = try? JSONDecoder().decode(PlanHistory.self, from: FixtureSidecar.mergeHistory(split.file, sidecar: afterRooms?.sidecar))
        expect(stillThere?.existingConditions.rooms.first?.room.fixtures.count == 6, "deleting the live kitchen leaves saved revisions whole")
        // A revision is never rewritten with less, even from a history that lost them.
        let stripped = FixtureSidecar.splitHistory(split.file, sidecar: split.sidecar)
        expect(stripped?.sidecar == FixtureSidecar.canonical(split.sidecar), "saving history read without its fixtures drops nothing")
    }

    // MARK: Cross version test, first half: this version saves a project

    static func writeProject(to folder: URL) {
        let live = [kitchen(), bathroom()]
        var plan = PlanHistory(existingConditions: .init(title: "Existing Conditions", rooms: live, markers: PlanMarkers()))
        plan.saveRevision(named: "Option 1", rooms: live, markers: PlanMarkers())
        let roomsSplit = FixtureSidecar.splitRooms(encode(live), sidecar: nil, mode: .replace)!
        let historySplit = FixtureSidecar.splitHistory(try! JSONEncoder().encode(plan), sidecar: withFuture(roomsSplit.sidecar))!
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try! roomsSplit.file.write(to: folder.appendingPathComponent("rooms.json"))
        try! historySplit.file.write(to: folder.appendingPathComponent("plan_history.json"))
        try! historySplit.sidecar!.write(to: folder.appendingPathComponent(FixtureSidecar.fileName))
        print("This version saved a kitchen with 2 older and 4 newer fixtures, and two revisions.")
    }

    // MARK: Cross version test, second half: after 1.0.2 read and rewrote both files

    static func checkProject(at folder: URL) {
        func read(_ name: String) -> Data { (try? Data(contentsOf: folder.appendingPathComponent(name))) ?? Data() }
        let sidecar = read(FixtureSidecar.fileName)
        let live = rooms(FixtureSidecar.mergeRooms(read("rooms.json"), sidecar: sidecar))
        let room = live.first { $0.id == kitchenID }
        expect(room?.name == "Kitchen, edited on 1.0.2", "the older device's rename is kept")
        expect(room?.room.fixtures.contains { $0.kind == .stove } == false && room?.room.fixtures.contains { $0.kind == .fridge } == true,
               "the older device's own edit (stove deleted) is kept")
        expect(Set(room?.room.fixtures.map(\.kind) ?? []).isSuperset(of: Set(newKinds)), "all four newer fixtures are still there")
        expect(room?.room.fixtures.first { $0.kind == .dishwasher }?.x == 0.1 + 0.2 + 12.5, "at exactly the saved position")

        let plan = try? JSONDecoder().decode(PlanHistory.self, from: FixtureSidecar.mergeHistory(read("plan_history.json"), sidecar: sidecar))
        let revisions = plan?.proposedRevisions ?? []
        expect(revisions.count == 2, "the revision saved on 1.0.2 is there beside the earlier one")
        expect(plan?.existingConditions.rooms.first?.room.fixtures.count == 6 && revisions.first?.rooms.first?.room.fixtures.count == 6,
               "revisions saved by this version are whole after 1.0.2 rewrote the history")
        // 1.0.2 cannot see the newer fixtures, so a revision it saves does not hold them.
        expect(revisions.last?.title == "Saved on 1.0.2" && revisions.last?.rooms.first?.room.fixtures.count == 1,
               "a revision saved on 1.0.2 holds only what 1.0.2 could see")

        // Back on this version: delete the dishwasher and save.
        var edited = live
        if let index = edited.firstIndex(where: { $0.id == kitchenID }) {
            edited[index].room.fixtures.removeAll { $0.kind == .dishwasher }
        }
        let saved = FixtureSidecar.splitRooms(encode(edited), sidecar: sidecar, mode: .replace)
        let reread = rooms(FixtureSidecar.mergeRooms(saved?.file ?? Data(), sidecar: saved?.sidecar)).first { $0.id == kitchenID }
        expect(reread?.room.fixtures.contains { $0.kind == .dishwasher } == false && reread?.room.fixtures.count == 4,
               "the delete sticks in the live room")
        expect(text(saved?.sidecar).contains("\"Wine Fridge\""), "a later version's fixture is still carried")
        let after = try? JSONDecoder().decode(PlanHistory.self, from: FixtureSidecar.mergeHistory(read("plan_history.json"), sidecar: saved?.sidecar))
        expect(after?.existingConditions.rooms.first?.room.fixtures.contains { $0.kind == .dishwasher } == true, "and saved revisions keep theirs")
        if failures == 0 { print("Cross version: nothing saved by this version was lost after 1.0.2 read and rewrote the project.") }
    }
}
