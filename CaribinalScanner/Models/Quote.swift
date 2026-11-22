import Foundation

/// Per-project quote settings and the derived totals for a material takeoff.
///
/// `QuoteSettings` is the small, editable configuration a contractor applies to
/// a project — a markup percentage and a tax rate with a label (e.g. "GST").
/// It is persisted per project via `ScanStore.loadQuoteSettings(for:)` /
/// `ScanStore.saveQuoteSettings(_:for:)`.
///
/// `QuoteTotals` turns a takeoff subtotal plus those settings into the four
/// numbers a quote shows: subtotal, markup, tax, and grand total. Markup is a
/// percentage of the subtotal; tax is charged on the marked-up amount.
struct QuoteSettings: Codable, Equatable {
    var markupPercent: Double = 0
    var taxPercent: Double = 5
    var taxLabel: String = "GST"
}

extension QuoteSettings {
    /// A percentage as the decimal that was typed (14.975, not the nearest
    /// binary double). Nil when the value has no plain decimal form.
    static func exactPercent(_ percent: Double) -> Decimal? {
        let text = "\(percent)"
        guard percent.isFinite, !text.contains("e") else { return nil }
        return Decimal(string: text)
    }

    /// That percentage of an amount in whole cents, rounded half up to the
    /// cent. EstiMater recomputes a quote's tax in exact arithmetic and
    /// refuses a file that is a cent off, which binary floating point is
    /// whenever the exact answer ends in half a cent.
    static func cents(_ amount: Int, percent: Decimal) -> Int? {
        var exact = Decimal(amount) * percent / 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &exact, 0, .plain)
        guard rounded >= 0, rounded <= Decimal(Int.max) else { return nil }
        return NSDecimalNumber(decimal: rounded).intValue
    }
}

struct QuoteTotals {
    let subtotal: Double
    let markup: Double
    let tax: Double
    let grandTotal: Double

    init(subtotal: Double, settings: QuoteSettings) {
        self.subtotal = subtotal
        self.markup = subtotal * settings.markupPercent / 100
        self.tax = (subtotal + markup) * settings.taxPercent / 100
        self.grandTotal = subtotal + markup + tax
    }
}
