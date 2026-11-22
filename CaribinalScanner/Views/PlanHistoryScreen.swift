import SwiftUI

struct PlanHistoryScreen: View {
    @State private var history: PlanHistory
    let project: RenovationProject
    let onSave: (PlanHistory) -> Void

    @State private var showingSaveRevision = false
    @State private var revisionName = ""
    @State private var saveError: String?
    @State private var showingSamplePreview = false

    init(history: PlanHistory, project: RenovationProject, onSave: @escaping (PlanHistory) -> Void) {
        _history = State(initialValue: history)
        self.project = project
        self.onSave = onSave
    }

    var body: some View {
        List {
            Section("Existing Conditions") {
                snapshotLink(history.existingConditions, label: "Existing Conditions")
            }
            Section("Proposed Revisions") {
                Button("Save Proposed Revision", systemImage: "square.and.arrow.down") {
                    revisionName = ""
                    saveError = nil
                    showingSaveRevision = true
                }
                if history.proposedRevisions.isEmpty {
                    Text("Save a copy of your current editable layout to review and export its measurements.")
                        .foregroundStyle(.secondary)
                }
                ForEach(history.proposedRevisions.reversed()) { snapshot in
                    snapshotLink(snapshot, label: "Proposed · \(snapshot.title)")
                }
            }
            Section("Preview Renovation") {
                Button("Open Sample Bathroom", systemImage: "shower") { showingSamplePreview = true }
                Text("See a finished room drawn from a plan. To preview your own, open a proposed revision and choose a room.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Plan History")
        .fullScreenCover(isPresented: $showingSamplePreview) {
            FinishedPreviewScreen(source: .sample)
        }
        .sheet(isPresented: $showingSaveRevision) {
            NavigationStack {
                Form {
                    TextField("Revision name (optional)", text: $revisionName)
                    if let saveError {
                        Text(saveError).foregroundStyle(.red)
                    }
                }
                .navigationTitle("Save Proposed Revision")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingSaveRevision = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { saveRevision() }
                    }
                }
            }
        }
    }

