import Foundation

/// Investment deal analysis — the property-flip framework merged into the
/// scanner: purchase + financing + ARV + renovation cost → strategy-specific
/// returns (Flip / Rental / BRRRR). The renovation figure prefers the
/// measured scan estimate; before a scan exists, quick province cost bands
/// fill in. ARV is manual entry today; `fetchARV(address:)` is the seam
/// where the Teranet AVM API plugs in once a commercial key exists.
struct DealInputs: Codable {
    enum Strategy: String, Codable, CaseIterable, Identifiable {
        case flip = "Flip"
        case rental = "Rental"
        case brrrr = "BRRRR"

        var id: String { rawValue }
    }

    enum PropertyType: String, Codable, CaseIterable, Identifiable {
        case single = "Single Family"
        case duplex = "Duplex"
        case small = "Triplex / 4-plex"
        case apartment = "Apartment (5+)"

        var id: String { rawValue }
    }

    struct UnitRent: Codable, Identifiable {
        var id = UUID()
        var name = "Unit"
        var monthlyRent: Double = 1200
        var occupied = true
    }

    var strategy: Strategy = .rental
    var propertyType: PropertyType = .single
    var units: [UnitRent] = []
    var mlsNumber = ""
    var listPrice: Double = 0
    var annualTaxes: Double = 0
    var managementPercent: Double = 0
    var maintenancePercent: Double = 5
    var capRatePercent: Double = 5.5
    var purchasePrice: Double = 300000
    var downPaymentPercent: Double = 20
    var interestRate: Double = 5.0        // annual %
    var amortizationYears: Int = 25
    var arv: Double = 0                   // after-renovation value
    var sellingCostPercent: Double = 6    // flip: realtor + closing
    var monthsToFlip: Int = 4
    var monthlyRent: Double = 1400
    var vacancyPercent: Double = 5
    var monthlyCosts: Double = 250        // taxes, insurance, utilities
    var refinanceLTV: Double = 75         // BRRRR refinance loan-to-value
    var quickReno: [String: Double] = [:] // pre-scan category budgets
    var overrideRenoCost: Double?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case strategy, purchasePrice, downPaymentPercent, interestRate,
             amortizationYears, arv, sellingCostPercent, monthsToFlip,
             monthlyRent, vacancyPercent, monthlyCosts, refinanceLTV,
             quickReno, overrideRenoCost, propertyType, units, mlsNumber,
             listPrice, annualTaxes, managementPercent, maintenancePercent,
             capRatePercent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strategy = try c.decodeIfPresent(Strategy.self, forKey: .strategy) ?? .rental
        purchasePrice = try c.decodeIfPresent(Double.self, forKey: .purchasePrice) ?? 300000
        downPaymentPercent = try c.decodeIfPresent(Double.self, forKey: .downPaymentPercent) ?? 20
        interestRate = try c.decodeIfPresent(Double.self, forKey: .interestRate) ?? 5.0
        amortizationYears = try c.decodeIfPresent(Int.self, forKey: .amortizationYears) ?? 25
        arv = try c.decodeIfPresent(Double.self, forKey: .arv) ?? 0
        sellingCostPercent = try c.decodeIfPresent(Double.self, forKey: .sellingCostPercent) ?? 6
        monthsToFlip = try c.decodeIfPresent(Int.self, forKey: .monthsToFlip) ?? 4
        monthlyRent = try c.decodeIfPresent(Double.self, forKey: .monthlyRent) ?? 1400
        vacancyPercent = try c.decodeIfPresent(Double.self, forKey: .vacancyPercent) ?? 5
        monthlyCosts = try c.decodeIfPresent(Double.self, forKey: .monthlyCosts) ?? 250
        refinanceLTV = try c.decodeIfPresent(Double.self, forKey: .refinanceLTV) ?? 75
        quickReno = try c.decodeIfPresent([String: Double].self, forKey: .quickReno) ?? [:]
        propertyType = try c.decodeIfPresent(PropertyType.self, forKey: .propertyType) ?? .single
        units = try c.decodeIfPresent([UnitRent].self, forKey: .units) ?? []
        mlsNumber = try c.decodeIfPresent(String.self, forKey: .mlsNumber) ?? ""
        listPrice = try c.decodeIfPresent(Double.self, forKey: .listPrice) ?? 0
        annualTaxes = try c.decodeIfPresent(Double.self, forKey: .annualTaxes) ?? 0
        managementPercent = try c.decodeIfPresent(Double.self, forKey: .managementPercent) ?? 0
        maintenancePercent = try c.decodeIfPresent(Double.self, forKey: .maintenancePercent) ?? 5
        capRatePercent = try c.decodeIfPresent(Double.self, forKey: .capRatePercent) ?? 5.5
        overrideRenoCost = try c.decodeIfPresent(Double.self, forKey: .overrideRenoCost)
    }

    /// Manitoba-first quick renovation bands, used before a scan exists.
    static let renoCategories: [(name: String, low: Double, high: Double)] = [
        ("Kitchen", 15000, 35000),
        ("Bathroom", 8000, 16000),
        ("Roof", 8000, 14000),
        ("Paint", 3000, 7000),
        ("Flooring", 6000, 14000),
        ("Landscaping", 3000, 10000),
    ]
}

