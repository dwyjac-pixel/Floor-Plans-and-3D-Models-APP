import Foundation

/// Inputs for the rough project estimate (Module 6 of the build plan).
struct EstimateInputs: Codable {
    enum KitchenType: String, Codable, CaseIterable, Identifiable {
        case none = "None"
        case kitchenette = "Kitchenette"
        case fullKitchen = "Full Kitchen"

        var id: String { rawValue }
    }

    enum FinishLevel: String, Codable, CaseIterable, Identifiable {
        case basic = "Basic"
        case standard = "Standard"
        case premium = "Premium"

        var id: String { rawValue }
    }

    enum FlooringType: String, Codable, CaseIterable, Identifiable {
        case vinylPlank = "Vinyl Plank"
        case carpet = "Carpet"
        case laminate = "Laminate"
        case tile = "Tile"

        var id: String { rawValue }
    }

    enum CeilingType: String, Codable, CaseIterable, Identifiable {
        case drywall = "Drywall"
        case dropCeiling = "Drop Ceiling"
        case exposedPainted = "Exposed (Painted)"

        var id: String { rawValue }
    }

    enum PlumbingDistance: String, Codable, CaseIterable, Identifiable {
        case short = "Short (near stack)"
        case medium = "Medium"
        case long = "Long run"

        var id: String { rawValue }
    }

    enum ElectricalComplexity: String, Codable, CaseIterable, Identifiable {
        case simple = "Simple"
        case moderate = "Moderate"
        case complex = "Complex / panel work"

        var id: String { rawValue }
    }

    var bedrooms = 0
    var bathrooms = 0
    var kitchen: KitchenType = .none
    var finishLevel: FinishLevel = .standard
    var flooring: FlooringType = .vinylPlank
    var ceiling: CeilingType = .drywall
    var plumbingDistance: PlumbingDistance = .short
    var electrical: ElectricalComplexity = .simple
    var egressWindows = 0
    var sideDoorEntrance = false
    var laundry = false
    var demolition = false
    var overrideSquareFeet: Double?   // used when there's no floor plan yet
    var notes = ""

    init() {}

    // Custom decoding so estimate files saved by earlier versions still load.
    private enum CodingKeys: String, CodingKey {
        case bedrooms, bathrooms, kitchen, finishLevel, flooring, ceiling,
             plumbingDistance, electrical, egressWindows, sideDoorEntrance,
             laundry, demolition, overrideSquareFeet, notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bedrooms = try container.decodeIfPresent(Int.self, forKey: .bedrooms) ?? 0
        bathrooms = try container.decodeIfPresent(Int.self, forKey: .bathrooms) ?? 0
        kitchen = try container.decodeIfPresent(KitchenType.self, forKey: .kitchen) ?? .none
        finishLevel = try container.decodeIfPresent(FinishLevel.self, forKey: .finishLevel) ?? .standard
        flooring = try container.decodeIfPresent(FlooringType.self, forKey: .flooring) ?? .vinylPlank
        ceiling = try container.decodeIfPresent(CeilingType.self, forKey: .ceiling) ?? .drywall
        plumbingDistance = try container.decodeIfPresent(PlumbingDistance.self, forKey: .plumbingDistance) ?? .short
        electrical = try container.decodeIfPresent(ElectricalComplexity.self, forKey: .electrical) ?? .simple
        egressWindows = try container.decodeIfPresent(Int.self, forKey: .egressWindows) ?? 0
        sideDoorEntrance = try container.decodeIfPresent(Bool.self, forKey: .sideDoorEntrance) ?? false
        laundry = try container.decodeIfPresent(Bool.self, forKey: .laundry) ?? false
        demolition = try container.decodeIfPresent(Bool.self, forKey: .demolition) ?? false
        overrideSquareFeet = try container.decodeIfPresent(Double.self, forKey: .overrideSquareFeet)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

struct EstimateLine: Identifiable {
    let id = UUID()
    let label: String
    let low: Double
    let high: Double

    var rangeText: String {
        low == high ? Money.format(low) : "\(Money.format(low)) – \(Money.format(high))"
    }
}

struct EstimateResult {
    let squareFeet: Double
    let lines: [EstimateLine]

