import SwiftUI
import SwiftData
import ARKit
import AVFoundation

/// Full-screen AR corner capture: walk the room, aim the crosshair at each
/// floor corner, tap Mark Corner. Works on any ARKit iPhone — no LiDAR
/// needed. Produces a floor plan and a simple extruded 3D model.
struct CornerCaptureScreen: View {
    let project: RenovationProject
    /// Room to recapture in place; nil adds a new room to the project.
    let targetRoomID: UUID?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("useImperialUnits") private var useImperial = true
    @StateObject private var controller = CornerCaptureController()
    @State private var cameraDenied = false
    @State private var showingFinishSheet = false
    @State private var squareUpWalls = true
    @State private var ceilingMeters: Double
    @State private var isSaving = false
    @State private var saveError: String?

    init(project: RenovationProject, targetRoomID: UUID? = nil) {
        self.project = project
        self.targetRoomID = targetRoomID
        // QA-045: when recapturing an existing room, seed the ceiling height
        // from that room, not from the (possibly unrelated) manual-entry room.
        // New rooms fall back to the manual room's height, then 2.4 m.
        var existingCeiling = 0.0
        if let targetRoomID,
           let room = ScanStore.loadRooms(for: project).first(where: { $0.id == targetRoomID })?.room {
            existingCeiling = room.ceilingHeightMeters
        }
        if existingCeiling <= 0 {
            existingCeiling = ScanStore.loadManualRoom(for: project)?.ceilingHeightMeters ?? 0
        }
        _ceilingMeters = State(initialValue: existingCeiling > 0 ? existingCeiling
                                                                 : AppSettings.defaultCeilingMeters)
    }

