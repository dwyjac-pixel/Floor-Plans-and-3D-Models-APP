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