    private func saveRevision() {
        do {
            let updated = try ScanStore.savePlanSnapshot(for: project, revisionName: revisionName)
            history = updated
            onSave(updated)
            showingSaveRevision = false
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func snapshotLink(_ snapshot: PlanHistory.Snapshot, label: String) -> some View {
        NavigationLink {
            PlanSnapshotScreen(snapshot: snapshot, title: label, project: project,
                               existingConditionsID: history.existingConditions.id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                Text(snapshot.savedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PlanSnapshotScreen: View {
    let snapshot: PlanHistory.Snapshot
    let title: String
    let project: RenovationProject
    let existingConditionsID: UUID

    @AppStorage("useImperialUnits") private var useImperial = true
    @State private var selectedFloor: String?
    @State private var showingModel = false
    @State private var export: SnapshotExport?
    @State private var exportFailed = false
    @State private var measurementExport: MeasurementExport?
    @State private var previewRoom: RoomEntry?

    private var floors: [String] {
        Array(Set(snapshot.rooms.map(\.floorDisplayName))).sorted()
    }

    private var floor: String? { selectedFloor ?? floors.first }

    private var rooms: [RoomEntry] {
        snapshot.rooms.filter { $0.floorDisplayName == floor }
    }

    var body: some View {
        List {
            if floors.count > 1 {
                Picker("Floor", selection: Binding(get: { floor }, set: { selectedFloor = $0 })) {
                    ForEach(floors, id: \.self) { Text($0).tag(Optional($0)) }
                }
            }
            if let plan = FloorPlanModel(rooms: rooms.map(\.room)) {
                Section {
                    FloorPlanCanvas(plan: plan, useImperial: useImperial, markers: snapshot.markers.markers)
                        .frame(height: 340)
                        .accessibilityLabel("Saved floor plan")
                    Button("View 3D Model", systemImage: "cube") { showingModel = true }
                    Button("Export Plan Image", systemImage: "square.and.arrow.up") { exportImage(plan) }
                }
            }
            Section("Saved Measurements") {
                Button("Export for EstiMater", systemImage: "square.and.arrow.up") { exportMeasurements() }
                ForEach(rooms) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name).font(.headline)
                        Text(Measure.area(entry.room.floorAreaSquareMeters, imperial: useImperial))
                        if entry.room.ceilingHeightMeters > 0 {
                            Text("Ceiling: \(Measure.height(entry.room.ceilingHeightMeters, imperial: useImperial)) · \(entry.room.ceilingHeightSourceLabel)")
                        } else {
                            Text("Ceiling: needs a site measurement")
                        }
                        if let clearance = entry.room.bulkheadClearanceMeters {
                            Text("Bulkhead clearance: \(Measure.height(clearance, imperial: useImperial))")
                        }
                        if entry.room.outlineNeedsVerification == true {
                            Text("Approximate outline. Verify on site.")
                        }
                        if snapshot.id != existingConditionsID {
                            Button("Preview Renovation", systemImage: "sparkles.rectangle.stack") { previewRoom = entry }
                                .buttonStyle(.borderless)
                                .padding(.top, 2)
                        }
                    }
                    .font(.subheadline)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingModel) {
            Model3DScreen(project: project, snapshotRooms: rooms, title: title)
        }
        .fullScreenCover(item: $previewRoom) { entry in
            FinishedPreviewScreen(source: FinishedPreviewSource(room: entry.room, roomName: entry.name,
                                                                revisionTitle: snapshot.title, savedAt: snapshot.savedAt))
        }
        .sheet(item: $export) { file in
            ExportPreviewSheet(title: title, url: file.url) {
                Image(uiImage: file.image).resizable().scaledToFit().padding()
            }
        }
        .sheet(item: $measurementExport) { file in
            ExportPreviewSheet(title: "EstiMater Measurements", url: file.url) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.headline)
                    Text("\(snapshot.rooms.count) rooms across \(floors.count) floors")
                    Text("Save this file to Files, then choose it in EstiMater under Scanner measurements.")
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
        }
        .alert("Could Not Export Plan", isPresented: $exportFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    @MainActor
    private func exportImage(_ plan: FloorPlanModel) {
        let renderer = ImageRenderer(content:
            VStack(spacing: 4) {
                Text(title).font(.title.bold())
                Text([project.name, floor, snapshot.savedAt.formatted(date: .abbreviated, time: .omitted)]
                    .compactMap { $0 }.joined(separator: " · "))
                FloorPlanCanvas(plan: plan, useImperial: useImperial, markers: snapshot.markers.markers,
                                layers: PlanLayers(), exportBackground: true)
                    .frame(width: 800, height: 720)
            }
            .frame(width: 820, height: 820)
            .foregroundStyle(.black)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        )
        renderer.scale = 2
        guard let image = renderer.uiImage, let data = image.pngData() else {
            exportFailed = true
            return
        }
        let label = [title, floor].compactMap { $0 }.joined(separator: " - ")
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(snapshot.id.uuidString)
        let url = directory.appendingPathComponent("\(label.prefix(100)).png")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            export = SnapshotExport(url: url, image: image)
        } catch {
            exportFailed = true
        }
    }

    private func exportMeasurements() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(snapshot.id.uuidString)
        let label = snapshot.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let suffix = snapshot.id.uuidString.prefix(8)
        let url = directory.appendingPathComponent("\(label.prefix(70)) - \(suffix).json")
        do {
            let payload = ScannerRevisionExport(snapshot: snapshot, existingConditionsID: existingConditionsID)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(payload).write(to: url, options: .atomic)
            measurementExport = MeasurementExport(url: url)
        } catch {
            exportFailed = true
        }
    }

    private struct MeasurementExport: Identifiable {
        let url: URL
        var id: URL { url }
    }

    private struct SnapshotExport: Identifiable {
        let url: URL
        let image: UIImage
        var id: URL { url }
    }
}