    var body: some View {
        ZStack {
            ARCaptureViewRep(controller: controller)
                .ignoresSafeArea()

            Image(systemName: "plus")
                .font(.title)
                .foregroundStyle(controller.crosshairReady ? Color.green : Color.orange)
                .shadow(radius: 2)
                .accessibilityLabel("Aiming crosshair")
                .accessibilityValue(controller.crosshairReady ? "Ready to mark a corner" : "Not on the floor yet")

            VStack(spacing: 10) {
                HStack(alignment: .top) {
                    Button("Cancel") {
                        controller.stop()
                        dismiss()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Corners: \(controller.cornerCount)")
                        if let lastWallText = controller.lastWallText {
                            Text("Last wall: \(lastWallText)")
                        }
                    }
                    .font(.footnote.bold())
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityElement(children: .combine)
                }

                if let status = controller.trackingStatus {
                    Text(status)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }

                if let hint = controller.hint {
                    Text(hint)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }

                if controller.trackingStatus == nil && controller.hint == nil && !controller.crosshairReady {
                    Text("Aim the crosshair at the floor — it turns green when a corner can be marked.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }

                if controller.cornerCount == 0 {
                    Text("Walk the room and aim the crosshair at each floor corner, in order around the room, then tap Mark Corner. The wall back to the first corner closes automatically when you finish.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }

                Spacer()

                HStack(spacing: 12) {
                    Button("Undo") { controller.undo() }
                        .buttonStyle(.bordered)
                        .disabled(controller.cornerCount == 0)
                        .accessibilityHint("Removes the last marked corner")
                    Button("Mark Corner") { controller.markCorner() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint("Places a corner where the crosshair is aimed")
                    Button("Finish") { showingFinishSheet = true }
                        .buttonStyle(.bordered)
                        .disabled(controller.cornerCount < 3)
                        .accessibilityHint("Closes the outline and sets the ceiling height")
                }
                .padding(.bottom, 8)
            }
            .padding()

            if cameraDenied {
                VStack(spacing: 16) {
                    Image(systemName: "camera.fill")
                        .font(.largeTitle)
                        .accessibilityHidden(true)
                    Text("Camera access is turned off")
                        .font(.headline)
                    Text("Corner capture needs the camera. Turn it on in Settings → Reno Planner → Camera, then come back.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.bordered)
                }
                .foregroundStyle(.white)
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.88))
                .ignoresSafeArea()
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            checkPermissionAndStart()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            controller.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, cameraDenied,
                  AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
            cameraDenied = false
            controller.start()
        }
        .sheet(isPresented: $showingFinishSheet) {
            NavigationStack {
                Form {
                    Section {
                        DimensionRow(label: "Ceiling height", meters: $ceilingMeters, imperial: useImperial)
                    } footer: {
                        Text("Used for the 3D model, floor plan summary, and suite assessment.")
                    }
                    Section {
                        Toggle("Square up walls", isOn: $squareUpWalls)
                        LabeledContent("Corners captured", value: "\(controller.cornerCount)")
                    } footer: {
                        Text("Snaps corners that are close to 90° to exactly 90°, correcting small tracking drift. Turn off for rooms with angled walls.")
                    }
                }
                .navigationTitle("Finish Capture")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Back") { showingFinishSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if isSaving {
                            ProgressView()
                        } else {
                            Button("Save") { save() }
                        }
                    }
                }
            }
            .presentationDetents([.medium])
            .interactiveDismissDisabled(isSaving)
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

    private func checkPermissionAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            controller.start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        controller.start()
                    } else {
                        cameraDenied = true
                    }
                }
            }
        default:
            cameraDenied = true
        }
    }

    private func save() {
        isSaving = true
        var points = controller.corners.map { CornerRoom.Point(x: Double($0.x), z: Double($0.z)) }
        if squareUpWalls {
            points = RoomSquarer.squared(points)
        }
        // QA-046: reject self-intersecting or degenerate outlines before they
        // reach disk — a bow-tie or near-zero-area polygon corrupts every
        // downstream feature (area, takeoff, 3D). Keep the session alive so
        // the user can undo/re-mark corners.
        let polygon = points.map { SIMD2<Double>($0.x, $0.z) }
        guard ScanConverter.isSimplePolygon(polygon) else {
            saveError = "Corners cross each other — mark corners in order around the room."
            isSaving = false
            return
        }
        let captured = CornerRoom(corners: points, ceilingHeightMeters: ceilingMeters)
        guard captured.floorAreaSquareMeters >= ScanConverter.minRoomArea else {
            saveError = "This outline is too small to be a room — mark the corners around the whole floor."
            isSaving = false
            return
        }
        do {
            var rooms = ScanStore.loadRooms(for: project)
            if let targetRoomID, let index = rooms.firstIndex(where: { $0.id == targetRoomID }) {
                // QA-044: recapture replaces only the outline geometry. Carry
                // the old room's finishes and contents forward so they aren't
                // silently discarded. Interior walls and fixtures live in
                // shared plan space and survive placedOver's alignment (which
                // keeps the old min corner). Openings reference outline-wall
                // indices that no longer match the new corner count, so they
                // are dropped rather than land on the wrong walls.
                let old = rooms[index].room
                var placed = captured.placedOver(old)
                placed.fixtures = old.fixtures
                placed.interiorWalls = old.interiorWalls
                placed.floorType = old.floorType
                placed.floorHex = old.floorHex
                placed.outlineWallHex = old.outlineWallHex
                rooms[index].room = placed
            } else {
                rooms.append(RoomEntry(name: "Room \(rooms.count + 1)",
                                       room: captured.placedAlongside(rooms)))
            }
            try ScanStore.saveRooms(rooms, for: project)
            let dir = try ScanStore.folder(for: project)
            Model3DBuilder.writeUSDZInBackground(rooms: rooms.map(\.room),
                                         to: dir.appendingPathComponent(ScanStore.usdzFileName))
            project.scanDate = .now
            try? modelContext.save()
            controller.stop()
            showingFinishSheet = false
            dismiss()
        } catch {
            saveError = error.localizedDescription
            isSaving = false
        }
    }
}

struct ARCaptureViewRep: UIViewRepresentable {
    let controller: CornerCaptureController

    func makeUIView(context: Context) -> ARSCNView {
        controller.arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
