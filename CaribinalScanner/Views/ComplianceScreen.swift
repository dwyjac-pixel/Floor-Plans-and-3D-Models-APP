import SwiftUI

/// The suite compliance report: code-aware checks computed from the plan
/// geometry plus the declared scope. Replaces a paid feasibility consult
/// with a scan — but stays clearly labelled as guidance.
struct ComplianceScreen: View {
    let compliance: SuiteCompliance

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: compliance.failCount > 0
                          ? "exclamationmark.shield.fill"
                          : compliance.warningCount > 0 ? "questionmark.diamond.fill" : "checkmark.shield.fill")
                        .font(.title)
                        .foregroundStyle(compliance.failCount > 0 ? .red
                                         : compliance.warningCount > 0 ? .orange : .green)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(compliance.headline)
                            .font(.headline)
                        Text(compliance.preset.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }

            if !compliance.measuredChecks.isEmpty {
                Section("Measured from your plan") {
                    ForEach(compliance.measuredChecks) { check in
                        CheckRow(check: check)
                    }
                }
            }

            Section {
                ForEach(compliance.declaredChecks) { check in
                    CheckRow(check: check)
                }
            } header: {
                Text("From your planning & estimate")
            } footer: {
                Text("Guidance only, based on National Building Code secondary-suite provisions. Editions and municipal requirements vary — confirm everything with your local authority before construction.")
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .navigationTitle("Suite Compliance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct CheckRow: View {
    let check: SuiteCompliance.Check

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .padding(.top, 2)
                .accessibilityLabel(statusLabel)
            VStack(alignment: .leading, spacing: 3) {
                Text(check.title)
                    .font(.subheadline.weight(.semibold))
                Text(check.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if check.reference != "—" {
                    Text(check.reference)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var statusLabel: String {
        switch check.status {
        case .pass: "Passed"
        case .warning: "Warning"
        case .fail: "Failed"
        case .unknown: "Unknown"
        }
    }

    private var symbol: String {
        switch check.status {
        case .pass: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .fail: "xmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private var color: Color {
        switch check.status {
        case .pass: .green
        case .warning: .orange
        case .fail: .red
        case .unknown: .gray
        }
    }
}
