import SwiftUI

/// Editable unit rates behind every estimate. Low and high define the
/// range each line prints with; changes save immediately and apply to all
/// projects.
struct PriceBookScreen: View {
    @State private var book = PriceBook.load()

    var body: some View {
        Form {
            Section("Per square foot") {
                RateRow("Finishing: basic", $book.finishBasicPerSqFt)
                RateRow("Finishing: standard", $book.finishStandardPerSqFt)
                RateRow("Finishing: premium", $book.finishPremiumPerSqFt)
                RateRow("Demolition", $book.demolitionPerSqFt)
                RateRow("Tile flooring upgrade", $book.tileUpgradePerSqFt)
                RateRow("Drop ceiling", $book.dropCeilingPerSqFt)
            }

            Section("Rooms") {
                RateRow("Bedroom allowance (each)", $book.bedroomAllowance)
                RateRow("Bathroom: basic finish", $book.bathroomBasic)
                RateRow("Bathroom: standard / premium", $book.bathroomUpgraded)
                RateRow("Kitchenette", $book.kitchenette)
                RateRow("Full kitchen", $book.fullKitchen)
            }

            Section("Site & services") {
                RateRow("Egress window (each)", $book.egressWindow)
                RateRow("Side-door entrance", $book.sideDoorEntrance)
                RateRow("Laundry", $book.laundry)
                RateRow("Plumbing: medium run", $book.plumbingMedium)
                RateRow("Plumbing: long run", $book.plumbingLong)
                RateRow("Electrical: moderate", $book.electricalModerate)
                RateRow("Electrical: complex / panel", $book.electricalComplex)
            }

            Section {
                RateRow("Permit & design", $book.permitPercent, unit: .percent)
            } footer: {
                Text("Low and high set each estimate line's range. Rates are in CAD and apply to every project.")
            }

            Section {
                Button("Reset to Default Rates", role: .destructive) {
                    book = PriceBook()
                }
            }
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .navigationTitle("Price Book")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: book) { _, newBook in
            newBook.save()
        }
    }
}

private struct RateRow: View {
    enum Unit {
        case dollars, percent
    }

    let label: String
    @Binding var rate: PriceBook.Rate
    var unit: Unit = .dollars

    init(_ label: String, _ rate: Binding<PriceBook.Rate>, unit: Unit = .dollars) {
        self.label = label
        _rate = rate
        self.unit = unit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.subheadline)
            HStack(spacing: 6) {
                field(value: lowBinding, placeholder: "Low")
                Text("to")
                    .foregroundStyle(.secondary)
                field(value: highBinding, placeholder: "High")
            }
            .font(.callout)
        }
        .padding(.vertical, 2)
    }

    // Reject negative rates and keep low ≤ high, so an estimate line can
    // never carry an inverted or negative range.
    private var lowBinding: Binding<Double> {
        Binding(
            get: { rate.low },
            set: { newValue in
                let clamped = max(newValue, 0)
                rate.low = clamped
                if rate.high < clamped { rate.high = clamped }
            }
        )
    }

    private var highBinding: Binding<Double> {
        Binding(
            get: { rate.high },
            set: { newValue in
                let clamped = max(newValue, 0)
                rate.high = clamped
                if rate.low > clamped { rate.low = clamped }
            }
        )
    }

    @ViewBuilder
    private func field(value: Binding<Double>, placeholder: String) -> some View {
        HStack(spacing: 2) {
            if unit == .dollars {
                Text("$").foregroundStyle(.secondary)
            }
            TextField(placeholder, value: value, format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 110)
                .accessibilityLabel("\(label), \(placeholder)")
            if unit == .percent {
                Text("%").foregroundStyle(.secondary)
            }
        }
    }
}
