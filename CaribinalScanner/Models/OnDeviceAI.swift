import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device AI via Apple Intelligence (FoundationModels, iOS 26): no API
/// key, no network, nothing leaves the phone — the model ships with the OS.
/// Every caller checks `availability` and degrades gracefully on devices
/// without Apple Intelligence.
enum OnDeviceAI {
    enum Availability {
        case available
        /// Eligible device, but Apple Intelligence is off or still
        /// downloading the model.
        case needsAppleIntelligence
        /// Older iOS or hardware without Apple Intelligence.
        case unsupported
    }

    static var availability: Availability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.deviceNotEligible):
                return .unsupported
            case .unavailable:
                return .needsAppleIntelligence
            }
        }
        #endif
        return .unsupported
    }

    // MARK: - Location

    /// First Canadian postal code or US ZIP found in free text.
    static func extractPostal(from text: String) -> String? {
        if let match = text.firstMatch(of: /[A-Za-z]\d[A-Za-z]\s?\d[A-Za-z]\d/) {
            return String(match.output).uppercased()
        }
        if let match = text.firstMatch(of: /\b\d{5}(?:-\d{4})?\b/) {
            return String(match.output)
        }
        return nil
    }

    /// Coarse region from a postal/ZIP code — enough for the model to
    /// reason about the market without pretending to know local prices.
    static func region(fromPostal raw: String) -> String? {
        let code = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard let first = code.first else { return nil }
        if first.isLetter {
            let provinces: [Character: String] = [
                "A": "Newfoundland and Labrador", "B": "Nova Scotia",
                "C": "Prince Edward Island", "E": "New Brunswick",
                "G": "eastern Quebec", "H": "Montréal", "J": "western Quebec",
                "K": "eastern Ontario", "L": "central Ontario", "M": "Toronto",
                "N": "southwestern Ontario", "P": "northern Ontario",
                "R": "Manitoba", "S": "Saskatchewan", "T": "Alberta",
                "V": "British Columbia", "X": "Nunavut / NWT", "Y": "Yukon",
            ]
            guard let province = provinces[first] else { return nil }
            if first == "R", code.count >= 2,
               let second = code.dropFirst().first, "23".contains(second) {
                return "Winnipeg, Manitoba"
            }
            return province
        }
        let zones: [Character: String] = [
            "0": "the US Northeast", "1": "New York State / the Northeast US",
            "2": "the US Mid-Atlantic", "3": "the US Southeast",
            "4": "the eastern US Midwest", "5": "the northern US Midwest",
            "6": "the central US Midwest", "7": "the US South-Central states",
            "8": "the US Mountain West", "9": "the US West Coast",
        ]
        return zones[first]
    }

    // MARK: - Prompt building (plain data in, compact text out)

    /// Compact, token-frugal description of the quote for the small
    /// on-device model: priced lines, exclusions, price-book anchors.
    static func quotePrompt(takeoff: MaterialTakeoff,
                            adjustments: TakeoffAdjustments,
                            settings: QuoteSettings,
                            estimate: EstimateInputs?,
                            region: String?) -> String {
        var out = "Review this renovation quote"
        if let region { out += " for a job in \(region)" }
        out += ".\n\nQUOTE LINES (CAD):\n"
        var subtotal = 0.0
        for line in takeoff.lines {
            let included = adjustments.isIncluded(line)
            let price = adjustments.prices[line.key]
            var row = "- \(line.item) (\(line.quantity))"
            if let price {
                row += included ? String(format: ": $%.0f", price) : ": excluded"
                if included { subtotal += price }
            } else {
                row += included ? ": no price yet" : ": excluded"
            }
            out += row + "\n"
        }
        out += String(format: "Subtotal $%.0f, markup %.0f%%, %@ %.0f%%.\n",
                      subtotal, settings.markupPercent, settings.taxLabel, settings.taxPercent)

        let book = PriceBook.load()
        out += "\nCONTRACTOR'S OWN PRICE BOOK (anchors, CAD): "
        out += String(format: "finishing basic $%.0f-%.0f/sqft, standard $%.0f-%.0f/sqft, premium $%.0f-%.0f/sqft; ",
                      book.finishBasicPerSqFt.low, book.finishBasicPerSqFt.high,
                      book.finishStandardPerSqFt.low, book.finishStandardPerSqFt.high,
                      book.finishPremiumPerSqFt.low, book.finishPremiumPerSqFt.high)
        out += String(format: "bathroom $%.0f-%.0f; egress window $%.0f each.\n",
                      book.bathroomBasic.low, book.bathroomBasic.high, book.egressWindow.low)

        if let estimate {
            out += "\nSCOPE: \(estimate.bedrooms) bedroom(s), \(estimate.bathrooms) bathroom(s), "
            out += "finish level \(estimate.finishLevel.rawValue), \(estimate.egressWindows) egress window(s).\n"
        }
        out += "\nFlag only lines that look out of range or missing, and ask the questions that would most change this price."
        return out
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
extension OnDeviceAI {
    static func makeSession(region: String?) -> LanguageModelSession {
        LanguageModelSession(instructions: """
        You are a pricing reviewer built into a contractor's estimating app \
        (basement renovations and secondary suites\(region.map { ", working in \($0)" } ?? "")). \
        Ground every statement in the quote lines and the contractor's own price book \
        provided to you. You do NOT know live market prices — never invent one; when \
        something depends on data you don't have, say exactly what the contractor should \
        check. Be brief, concrete, and use dollar figures only from the provided numbers.
        """)
    }
}

@available(iOS 26.0, *)
@Generable
struct QuoteAIAnalysis {
    @Guide(description: "Two or three sentences: the overall read on this quote, grounded only in the provided numbers and region.")
    var summary: String
    @Guide(description: "One finding per quote line that deserves attention. Skip lines that look fine.")
    var findings: [QuoteAIFinding]
    @Guide(description: "Three to five short questions about this specific job whose answers would most change the price.")
    var questions: [String]
}

@available(iOS 26.0, *)
@Generable
struct QuoteAIFinding {
    @Guide(description: "The quote line's item name, copied exactly from the quote")
    var item: String
    @Guide(description: "Exactly one of: looks_low, fair, looks_high, check")
    var verdict: String
    @Guide(description: "One sentence tying the verdict to the numbers or the job")
    var note: String
}
#endif
