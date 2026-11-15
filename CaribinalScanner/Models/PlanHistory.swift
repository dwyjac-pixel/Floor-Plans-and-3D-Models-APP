import Foundation

struct PlanHistory: Codable {
    struct Snapshot: Codable, Identifiable {
        let id: UUID
        let title: String
        let savedAt: Date
        let rooms: [RoomEntry]
        let markers: PlanMarkers

        init(title: String, rooms: [RoomEntry], markers: PlanMarkers) {
            self.id = UUID()
            self.title = title
            self.savedAt = .now
            self.rooms = rooms
            self.markers = markers
        }
    }

    let existingConditions: Snapshot
    private(set) var proposedRevisions: [Snapshot] = []

    mutating func saveRevision(named name: String, rooms: [RoomEntry], markers: PlanMarkers) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        proposedRevisions.append(Snapshot(
            title: name.isEmpty ? "Revision \(proposedRevisions.count + 1)" : name,
            rooms: rooms, markers: markers))
    }
}