    var totalLow: Double { lines.reduce(0) { $0 + $1.low } }
    var totalHigh: Double { lines.reduce(0) { $0 + $1.high } }
    var rangeText: String { "\(Money.format(totalLow)) – \(Money.format(totalHigh))" }
    var materialsText: String { "\(Money.format(totalLow * 0.45)) – \(Money.format(totalHigh * 0.45))" }
    var labourText: String { "\(Money.format(totalLow * 0.55)) – \(Money.format(totalHigh * 0.55))" }
}

/// Builds the planning range from the user's PriceBook rates. Shipped
/// defaults are calibrated to Caribinal Creations for bathrooms and egress
/// windows; everything else starts as a placeholder until the owner edits
/// the Price Book.
enum EstimateCalculator {
    static func calculate(inputs: EstimateInputs, planAreaSquareMeters: Double?) -> EstimateResult? {
        // A real scanned plan area always wins over a typed override so a
        // stale value can't silently replace a measured scan (QA-016).
        let squareFeet: Double
        if let area = planAreaSquareMeters, area > 0 {
            squareFeet = area * 10.7639
        } else if let override = inputs.overrideSquareFeet, override > 0 {
            squareFeet = override
        } else {
            return nil
        }
        guard squareFeet >= 100 else { return nil }

        let book = PriceBook.load()
        var lines: [EstimateLine] = []

        let rate: PriceBook.Rate
        switch inputs.finishLevel {
        case .basic: rate = book.finishBasicPerSqFt
        case .standard: rate = book.finishStandardPerSqFt
        case .premium: rate = book.finishPremiumPerSqFt
        }
        lines.append(EstimateLine(
            label: "Finishing — \(inputs.finishLevel.rawValue.lowercased()), \(Int(squareFeet.rounded())) sq ft",
            low: squareFeet * rate.low,
            high: squareFeet * rate.high))

        if inputs.demolition {
            lines.append(EstimateLine(label: "Demolition",
                                      low: squareFeet * book.demolitionPerSqFt.low,
                                      high: squareFeet * book.demolitionPerSqFt.high))
        }
        if inputs.bedrooms > 0 {
            let count = Double(inputs.bedrooms)
            lines.append(EstimateLine(label: "Bedroom allowance ×\(inputs.bedrooms)",
                                      low: book.bedroomAllowance.low * count,
                                      high: book.bedroomAllowance.high * count))
        }
        if inputs.bathrooms > 0 {
            let count = Double(inputs.bathrooms)
            let bathRate: PriceBook.Rate
            switch inputs.finishLevel {
            case .basic: bathRate = book.bathroomBasic
            case .standard, .premium: bathRate = book.bathroomUpgraded
            }
            lines.append(EstimateLine(label: "Bathroom ×\(inputs.bathrooms)",
                                      low: bathRate.low * count, high: bathRate.high * count))
        }
        switch inputs.kitchen {
        case .none:
            break
        case .kitchenette:
            lines.append(EstimateLine(label: "Kitchenette",
                                      low: book.kitchenette.low, high: book.kitchenette.high))
        case .fullKitchen:
            lines.append(EstimateLine(label: "Full kitchen",
                                      low: book.fullKitchen.low, high: book.fullKitchen.high))
        }
        if inputs.egressWindows > 0 {
            let count = Double(inputs.egressWindows)
            lines.append(EstimateLine(label: "Egress window ×\(inputs.egressWindows)",
                                      low: book.egressWindow.low * count,
                                      high: book.egressWindow.high * count))
        }
        if inputs.sideDoorEntrance {
            lines.append(EstimateLine(label: "Side-door entrance",
                                      low: book.sideDoorEntrance.low, high: book.sideDoorEntrance.high))
        }
        if inputs.laundry {
            lines.append(EstimateLine(label: "Laundry",
                                      low: book.laundry.low, high: book.laundry.high))
        }
        if inputs.flooring == .tile {
            lines.append(EstimateLine(label: "Tile flooring upgrade",
                                      low: squareFeet * book.tileUpgradePerSqFt.low,
                                      high: squareFeet * book.tileUpgradePerSqFt.high))
        }
        if inputs.ceiling == .dropCeiling {
            lines.append(EstimateLine(label: "Drop ceiling",
                                      low: squareFeet * book.dropCeilingPerSqFt.low,
                                      high: squareFeet * book.dropCeilingPerSqFt.high))
        }
        switch inputs.plumbingDistance {
        case .short:
            break
        case .medium:
            lines.append(EstimateLine(label: "Plumbing distance allowance",
                                      low: book.plumbingMedium.low, high: book.plumbingMedium.high))
        case .long:
            lines.append(EstimateLine(label: "Plumbing distance allowance",
                                      low: book.plumbingLong.low, high: book.plumbingLong.high))
        }
        switch inputs.electrical {
        case .simple:
            break
        case .moderate:
            lines.append(EstimateLine(label: "Electrical allowance",
                                      low: book.electricalModerate.low, high: book.electricalModerate.high))
        case .complex:
            lines.append(EstimateLine(label: "Electrical allowance",
                                      low: book.electricalComplex.low, high: book.electricalComplex.high))
        }

        let subtotalLow = lines.reduce(0) { $0 + $1.low }
        let subtotalHigh = lines.reduce(0) { $0 + $1.high }
        lines.append(EstimateLine(label: "Permit & design allowance",
                                  low: subtotalLow * book.permitPercent.low / 100,
                                  high: subtotalHigh * book.permitPercent.high / 100))

        return EstimateResult(squareFeet: squareFeet, lines: lines)
    }
}

enum Money {
    static func format(_ value: Double) -> String {
        // Guard against NaN/±inf and out-of-range values reachable from
        // unvalidated money/rate fields — Int(_:) traps on those (QA-027).
        guard value.isFinite else { return "—" }
        let clamped = min(max(value.rounded(), -9_000_000_000_000), 9_000_000_000_000)
        return "$" + Int(clamped).formatted(.number.grouping(.automatic))
    }
}
