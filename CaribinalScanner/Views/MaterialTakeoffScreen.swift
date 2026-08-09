import SwiftUI

/// Grouped material list computed from the room geometry, with per-line
/// pricing the user controls: tick a line to include it in the total,
/// and enter or adjust its price. Decisions persist per project.
struct MaterialTakeoffScreen: View {
    let takeoff: MaterialTakeoff
    let project: RenovationProject

    @State private var adjustments = TakeoffAdjustments()
    @State private var quote = QuoteSettings()
    @FocusState private var focusedPriceKey: String?

    private var totals: QuoteTotals {
        QuoteTotals(subtotal: adjustments.total(for: takeoff), settings: quote)
    }

    private var categories: [String] {
        var seen: [String] = []
        for line in takeoff.lines where !seen.contains(line.category) {
            seen.append(line.category)
        }
        return seen
    }

    private var pricedLineCount: Int {
        takeoff.lines.filter { adjustments.isIncluded($0) && adjustments.price(for: $0) != nil }.count
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Subtotal") {
                    Text(Money.format(totals.subtotal))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Markup %")
                    Spacer()
                    TextField("0", value: $quote.markupPercent, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .focused($focusedPriceKey, equals: "__markup__")
                        .accessibilityLabel("Markup percent")
                }
                LabeledContent("Markup") {
                    Text(Money.format(totals.markup))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("\(quote.taxLabel) %")
                    Spacer()
                    TextField("0", value: $quote.taxPercent, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .focused($focusedPriceKey, equals: "__tax__")
                        .accessibilityLabel("\(quote.taxLabel) percent")
                }
                LabeledContent(quote.taxLabel) {
                    Text(Money.format(totals.tax))
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Total") {
                    Text(Money.format(totals.grandTotal))
                        .font(.title3.bold())
                        .foregroundStyle(.tint)
                }
            } header: {
                Text("Pricing Summary")
            } footer: {
                Text(pricedLineCount == 0
                     ? "Enter a price on each line and untick anything the quote shouldn't include."
                     : "\(pricedLineCount) priced line\(pricedLineCount == 1 ? "" : "s") included. Markup and \(quote.taxLabel) apply to the subtotal above.")
            }

            ForEach(categories, id: \.self) { category in
                Section(category) {
                    ForEach(takeoff.lines.filter { $0.category == category }) { line in
                        lineRow(line)
                    }
                }
            }
            Section {
            } footer: {
                Text("Quantities assume 16\" o.c. framing, 4×8 sheets, and a 10% waste factor. Verify against site conditions before ordering.")
            }
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .navigationTitle("Quote")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedPriceKey = nil }
            }
        }
        .onAppear {
            adjustments = ScanStore.loadTakeoffAdjustments(for: project) ?? TakeoffAdjustments()
            quote = ScanStore.loadQuoteSettings(for: project)
        }
        .onChange(of: quote) { _, newValue in
            try? ScanStore.saveQuoteSettings(newValue, for: project)
        }
    }

    private func lineRow(_ line: MaterialTakeoff.Line) -> some View {
        let included = adjustments.isIncluded(line)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    if included {
                        adjustments.excludedKeys.insert(line.key)
                    } else {
                        adjustments.excludedKeys.remove(line.key)
                    }
                    persist()
                } label: {
                    Image(systemName: included ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(included ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Include \(line.item)")
                .accessibilityValue(included ? "Included" : "Excluded")
                .accessibilityHint(included ? "Double tap to exclude from the total" : "Double tap to include in the total")

                VStack(alignment: .leading, spacing: 2) {
                    Text(line.item)
                        .strikethrough(!included, color: .secondary)
                        .foregroundStyle(included ? .primary : .secondary)
                    if !line.note.isEmpty {
                        Text(line.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(line.quantity)
                    .bold()
                    .foregroundStyle(included ? Color.accentColor : Color.secondary)
            }
            HStack {
                Text("Price")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // Plain "$" + grouped integer to match Money.format everywhere
                // else; .currency(code:"CAD") rendered "CA$" outside Canada.
                Text("$").foregroundStyle(.secondary)
                TextField("0", value: priceBinding(line), format: .number.grouping(.automatic).precision(.fractionLength(0)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 120)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedPriceKey, equals: line.key)
                    .disabled(!included)
                    .opacity(included ? 1 : 0.5)
                    .accessibilityLabel("Price for \(line.item)")
            }
            .padding(.leading, 34)
        }
        .padding(.vertical, 2)
    }

    private func priceBinding(_ line: MaterialTakeoff.Line) -> Binding<Double?> {
        Binding(
            get: { adjustments.prices[line.key] },
            set: { newValue in
                if let newValue, newValue > 0 {
                    adjustments.prices[line.key] = newValue
                } else {
                    adjustments.prices.removeValue(forKey: line.key)
                }
                persist()
            }
        )
    }

    private func persist() {
        try? ScanStore.saveTakeoffAdjustments(adjustments, for: project)
    }
}
