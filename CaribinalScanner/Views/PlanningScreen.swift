import SwiftUI

/// Renovation planning checklist plus a live suite-potential assessment.
/// Planned items (with notes) appear in the PDF report.
struct PlanningScreen: View {
    let project: RenovationProject
    let areaSquareMeters: Double?
    let ceilingMeters: Double?
    let estimate: EstimateInputs?
    var onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var checklist: PlanningChecklist
    @State private var saveError: String?

    init(project: RenovationProject,
         areaSquareMeters: Double?,
         ceilingMeters: Double?,
         estimate: EstimateInputs?,
         onSave: @escaping () -> Void) {
        self.project = project
        self.areaSquareMeters = areaSquareMeters
        self.ceilingMeters = ceilingMeters
        self.estimate = estimate
        self.onSave = onSave
        _checklist = State(initialValue: ScanStore.loadPlanning(for: project) ?? .standard())
    }

    private var assessment: SuiteAssessment.Result {
        SuiteAssessment.evaluate(areaSquareMeters: areaSquareMeters,
                                 ceilingMeters: ceilingMeters,
                                 planning: checklist,
                                 estimate: estimate)
    }

    var body: some View {
        Form {
            Section("Suite Assessment") {
                Text(assessment.headline)
                    .font(.subheadline)
                    .bold()
                ForEach(assessment.notes, id: \.self) { note in
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach($checklist.items) { $item in
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(item.title, isOn: $item.planned)
                        if item.planned {
                            TextField("Notes / location", text: $item.note, axis: .vertical)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Notes for \(item.title)")
                        }
                    }
                }
            } footer: {
                Text("Planned items appear in the Proposed Development section of the PDF report. The assessment above updates as you toggle items.")
            }
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .navigationTitle("Planning Checklist")
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

    private func save() {
        do {
            try ScanStore.savePlanning(checklist, for: project)
            onSave()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
