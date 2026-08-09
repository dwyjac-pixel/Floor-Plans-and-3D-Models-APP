import SwiftUI

/// Estimate inputs form with a live rough range, computed from the floor
/// plan area (or a typed square footage when no plan exists yet).
struct EstimateScreen: View {
    let project: RenovationProject
    let planAreaSquareMeters: Double?
    var onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var inputs: EstimateInputs
    @State private var saveError: String?

    init(project: RenovationProject, planAreaSquareMeters: Double?, onSave: @escaping () -> Void) {
        self.project = project
        self.planAreaSquareMeters = planAreaSquareMeters
        self.onSave = onSave
        _inputs = State(initialValue: ScanStore.loadEstimate(for: project) ?? EstimateInputs())
    }

    private var result: EstimateResult? {
        EstimateCalculator.calculate(inputs: inputs, planAreaSquareMeters: planAreaSquareMeters)
    }

    var body: some View {
        Form {
            Section {
                if let planAreaSquareMeters {
                    LabeledContent("From floor plan",
                                   value: String(format: "%.0f sq ft", planAreaSquareMeters * 10.7639))
                } else {
                    HStack {
                        Text("Square feet")
                        Spacer()
                        TextField("0", value: squareFeetBinding, format: .number)
                            // Area can be fractional; .decimalPad also lets
                            // comma-decimal locales type a separator.
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .accessibilityLabel("Square feet")
                    }
                }
            } header: {
                Text("Floor Area")
            } footer: {
                planAreaSquareMeters == nil
                    ? Text("No floor plan yet — enter the square footage to estimate against.")
                    : Text("Area comes from the saved floor plan.")
            }

            Section("Scope") {
                Stepper("Bedrooms: \(inputs.bedrooms)", value: $inputs.bedrooms, in: 0...4)
                Stepper("Bathrooms: \(inputs.bathrooms)", value: $inputs.bathrooms, in: 0...3)
                Picker("Kitchen", selection: $inputs.kitchen) {
                    ForEach(EstimateInputs.KitchenType.allCases) { Text($0.rawValue).tag($0) }
                }
                Stepper("Egress windows: \(inputs.egressWindows)", value: $inputs.egressWindows, in: 0...4)
                Toggle("Side-door entrance", isOn: $inputs.sideDoorEntrance)
                Toggle("Laundry", isOn: $inputs.laundry)
                Toggle("Demolition required", isOn: $inputs.demolition)
                Picker("Finish level", selection: $inputs.finishLevel) {
                    ForEach(EstimateInputs.FinishLevel.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Flooring", selection: $inputs.flooring) {
                    ForEach(EstimateInputs.FlooringType.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Ceiling", selection: $inputs.ceiling) {
                    ForEach(EstimateInputs.CeilingType.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Plumbing distance", selection: $inputs.plumbingDistance) {
                    ForEach(EstimateInputs.PlumbingDistance.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Electrical", selection: $inputs.electrical) {
                    ForEach(EstimateInputs.ElectricalComplexity.allCases) { Text($0.rawValue).tag($0) }
                }
            }

            if let result {
                Section {
                    ForEach(result.lines) { line in
                        HStack {
                            Text(line.label)
                                .font(.subheadline)
                            Spacer()
                            Text(line.rangeText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(line.label)
                        .accessibilityValue(line.rangeText)
                    }
                    LabeledContent("Total range") {
                        Text(result.rangeText).bold()
                    }
                    LabeledContent("Materials (approx.)", value: result.materialsText)
                    LabeledContent("Labour (approx.)", value: result.labourText)
                } header: {
                    Text("Rough Range")
                } footer: {
                    Text("A fast planning range from your Price Book — not a quote. Once rooms are captured, build the itemized, taxed Quote under Materials → Quote for the real deliverable.")
                }
            }

            Section {
                NavigationLink {
                    PriceBookScreen()
                } label: {
                    Label("Price Book", systemImage: "dollarsign.square")
                }
            } footer: {
                Text("Edit the unit rates behind every line. Rates apply to all projects.")
            }

            Section("Estimate Notes") {
                TextEditor(text: $inputs.notes)
                    .frame(minHeight: 80)
            }
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .navigationTitle("Quick Estimate")
        .keyboardDoneButton()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
            }
        }
        .alert("Could Not Save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private var squareFeetBinding: Binding<Double> {
        Binding(
            get: { inputs.overrideSquareFeet ?? 0 },
            set: { inputs.overrideSquareFeet = $0 > 0 ? $0 : nil }
        )
    }

    private func save() {
        do {
            try ScanStore.saveEstimate(inputs, for: project)
            onSave()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
