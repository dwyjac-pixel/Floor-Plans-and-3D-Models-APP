import SwiftUI
import RoomPlan
import ARKit

/// A small chooser sheet listing the ways to add a room, in plain language.
/// It owns no capture logic: each row calls a closure supplied by
/// ProjectDetailView that drives that view's existing sheets/covers, so the
/// capture flows stay in one place.
struct AddRoomSheet: View {
    /// Start a LiDAR RoomPlan scan (sets `showingScanner`).
    let onLiDAR: () -> Void
    /// Walk the room and mark each floor corner with the camera
    /// (sets `showingCornerCapture`).
    let onCorner: () -> Void
    /// Trace a blueprint photo or PDF (sets `showingPlanTrace`).
    let onTrace: () -> Void
    /// Type width/length measurements by hand (sets `showingManualEntry`).
    let onManual: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var lidarSupported: Bool { RoomCaptureSession.isSupported }
    private var cameraSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    var body: some View {
        NavigationStack {
            List {
                if lidarSupported {
                    Section {
                        row(title: "Scan with LiDAR",
                            description: "Point the camera and walk the room — walls, doors, and windows are measured automatically.",
                            systemImage: "cube.transparent",
                            recommended: true,
                            action: onLiDAR)
                    } footer: {
                        Text("Recommended on this device — the fastest, most accurate way to capture a room.")
                    }
                }

                Section {
                    if cameraSupported {
                        row(title: "Walk & mark corners",
                            description: "Tap each floor corner with the camera to trace the room's outline.",
                            systemImage: "camera.viewfinder",
                            action: onCorner)
                    }
                    row(title: "Trace a blueprint photo",
                        description: "Import a photo or PDF of a plan and trace the walls over it.",
                        systemImage: "doc.viewfinder",
                        action: onTrace)
                    row(title: "Type measurements",
                        description: "Enter the room's width and length by hand — no camera needed.",
                        systemImage: "square.and.pencil",
                        action: onManual)
                } footer: {
                    if !lidarSupported {
                        Text("LiDAR scanning isn't available on this device — use the camera, trace a plan, or enter measurements.")
                    }
                }
            }
            .navigationTitle("Add a Room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func row(title: String,
                     description: String,
                     systemImage: String,
                     recommended: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button {
            // Record the choice, then dismiss; the parent presents the actual
            // capture flow once this sheet has fully gone away.
            action()
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        if recommended {
                            Text("Recommended")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15),
                                            in: Capsule())
                                .foregroundStyle(.tint)
                        }
                    }
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(recommended ? "\(title), recommended" : title)
        .accessibilityHint(description)
    }
}
