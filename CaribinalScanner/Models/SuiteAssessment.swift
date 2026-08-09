import Foundation

/// Rough suite-potential guidance from floor area, ceiling height, and what
/// is planned or estimated. Guidance only — requirements vary by
/// municipality; always verify against local zoning and building code.
enum SuiteAssessment {
    struct Result {
        let headline: String
        let notes: [String]
    }

    static func evaluate(areaSquareMeters: Double?,
                         ceilingMeters: Double?,
                         planning: PlanningChecklist?,
                         estimate: EstimateInputs?) -> Result {
        guard let areaSquareMeters, areaSquareMeters > 0 else {
            return Result(
                headline: "Suite assessment needs a floor plan or measurements.",
                notes: ["Scan the space or enter manual measurements to assess suite potential."])
        }
        let squareFeet = areaSquareMeters * 10.7639

        let bedroomCapacity: Int
        switch squareFeet {
        case ..<350: bedroomCapacity = 0
        case ..<550: bedroomCapacity = 1
        case ..<750: bedroomCapacity = 2
        default: bedroomCapacity = 3
        }

        var notes: [String] = []
        var ceilingOK = true
        if let ceilingMeters {
            if ceilingMeters < 1.95 {
                ceilingOK = false
                notes.append("Ceiling height \(Measure.length(ceilingMeters, imperial: true)) is below the ~6' 6\" typically required for living space.")
            }
        } else {
            notes.append("Ceiling height not recorded — needed to confirm suite viability.")
        }

        func planned(_ title: String) -> Bool {
            planning?.items.first { $0.title == title }?.planned ?? false
        }
        let hasEgress = planned("Egress window(s)") || (estimate?.egressWindows ?? 0) > 0
        let hasEntrance = planned("Side-door entrance") || (estimate?.sideDoorEntrance ?? false)
        let hasFireSeparation = planned("Fire separation")
        let hasBathroom = planned("Bathroom") || (estimate?.bathrooms ?? 0) > 0
        let hasKitchen = planned("Kitchen / kitchenette") || (estimate.map { $0.kitchen != .none } ?? false)

        var missing: [String] = []
        if !hasEgress { missing.append("egress window(s)") }
        if !hasEntrance { missing.append("separate entrance") }
        if !hasFireSeparation { missing.append("fire separation") }
        if !hasBathroom { missing.append("bathroom") }
        if !hasKitchen { missing.append("kitchen/kitchenette") }

        let sqFtText = "\(Int(squareFeet.rounded())) sq ft"
        let headline: String
        if bedroomCapacity == 0 {
            headline = "Small space (\(sqFtText)) — best suited to storage, utility, or partial development."
        } else if missing.isEmpty && ceilingOK {
            headline = "Rental-ready legal suite potential — up to \(bedroomCapacity)-bedroom (\(sqFtText))."
        } else if missing.count >= 4 {
            headline = "Family-use basement development — up to \(bedroomCapacity)-bedroom (\(sqFtText))."
        } else {
            headline = "Suite potential — up to \(bedroomCapacity)-bedroom (\(sqFtText)), items outstanding."
        }
        if !missing.isEmpty && bedroomCapacity > 0 {
            notes.append("Needed for a rental-ready legal suite: \(missing.joined(separator: ", ")).")
        }
        notes.append("Guidance only — verify against local zoning and building code.")
        return Result(headline: headline, notes: notes)
    }
}
