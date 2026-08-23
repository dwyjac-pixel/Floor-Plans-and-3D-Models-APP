import SwiftUI
import SwiftData
import RoomPlan

/// Full-screen scanning flow: walk the room with the camera, finish the scan,
/// review RoomPlan's processed result, then save it into the project.
struct ScanScreen: View {
    let project: RenovationProject

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var controller = ScanSessionController()
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        ZStack {
            RoomCaptureViewRep(controller: controller)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Button("Cancel") {
                        controller.cancel()
                        dismiss()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    Spacer()
                }
                Spacer()
                bottomBar
            }
            .padding()
        }
        .onAppear {
            ScanDebugLog.log("ScanScreen.onAppear: begin")
            // Scanning is a long hands-busy task — never let the screen sleep.
            UIApplication.shared.isIdleTimerDisabled = true
            controller.start()
            ScanDebugLog.log("ScanScreen.onAppear: end")
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .alert("Scan Problem", isPresented: alertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? controller.errorMessage ?? "Something went wrong.")
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if controller.isProcessing || isSaving {
            ProgressView(isSaving ? "Saving…" : "Processing scan…")
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(isSaving ? "Saving" : "Processing scan")
        } else if controller.didFinish {
            HStack(spacing: 12) {
                Button("Rescan") { controller.start() }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Discards this scan and starts a new one")
                Button("Save Scan") { save() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Adds the scanned room to the project")
            }
            .padding(.bottom, 8)
        } else if controller.didFail {
            VStack(spacing: 10) {
                Text("Scan failed — the camera lost tracking.")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                Button("Rescan") { controller.start() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.bottom, 8)
        } else {
            Button("Finish Scan") { controller.finish() }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Ends the walkthrough and processes the room")
                .padding(.bottom, 8)
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { saveError != nil || controller.errorMessage != nil },
            set: { presented in
                if !presented {
                    saveError = nil
                    controller.errorMessage = nil
                }
            }
        )
    }

    private func save() {
        guard let room = controller.finishedRoom else { return }
        isSaving = true
        // QA-012: `folder(for:)` reads `project.folderName` — a SwiftData
        // @Model property — so resolve the project's directory URL here on the
        // main actor and hand only the plain URL to the detached task. Nothing
        // inside the task touches the model, so there's no cross-thread @Model
        // read. The heavy encode/USDZ export still runs off the main actor.
        let dir: URL
        do {
            dir = try ScanStore.folder(for: project)
        } catch {
            saveError = error.localizedDescription
            isSaving = false
            return
        }
        // The USDZ export can take seconds — keep it off the main actor so
        // the "Saving…" spinner actually spins.
        Task.detached(priority: .userInitiated) {
            do {
                // Mirrors ScanStore.save(capturedRoom:for:), but writes into a
                // directory resolved on the main actor (QA-012) so the detached
                // work never reads the SwiftData @Model. room.json is written
                // first so a fragile USDZ export can't lose the scan.
                let data = try JSONEncoder().encode(room)
                try ScanStore.coordinatedWrite(data,
                                               to: dir.appendingPathComponent(ScanStore.roomDataFileName))
                // Export to a Caches temp and swap under coordination —
                // dir may be inside the iCloud container, where a direct
                // multi-second export would race the sync daemon.
                let usdz = dir.appendingPathComponent(ScanStore.lidarUSDZFileName)
                let temp = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("\(UUID().uuidString).tmp.usdz")
                do {
                    do {
                        try room.export(to: temp, exportOptions: .parametric)
                    } catch {
                        try room.export(to: temp, exportOptions: .mesh)
                    }
                    try ScanStore.coordinatedReplace(at: usdz, withItemAt: temp)
                } catch {
                    // Export failed — drop the temp and any stale USDZ (QA-048).
                    try? FileManager.default.removeItem(at: temp)
                    ScanStore.coordinatedDelete(at: usdz)
                }
                await MainActor.run {
                    controller.cancel()
                    project.scanDate = .now
                    try? modelContext.save()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    saveError = error.localizedDescription
                    isSaving = false
                }
            }
        }
    }
}
