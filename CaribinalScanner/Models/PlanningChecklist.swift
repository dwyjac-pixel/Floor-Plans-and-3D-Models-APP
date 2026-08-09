import Foundation

/// Renovation planning layer (Module 5): what the finished basement will
/// include. Planned items appear in the PDF report's Proposed Development
/// section.
struct PlanningChecklist: Codable {
    struct Item: Codable, Identifiable {
        var id = UUID()
        var title: String
        var planned = false
        var note = ""
    }

    var items: [Item] = []

    var plannedCount: Int { items.filter(\.planned).count }

    static func standard() -> PlanningChecklist {
        PlanningChecklist(items: [
            "Bedroom(s)",
            "Bathroom",
            "Kitchen / kitchenette",
            "Laundry",
            "Rec room",
            "Storage",
            "Mechanical room access",
            "Egress window(s)",
            "Side-door entrance",
            "Fire separation",
            "Smoke & CO alarms (interconnected)",
            "Sound separation",
            "Plumbing route",
            "Electrical panel / wiring",
            "Permit notes",
        ].map { Item(title: $0) })
    }
}
