import Foundation

struct ScannerRevisionExport: Encodable {
    struct Room: Encodable {
        let id: UUID
        let name: String
        let floor: String
        let ceiling_m: Double
        let bulkhead_clearance_m: Double?
        let area_m2: Double
        let perimeter_m: Double
        let doors: Int
        let ceiling_source: String
        let outline_needs_verification: Bool

        init(_ entry: RoomEntry) {
            id = entry.id
            name = entry.name
            floor = entry.floorDisplayName
            let room = entry.room
            ceiling_m = room.ceilingHeightMeters
            bulkhead_clearance_m = room.bulkheadClearanceMeters
            area_m2 = room.floorAreaSquareMeters
            perimeter_m = room.corners.indices.reduce(0) { total, index in
                let point = room.corners[index]
                let next = room.corners[(index + 1) % room.corners.count]
                return total + hypot(next.x - point.x, next.z - point.z)
            }
            doors = room.openings.filter { $0.kind == .door || $0.kind == .closetDoor }.count
            ceiling_source = room.ceilingHeightSource?.rawValue ?? "unknown"
            outline_needs_verification = room.outlineNeedsVerification == true
        }
    }

    let version = 1
    let source = "caribinal-scanner"
    let units = "metric"
    let project_id: UUID
    let revision_id: UUID
    let title: String
    let kind: String
    let rooms: [Room]

    init(snapshot: PlanHistory.Snapshot, existingConditionsID: UUID) {
        project_id = existingConditionsID
        revision_id = snapshot.id
        title = snapshot.title
        kind = snapshot.id == existingConditionsID ? "existing" : "proposed"
        rooms = snapshot.rooms.map(Room.init)
    }
}