struct DealResult {
    let strategy: DealInputs.Strategy
    let renoCost: Double
    let renoSource: String
    let cashInvested: Double
    let monthlyMortgage: Double
    // Flip
    let flipProfit: Double
    let flipROIPercent: Double
    // Rental
    let monthlyCashFlow: Double
    let cashOnCashPercent: Double
    let capRatePercent: Double
    // BRRRR
    let grossMonthlyRent: Double
    let dscr: Double
    let incomeApproachValue: Double
    let refinanceCashOut: Double
    let cashLeftInDeal: Double
    let postRefiCashFlow: Double

    var isWinner: Bool {
        switch strategy {
        case .flip: return flipROIPercent >= 15
        case .rental: return cashOnCashPercent >= 8
        case .brrrr: return postRefiCashFlow > 0 && (cashLeftInDeal <= 0.01 || cashOnCashPercent >= 15)
        }
    }
}

enum DealAnalyzer {
    /// Placeholder for the Teranet AVM integration — returns nil until a
    /// commercial API key exists; the UI treats nil as "enter ARV manually".
    static func fetchARV(address: String) async -> Double? {
        nil
    }

    static func monthlyPayment(principal: Double, annualRatePercent: Double, years: Int) -> Double {
        // years == 0 previously produced +inf (factor - 1 == 0); extreme
        // rates can overflow pow to inf/NaN. Return a finite value (QA-027).
        guard principal > 0, years > 0 else { return 0 }
        let r = annualRatePercent / 100 / 12
        let n = Double(years * 12)
        guard r > 0 else { return principal / max(n, 1) }
        let factor = pow(1 + r, n)
        let payment = principal * r * factor / (factor - 1)
        return payment.isFinite ? payment : 0
    }

