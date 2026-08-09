import Foundation

/// Markers placed on the floor plan: room labels, mechanical/electrical
/// locations, stairs, beams/posts, and free notes. Coordinates are in plan
/// space (metres), matching FloorPlanModel.
struct PlanMarkers: Codable {
    struct Marker: Codable, Identifiable {
        enum Kind: String, Codable, CaseIterable, Identifiable {
            case roomLabel = "Room Label"
            case mechanical = "Mechanical"
            case electricalPanel = "Electrical Panel"
            case stairs = "Stairs"
            case beamPost = "Beam / Post"
            case note = "Note"

            var id: String { rawValue }
        }

        var id = UUID()
        var kind: Kind
        var label: String
        var x: Double
        var y: Double
    }

    var markers: [Marker] = []
}
