import SwiftUI

/// Suite payback calculator: the owner's rent and cost numbers against the
/// project estimate, live. Inputs persist per project (roi.json). Reached
/// from the dashboard's Investment card as "Suite ROI & Payback".
struct ROIScreen: View {
    let project: RenovationProject
    let estimateMidpoint: Double?

    @State private var inputs: ROIInputs

    init(project: RenovationProject, estimateMidpoint: Double?) {
        self.project = project
        self.estimateMidpoint = estimateMidpoint
        _inputs = State(initialValue: ScanStore.loadROI(for: project) ?? ROIInputs())
    }

    private var result: ROIResult? {
        ROICalculator.calculate(inputs: inputs, estimateMidpoint: estimateMidpoint)
    }

    var body: some View {
        Form {
            Section {
                CurrencyRow(label: "Monthly rent", value: $inputs.monthlyRent)
                HStack {
                    Text("Vacancy allowance")
                    Spacer()
                    TextField("5", value: $inputs.vacancyPercent, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        .accessibilityLabel("Vacancy allowance")
                    Text("%").foregroundStyle(.secondary)
                }
                CurrencyRow(label: "Monthly costs", value: $inputs.monthlyCosts)
            } header: {
                Text("Rental income")
            } footer: {
                Text("Monthly costs: extra utilities, insurance, and upkeep attributable to the suite.")
            }

            Section {
                CurrencyRow(label: "Build cost", value: Binding(
                    get: { inputs.overrideBuildCost ?? estimateMidpoint ?? 0 },
                    set: { inputs.overrideBuildCost = $0 }
                ))
                if inputs.overrideBuildCost != nil, estimateMidpoint != nil {
                    Button("Use Estimate Midpoint") {
                        inputs.overrideBuildCost = nil
                    }
                }
            } header: {
                Text("Investment")
            } footer: {
                if inputs.overrideBuildCost == nil, estimateMidpoint != nil {
                    Text("Using the midpoint of this project's estimate range.")
                }
            }

            if let result {
                Section("Return") {
                    LabeledContent("Net income / year") {
                        Text(Money.format(result.annualNetIncome)).bold()
                    }
                    LabeledContent("Payback") {
                        Text(result.paybackText).bold()
                    }
                    LabeledContent("Annual yield") {
                        Text(String(format: "%.1f%%", result.annualYieldPercent)).bold()
                    }
                }
            }

            Section {
            } footer: {
                Text("Planning math only — not financial advice. Verify local rents, taxes, and financing with your own numbers.")
            }
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .navigationTitle("Suite ROI")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: inputs) { _, newInputs in
            try? ScanStore.saveROI(newInputs, for: project)
        }
    }
}

private struct CurrencyRow: View {
    let label: String
    @Binding var value: Double

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text("$").foregroundStyle(.secondary)
            TextField("0", value: $value, format: .number.precision(.fractionLength(0)))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .accessibilityLabel(label)
        }
    }
}
