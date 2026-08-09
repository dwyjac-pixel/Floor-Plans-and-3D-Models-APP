import SwiftUI

/// One place to reach every export/share action. It owns no export logic:
/// each row calls a closure supplied by ProjectDetailView that invokes that
/// view's existing export functions (which still present their own preview
/// sheets on the dashboard once this hub has dismissed).
struct ExportHubScreen: View {
    /// Whether an editable/traced/manual floor plan exists — gates the plan,
    /// permit, image, and CAD rows.
    let hasPlan: Bool
    /// Whether a 3D model (LiDAR or generated USDZ) exists — gates the model row.
    let hasModel: Bool

    let onPDFReport: () -> Void
    let onPermitPackage: () -> Void
    let onFloorPlanImage: () -> Void
    let onCADFile: () -> Void
    let onModel: () -> Void
    let onBackup: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(title: "PDF Report",
                        description: "The full client-facing report: plan, rooms, estimate, and photos.",
                        systemImage: "doc.richtext",
                        action: onPDFReport)
                    row(title: "Permit Package",
                        description: "A measured drawing set formatted for a permit submission.",
                        systemImage: "checkmark.seal",
                        enabled: hasPlan,
                        disabledNote: "Add a room to build a permit package.",
                        action: onPermitPackage)
                } header: {
                    Text("Documents")
                }

                Section {
                    row(title: "Floor Plan Image",
                        description: "A shareable PNG of the floor plan.",
                        systemImage: "photo",
                        enabled: hasPlan,
                        disabledNote: "Add a room to export a floor plan image.",
                        action: onFloorPlanImage)
                    row(title: "CAD File (DXF)",
                        description: "Walls, openings, and dimensions on separate layers for CAD tools.",
                        systemImage: "ruler",
                        enabled: hasPlan,
                        disabledNote: "Add a room to export a CAD file.",
                        action: onCADFile)
                    row(title: "3D Model (USDZ)",
                        description: "The 3D model, viewable in AR and Quick Look.",
                        systemImage: "cube",
                        enabled: hasModel,
                        disabledNote: "Scan or build a room to export a 3D model.",
                        action: onModel)
                } header: {
                    Text("Drawings & Model")
                }

                Section {
                    row(title: "Back Up Project",
                        description: "The whole project as one file to save, share, or re-import.",
                        systemImage: "externaldrive.badge.timemachine",
                        action: onBackup)
                } footer: {
                    Text("Backups include rooms, plan, estimate, planning, markers, and photos.")
                }
            }
            .navigationTitle("Export & Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func row(title: String,
                     description: String,
                     systemImage: String,
                     enabled: Bool = true,
                     disabledNote: String? = nil,
                     action: @escaping () -> Void) -> some View {
        Button {
            // Record the choice, then dismiss; the parent runs the export once
            // this hub has fully dismissed so its preview sheet can present.
            action()
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(enabled ? .primary : .secondary)
                    Text(enabled ? description : (disabledNote ?? description))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityHint(enabled ? description : (disabledNote ?? ""))
    }
}
