import Foundation

/// Rental payback math for a finished suite — the "what does this basement
/// earn" pitch. Plain arithmetic on the owner's own numbers; clearly
/// labelled as planning math, not financial advice.
struct ROIInputs: Codable, Equatable {
    var monthlyRent: Double = 1400
    var vacancyPercent: Double = 5
    var monthlyCosts: Double = 250      // extra utilities, insurance, upkeep
    var overrideBuildCost: Double?      // nil = midpoint of the estimate

    init() {}

    private enum CodingKeys: String, CodingKey {
        case monthlyRent, vacancyPercent, monthlyCosts, overrideBuildCost
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        monthlyRent = try container.decodeIfPresent(Double.self, forKey: .monthlyRent) ?? 1400
        vacancyPercent = try container.decodeIfPresent(Double.self, forKey: .vacancyPercent) ?? 5
        monthlyCosts = try container.decodeIfPresent(Double.self, forKey: .monthlyCosts) ?? 250
        overrideBuildCost = try container.decodeIfPresent(Double.self, forKey: .overrideBuildCost)
    }
}

struct ROIResult {
    let buildCost: Double
    let annualNetIncome: Double
    let paybackYears: Double?           // nil when income doesn't cover costs
    let annualYieldPercent: Double
    let tenYearPosition: Double         // net income ×10 − build cost

    var paybackText: String {
        guard let paybackYears else { return "n/a" }
        return String(format: "%.1f years", paybackYears)
    }
}

enum ROICalculator {
    static func calculate(inputs: ROIInputs, estimateMidpoint: Double?) -> ROIResult? {
        // A build-cost override of 0 (or negative) should fall back to the
        // estimate midpoint rather than hide the ROI result entirely.
        let cost: Double
        if let override = inputs.overrideBuildCost, override > 0 {
            cost = override
        } else if let midpoint = estimateMidpoint, midpoint > 0 {
            cost = midpoint
        } else {
            return nil
        }
        let vacancy = min(max(inputs.vacancyPercent, 0), 100) / 100
        let gross = inputs.monthlyRent * 12 * (1 - vacancy)
        let net = gross - inputs.monthlyCosts * 12
        return ROIResult(buildCost: cost,
                         annualNetIncome: net,
                         paybackYears: net > 0 ? cost / net : nil,
                         annualYieldPercent: net / cost * 100,
                         tenYearPosition: net * 10 - cost)
    }
}
