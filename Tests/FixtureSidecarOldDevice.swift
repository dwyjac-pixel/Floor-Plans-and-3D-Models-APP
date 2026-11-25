import Foundation

/// Stands in for a device still on 1.0.2. It is compiled against the room
/// model exactly as 1.0.2 shipped it (taken from git by
/// test-fixture-sidecar.sh), reads the project files, edits them the way
/// that version would, and writes them back whole.
@main
struct FixtureSidecarOldDevice {
    static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let roomsURL = folder.appendingPathComponent("rooms.json")
        var file = try JSONDecoder().decode(RoomsFile.self, from: Data(contentsOf: roomsURL))
        guard let index = file.rooms.firstIndex(where: { $0.name == "Kitchen" }) else { fatalError("no kitchen") }
        let seen = file.rooms[index].room.fixtures.map(\.kind.rawValue)
        precondition(seen == ["Stove", "Refrigerator"], "1.0.2 should see only the kinds it knows, saw \(seen)")
        file.rooms[index].name = "Kitchen, edited on 1.0.2"
        file.rooms[index].room.fixtures.removeAll { $0.kind == .stove }
        try JSONEncoder().encode(file).write(to: roomsURL)

        // Saving a revision on 1.0.2 rewrites the whole history.
        let historyURL = folder.appendingPathComponent("plan_history.json")
        var history = try JSONDecoder().decode(PlanHistory.self, from: Data(contentsOf: historyURL))
        history.saveRevision(named: "Saved on 1.0.2", rooms: file.rooms, markers: PlanMarkers())
        try JSONEncoder().encode(history).write(to: historyURL)
        print("1.0.2 saw \(seen), renamed the room, deleted the stove, saved a revision and rewrote both files.")
    }
}
