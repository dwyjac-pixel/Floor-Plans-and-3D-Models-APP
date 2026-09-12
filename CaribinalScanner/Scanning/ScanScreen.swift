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
    @State private var dismissOnAlertClose = false
    @State private var showingFloorChoice = false
    @State private var showingCustomFloor = false
    @State private var customFloorName = ""

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
        .confirmationDialog("Which floor is this?", isPresented: $showingFloorChoice,
                            titleVisibility: .visible) {
            ForEach([RoomEntry.defaultFloorName, "Basement", "Second Floor", "Garage"], id: \.self) { floor in
                Button(floor) { save(floorName: floor) }
            }
            Button("Other Floor…") { showingCustomFloor = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The rooms from this walk are converted to an editable floor plan and tagged with the floor you pick.")
        }
        .alert("Floor Name", isPresented: $showingCustomFloor) {
            TextField("e.g. Third Floor, Suite B", text: $customFloorName)
            Button("Save") {
                let name = customFloorName.trimmingCharacters(in: .whitespaces)
                save(floorName: name.isEmpty ? RoomEntry.defaultFloorName : name)
            }
            Button("Cancel", role: .cancel) {}
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
            VStack(spacing: 10) {
                if !controller.capturedRooms.isEmpty {
                    Text("\(controller.walkRooms.count) rooms captured this walk")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())
                }
                HStack(spacing: 12) {
                    Button("Rescan") { controller.start() }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Discards this room's scan and redoes it")
                    Button("Scan Next Room") { controller.scanNextRoom() }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Keeps this room and continues scanning the next one in the same walk")
                    Button(controller.capturedRooms.isEmpty ? "Save" : "Finish Floor") {
                        showingFloorChoice = true
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Converts every room from this walk into the floor plan")
                }
            }
            .padding(.bottom, 8)
        } else if controller.didFail {
            VStack(spacing: 10) {
                Text("Scan failed: the camera lost tracking.")
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
                    if dismissOnAlertClose {
                        dismissOnAlertClose = false
                        dismiss()
                    }
                }
            }
        )
    }

    /// Saves every room from this walk: raw scan data, auto-converted
    /// editable rooms tagged with the chosen floor, and the merged walk
    /// USDZ. One room or ten — same path.
    private func save(floorName: String) {
        let rooms = controller.walkRooms
        guard !rooms.isEmpty else { return }
        isSaving = true
        // QA-012: resolve the project's directory and load existing state
        // here on the main actor; the detached task gets plain values and
        // never reads the SwiftData @Model. The heavy conversion and USDZ
        // work still runs off the main actor.
        let dir: URL
        do {
            dir = try ScanStore.folder(for: project)
        } catch {
            saveError = error.localizedDescription
            isSaving = false
            return
        }
        let existingRooms = ScanStore.loadRooms(for: project)
        let existingWalks = ScanStore.loadScanWalks(for: project)
        Task.detached(priority: .userInitiated) {
            do {
                let result = try await ScanStore.saveScanWalk(rooms: rooms,
                                                              floorName: floorName,
                                                              existingRooms: existingRooms,
                                                              existingWalks: existingWalks,
                                                              directory: dir)
                await MainActor.run {
                    controller.cancel()
                    project.scanDate = .now
                    try? modelContext.save()
                    if result.failed > 0 {
                        isSaving = false
                        dismissOnAlertClose = result.added > 0
                        let added = result.added == 1 ? "1 room" : "\(result.added) rooms"
                        saveError = result.added > 0
                            ? "\(added) added to \(floorName). \(result.failed) couldn't build a clean outline. Rescan that one with a slower walk-through."
                            : "This room couldn't build a clean outline. Try rescanning with a slower walk-through. The raw scan data was kept."
                    } else {
                        dismiss()
                    }
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
