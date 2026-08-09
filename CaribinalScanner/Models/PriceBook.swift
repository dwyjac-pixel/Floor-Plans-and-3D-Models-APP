import Foundation

/// User-calibratable unit rates (CAD) behind the estimate calculator.
/// Defaults are the shipped planning rates; edit them once with real
/// numbers and every project's estimate uses them. Stored app-wide in
/// UserDefaults like PlanStyle and BusinessProfile.
struct PriceBook: Codable, Equatable {
    struct Rate: Codable, Equatable {
        var low: Double
        var high: Double
    }

    // Per square foot
    var finishBasicPerSqFt = Rate(low: 40, high: 55)
    var finishStandardPerSqFt = Rate(low: 55, high: 75)
    var finishPremiumPerSqFt = Rate(low: 80, high: 110)
    var demolitionPerSqFt = Rate(low: 3, high: 6)
    var tileUpgradePerSqFt = Rate(low: 6, high: 10)
    var dropCeilingPerSqFt = Rate(low: 2, high: 4)

    // Rooms — bathroom rates calibrated to Caribinal Creations (July 2026)
    var bedroomAllowance = Rate(low: 2500, high: 4500)
    var bathroomBasic = Rate(low: 8000, high: 12000)
    var bathroomUpgraded = Rate(low: 14000, high: 16000)
    var kitchenette = Rate(low: 8000, high: 14000)
    var fullKitchen = Rate(low: 22000, high: 38000)

    // Site & services — egress calibrated (flat $4,700 each)
    var egressWindow = Rate(low: 4700, high: 4700)
    var sideDoorEntrance = Rate(low: 10000, high: 20000)
    var laundry = Rate(low: 2500, high: 4500)
    var plumbingMedium = Rate(low: 1500, high: 3000)
    var plumbingLong = Rate(low: 3500, high: 6000)
    var electricalModerate = Rate(low: 2000, high: 4000)
    var electricalComplex = Rate(low: 5000, high: 9000)

    /// Percent of the subtotal, expressed as whole percent (4 = 4%).
    var permitPercent = Rate(low: 4, high: 7)

    init() {}

    // Every field decodes with a fallback so saved books keep loading as
    // rates are added.
    private enum CodingKeys: String, CodingKey {
        case finishBasicPerSqFt, finishStandardPerSqFt, finishPremiumPerSqFt,
             demolitionPerSqFt, tileUpgradePerSqFt, dropCeilingPerSqFt,
             bedroomAllowance, bathroomBasic, bathroomUpgraded, kitchenette,
             fullKitchen, egressWindow, sideDoorEntrance, laundry,
             plumbingMedium, plumbingLong, electricalModerate,
             electricalComplex, permitPercent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PriceBook()
        finishBasicPerSqFt = try container.decodeIfPresent(Rate.self, forKey: .finishBasicPerSqFt) ?? defaults.finishBasicPerSqFt
        finishStandardPerSqFt = try container.decodeIfPresent(Rate.self, forKey: .finishStandardPerSqFt) ?? defaults.finishStandardPerSqFt
        finishPremiumPerSqFt = try container.decodeIfPresent(Rate.self, forKey: .finishPremiumPerSqFt) ?? defaults.finishPremiumPerSqFt
        demolitionPerSqFt = try container.decodeIfPresent(Rate.self, forKey: .demolitionPerSqFt) ?? defaults.demolitionPerSqFt
        tileUpgradePerSqFt = try container.decodeIfPresent(Rate.self, forKey: .tileUpgradePerSqFt) ?? defaults.tileUpgradePerSqFt
        dropCeilingPerSqFt = try container.decodeIfPresent(Rate.self, forKey: .dropCeilingPerSqFt) ?? defaults.dropCeilingPerSqFt
        bedroomAllowance = try container.decodeIfPresent(Rate.self, forKey: .bedroomAllowance) ?? defaults.bedroomAllowance
        bathroomBasic = try container.decodeIfPresent(Rate.self, forKey: .bathroomBasic) ?? defaults.bathroomBasic
        bathroomUpgraded = try container.decodeIfPresent(Rate.self, forKey: .bathroomUpgraded) ?? defaults.bathroomUpgraded
        kitchenette = try container.decodeIfPresent(Rate.self, forKey: .kitchenette) ?? defaults.kitchenette
        fullKitchen = try container.decodeIfPresent(Rate.self, forKey: .fullKitchen) ?? defaults.fullKitchen
        egressWindow = try container.decodeIfPresent(Rate.self, forKey: .egressWindow) ?? defaults.egressWindow
        sideDoorEntrance = try container.decodeIfPresent(Rate.self, forKey: .sideDoorEntrance) ?? defaults.sideDoorEntrance
        laundry = try container.decodeIfPresent(Rate.self, forKey: .laundry) ?? defaults.laundry
        plumbingMedium = try container.decodeIfPresent(Rate.self, forKey: .plumbingMedium) ?? defaults.plumbingMedium
        plumbingLong = try container.decodeIfPresent(Rate.self, forKey: .plumbingLong) ?? defaults.plumbingLong
        electricalModerate = try container.decodeIfPresent(Rate.self, forKey: .electricalModerate) ?? defaults.electricalModerate
        electricalComplex = try container.decodeIfPresent(Rate.self, forKey: .electricalComplex) ?? defaults.electricalComplex
        permitPercent = try container.decodeIfPresent(Rate.self, forKey: .permitPercent) ?? defaults.permitPercent
    }

    private static let defaultsKey = "priceBook"

    static func load() -> PriceBook {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let book = try? JSONDecoder().decode(PriceBook.self, from: data) else {
            return PriceBook()
        }
        return book
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