    static func calculate(inputs: DealInputs, estimateMidpoint: Double?) -> DealResult {
        let renoCost: Double
        let renoSource: String
        if let override = inputs.overrideRenoCost, override > 0 {
            renoCost = override
            renoSource = "manual entry"
        } else if let estimateMidpoint, estimateMidpoint > 0 {
            renoCost = estimateMidpoint
            renoSource = "measured scan estimate"
        } else {
            renoCost = inputs.quickReno.values.reduce(0, +)
            renoSource = "quick scope (province bands)"
        }

        let downPayment = inputs.purchasePrice * inputs.downPaymentPercent / 100
        let loan = inputs.purchasePrice - downPayment
        let mortgage = monthlyPayment(principal: loan,
                                      annualRatePercent: inputs.interestRate,
                                      years: inputs.amortizationYears)
        let cashInvested = downPayment + renoCost

        // Flip / BRRRR value: manual ARV, or the income approach for 5+ units.
        var effectiveARV = inputs.arv
        if effectiveARV <= 0, inputs.propertyType == .apartment {
            let grossPreview = inputs.units.isEmpty
                ? inputs.monthlyRent
                : inputs.units.filter(\.occupied).reduce(0) { $0 + $1.monthlyRent }
            let operatingPreview = inputs.monthlyCosts + inputs.annualTaxes / 12
                + grossPreview * (inputs.managementPercent + inputs.maintenancePercent) / 100
            let noiPreview = grossPreview * (1 - inputs.vacancyPercent / 100) - operatingPreview
            if inputs.capRatePercent > 0 { effectiveARV = noiPreview * 12 / (inputs.capRatePercent / 100) }
        }
        let sellingCosts = effectiveARV * inputs.sellingCostPercent / 100
        // Holding cost is interest-only: the loan principal is already
        // accounted for by subtracting the full purchase price below, so
        // counting the principal portion of the mortgage payment too would
        // double-count it (QA-050). Property taxes are included and the
        // carrying figure no longer silently hinges on the Rental-only
        // "monthly costs" field being visible (QA-024).
        let monthlyRate = inputs.interestRate / 100 / 12
        let monthlyHolding = loan * monthlyRate
            + inputs.annualTaxes / 12
            + inputs.monthlyCosts
        let carrying = monthlyHolding * Double(inputs.monthsToFlip)
        let flipProfit = effectiveARV - sellingCosts - inputs.purchasePrice - renoCost - carrying
        let flipROI = cashInvested > 0 ? flipProfit / cashInvested * 100 : 0

        // Rental: hold and cash-flow. Rent roll wins over the single field.
        let grossRent = inputs.units.isEmpty
            ? inputs.monthlyRent
            : inputs.units.filter(\.occupied).reduce(0) { $0 + $1.monthlyRent }
        let effectiveRent = grossRent * (1 - inputs.vacancyPercent / 100)
        let operating = inputs.monthlyCosts
            + inputs.annualTaxes / 12
            + grossRent * (inputs.managementPercent + inputs.maintenancePercent) / 100
        let noi = effectiveRent - operating
        let cashFlow = noi - mortgage
        let dscr = mortgage > 0 ? noi / mortgage : 99
        let incomeValue = inputs.capRatePercent > 0 ? noi * 12 / (inputs.capRatePercent / 100) : 0
        let coc = cashInvested > 0 ? cashFlow * 12 / cashInvested * 100 : 0
        let basis = inputs.purchasePrice + renoCost
        let capRate = basis > 0 ? noi * 12 / basis * 100 : 0

        // BRRRR: refinance at ARV, pull cash back out.
        let refiLoan = effectiveARV * inputs.refinanceLTV / 100
        let cashOut = max(refiLoan - loan, 0)
        let cashLeftIn = max(cashInvested - cashOut, 0)
        let refiMortgage = monthlyPayment(principal: refiLoan,
                                          annualRatePercent: inputs.interestRate,
                                          years: inputs.amortizationYears)
        let postRefiCashFlow = noi - refiMortgage
        // Zero cash left in the deal only means an infinite (999) CoC when the
        // suite still cash-flows; a cash-negative BRRRR is not a winner (QA-007).
        let brrrrCoC: Double
        if cashLeftIn > 0 {
            brrrrCoC = postRefiCashFlow * 12 / cashLeftIn * 100
        } else if postRefiCashFlow > 0 {
            brrrrCoC = .infinity
        } else {
            brrrrCoC = -.infinity   // all cash out but bleeding money → undefined/negative
        }

        return DealResult(strategy: inputs.strategy,
                          renoCost: renoCost,
                          renoSource: renoSource,
                          cashInvested: cashInvested,
                          monthlyMortgage: mortgage,
                          flipProfit: flipProfit,
                          flipROIPercent: flipROI,
                          monthlyCashFlow: cashFlow,
                          cashOnCashPercent: inputs.strategy == .brrrr
                              ? (brrrrCoC == .infinity ? 999
                                 : (brrrrCoC.isFinite ? brrrrCoC : -999))
                              : coc,
                          capRatePercent: capRate,
                          grossMonthlyRent: grossRent,
                          dscr: dscr,
                          incomeApproachValue: incomeValue,
                          refinanceCashOut: cashOut,
                          cashLeftInDeal: cashLeftIn,
                          postRefiCashFlow: postRefiCashFlow)
    }
}
