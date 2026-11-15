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
    @State private var walkID = UUID()
    private struct PendingWalk {
        let floorName: String
        let rooms: [CapturedRoom]
        let interruptedRoom: Bool
    }

    @State private var pendingWalk: PendingWalk?
    @State private var completedReview: ScanWalkReview?
    @State private var savedRooms: [RoomEntry] = []
    @State private var showingFloorChoice = false
    @State private var showingCustomFloor = false
    @State private var customFloorName = ""

    var body: some View {
        ZStack {
            RoomCaptureViewRep(controller: controller)
                .id(ObjectIdentifier(controller.captureView))
                .ignoresSafeArea()
                .onAppear { controller.start() }

            VStack {
                HStack {
                    Button("Cancel") {
                        controller.cancel()
                        dismiss()
                    }
                    .disabled(isSaving)
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
            ScanDebugLog.log("ScanScreen.onAppear: end")
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .sheet(item: $completedReview, onDismiss: { dismiss() }) { review in
            NavigationStack {
                ScanReviewScreen(review: review, rooms: savedRooms)
            }
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
        } else if let pendingWalk {
            Button("Retry Save") { save(floorName: pendingWalk.floorName) }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 8)
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
                if controller.capturedRooms.isEmpty {
                    Button("Rescan") { controller.restartAfterTrackingFailure() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Save Earlier Rooms") { showingFloorChoice = true }
                        .buttonStyle(.borderedProminent)
                }
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

    /// Saves every room from this walk: raw scan data, auto-converted
    /// editable rooms tagged with the chosen floor, and the merged walk
    /// USDZ. One room or ten — same path.
    private func save(floorName: String) {
        let interruptedRoom = controller.didFail
        let walk = pendingWalk ?? PendingWalk(
            floorName: floorName,
            rooms: interruptedRoom ? controller.capturedRooms : controller.walkRooms,
            interruptedRoom: interruptedRoom)
        guard !walk.rooms.isEmpty, !isSaving else { return }
        pendingWalk = walk
        isSaving = true
        // Resolve the SwiftData project's directory on the main actor.
        // The detached task works with file URLs and captured room values.
        let dir: URL
        do {
            dir = try ScanStore.folder(for: project)
        } catch {
            saveError = error.localizedDescription
            isSaving = false
            return
        }
        let id = walkID
        Task.detached(priority: .userInitiated) {
            do {
                let result = try await ScanStore.saveScanWalk(id: id, rooms: walk.rooms,
                                                              floorName: walk.floorName,
                                                              interruptedRoom: walk.interruptedRoom,
                                                              directory: dir)
                await MainActor.run {
                    controller.cancel()
                    project.scanDate = .now
                    try? modelContext.save()
                    isSaving = false
                    savedRooms = result.rooms
                    completedReview = result.review
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


struct ScanReviewScreen: View {
    let review: ScanWalkReview
    let rooms: [RoomEntry]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section(review.floorName) {
                ForEach(Array(review.items.enumerated()), id: \.offset) { index, item in
                    VStack(alignment: .leading, spacing: 5) {
                        let room = rooms.first { $0.id == item.roomID }
                        Text(room?.name ?? "Room \(index + 1)").font(.headline)
                        if let room {
                            Label("Added to the floor plan", systemImage: "checkmark.circle")
                            if room.room.outlineNeedsVerification == true {
                                Label("Approximate outline. Check wall lengths and shape on site.",
                                      systemImage: "exclamationmark.triangle")
                            }
                            if room.room.fieldMeasuredCeilingMeters == nil {
                                Label("Measure ceiling height on site.", systemImage: "ruler")
                            }
                        } else if item.interrupted == true {
                            Label("Capture interrupted. Scan this room again or enter measurements.",
                                  systemImage: "exclamationmark.triangle")
                        } else if item.roomID == nil {
                            Label("No usable outline. Rescan this room or enter measurements.",
                                  systemImage: "exclamationmark.triangle")
                        } else {
                            Label("This room is missing from the current floor plan.",
                                  systemImage: "exclamationmark.triangle")
                        }
                    }
                    .font(.subheadline)
                }
            }
        }
        .navigationTitle("Scan Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

struct LatestScanReviewScreen: View {
    let url: URL
    let rooms: [RoomEntry]

    @State private var review: ScanWalkReview?
    @State private var message: String?

    var body: some View {
        Group {
            if let review {
                ScanReviewScreen(review: review, rooms: rooms)
            } else if let message {
                ContentUnavailableView(message, systemImage: "list.clipboard")
            } else {
                ProgressView("Loading scan review…")
            }
        }
        .task {
            do {
                let fileURL = url
                review = try await Task.detached {
                    try ScanStore.latestScanReview(at: fileURL)
                }.value
                if review == nil { message = "No review is available for this scan." }
            } catch {
                message = "Could not read the scan review."
            }
        }
    }
}
