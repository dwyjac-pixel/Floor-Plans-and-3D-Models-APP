import SwiftUI

/// Manual measurement entry for devices without LiDAR (or as a backup when
/// scanning isn't practical). A main rectangle plus bump-outs for L-shapes,
/// with doors, windows and openings placed along the main walls; produces
/// the same floor plan, summary and PDF output as a LiDAR scan.
struct ManualRoomEntryScreen: View {
    let project: RenovationProject
    var onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("useImperialUnits") private var useImperial = true

    @State private var room: ManualRoom
    @State private var editingFeature: ManualRoom.Feature?
    @State private var editingBumpOut: ManualRoom.BumpOut?
    @State private var saveError: String?
    @State private var pendingDropWarning: String?

    init(project: RenovationProject, onSave: @escaping () -> Void) {
        self.project = project
        self.onSave = onSave
        _room = State(initialValue: ScanStore.loadManualRoom(for: project) ?? ManualRoom())
    }

    var body: some View {
        Form {
            Section {
                Picker("Units", selection: $useImperial) {
                    Text("Feet & inches").tag(true)
                    Text("Metres").tag(false)
                }
                .pickerStyle(.segmented)
            }

            Section {
                DimensionRow(label: "Width", meters: $room.widthMeters, imperial: useImperial)
                DimensionRow(label: "Length", meters: $room.lengthMeters, imperial: useImperial)
                DimensionRow(label: "Ceiling height", meters: $room.ceilingHeightMeters, imperial: useImperial)
            } header: {
                Text("Room Size")
            } footer: {
                Text("Width runs along the top of the preview, length down the side. Use bump-outs below for L-shaped spaces.")
            }

            if let preview = FloorPlanModel(manual: room) {
                Section("Preview") {
                    FloorPlanCanvas(plan: preview, useImperial: useImperial)
                        .frame(height: 260)
                        .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
                        .accessibilityElement()
                        .accessibilityLabel("Floor plan preview")
                        .accessibilityHint("Shows the room outline from the measurements above")
                }
            }

            Section {
                ForEach(room.bumpOuts) { bump in
                    Button {
                        editingBumpOut = bump
                    } label: {
                        Text(bumpOutLabel(bump))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                    .accessibilityLabel("Bump-out: \(bumpOutLabel(bump))")
                    .accessibilityHint("Double tap to edit, swipe to delete")
                }
                .onDelete { room.bumpOuts.remove(atOffsets: $0) }

                Button("Add Bump-Out") {
                    editingBumpOut = ManualRoom.BumpOut(wallIndex: 0, offsetMeters: 0,
                                                        widthMeters: 3.0, depthMeters: 2.0)
                }
            } header: {
                Text("Bump-Outs (L-Shapes)")
            } footer: {
                Text("A bump-out extends the room outward from a wall. Floor area adds up automatically. Doors and windows can only sit on the main rectangle's walls for now.")
            }

            Section {
                ForEach(room.features) { feature in
                    Button {
                        editingFeature = feature
                    } label: {
                        Text(featureLabel(feature))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                    .accessibilityLabel(featureLabel(feature))
                    .accessibilityHint("Double tap to edit, swipe to delete")
                }
                .onDelete { room.features.remove(atOffsets: $0) }

                Button("Add Door") { addFeature(.door) }
                Button("Add Closet Door") { addFeature(.closetDoor) }
                Button("Add Window") { addFeature(.window) }
                Button("Add Opening") { addFeature(.opening) }
            } header: {
                Text("Doors, Windows & Openings")
            } footer: {
                Text("Tap an item to adjust it, swipe to delete. Positions are measured from the corner where each wall begins, going clockwise. Check the preview and adjust until it matches the room.")
            }
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .navigationTitle("Manual Measurements")
        .keyboardDoneButton()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(room.widthMeters <= 0 || room.lengthMeters <= 0)
            }
        }
        .sheet(item: $editingFeature) { feature in
            FeatureEditorSheet(feature: feature, imperial: useImperial) { updated in
                if let index = room.features.firstIndex(where: { $0.id == updated.id }) {
                    room.features[index] = updated
                } else {
                    room.features.append(updated)
                }
            }
        }
        .sheet(item: $editingBumpOut) { bump in
            BumpOutEditorSheet(bumpOut: bump, imperial: useImperial) { updated in
                if let index = room.bumpOuts.firstIndex(where: { $0.id == updated.id }) {
                    room.bumpOuts[index] = updated
                } else {
                    room.bumpOuts.append(updated)
                }
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
        .alert("Some Items Are Off the Wall", isPresented: Binding(
            get: { pendingDropWarning != nil },
            set: { if !$0 { pendingDropWarning = nil } }
        )) {
            Button("Save Anyway") { commit() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text(pendingDropWarning ?? "")
        }
    }

    private func addFeature(_ kind: ManualRoom.Feature.Kind) {
        let defaultWidth: Double
        switch kind {
        case .door: defaultWidth = 0.81      // 32-inch door
        case .closetDoor: defaultWidth = 1.52  // 60-inch bifold pair
        case .window: defaultWidth = 1.2
        case .opening: defaultWidth = 1.5
        }
        editingFeature = ManualRoom.Feature(kind: kind, wallIndex: 0, offsetMeters: 1.0, widthMeters: defaultWidth)
    }

    private func featureLabel(_ feature: ManualRoom.Feature) -> String {
        let wall = ManualRoom.wallNames[min(max(feature.wallIndex, 0), 3)]
        let offset = Measure.length(feature.offsetMeters, imperial: useImperial)
        let width = Measure.length(feature.widthMeters, imperial: useImperial)
        return "\(feature.kind.rawValue): \(wall), \(offset) from corner, \(width) wide"
    }

    private func bumpOutLabel(_ bump: ManualRoom.BumpOut) -> String {
        let wall = ManualRoom.wallNames[min(max(bump.wallIndex, 0), 3)]
        let width = Measure.length(bump.widthMeters, imperial: useImperial)
        let depth = Measure.length(bump.depthMeters, imperial: useImperial)
        let offset = Measure.length(bump.offsetMeters, imperial: useImperial)
        return "\(wall): \(width) wide × \(depth) deep, \(offset) from corner"
    }

    /// The length of the main-rectangle wall a feature/bump-out sits on:
    /// top/bottom walls run the room width, the sides run its length.
    private func wallLength(for wallIndex: Int) -> Double {
        (min(max(wallIndex, 0), 3) % 2 == 0) ? room.widthMeters : room.lengthMeters
    }

    /// Features and bump-outs whose start offset is at or past the end of
    /// their wall — the conversion drops these silently, so we warn.
    private var outOfRangeCount: Int {
        let features = room.features.filter { $0.offsetMeters >= wallLength(for: $0.wallIndex) }
        let bumps = room.bumpOuts.filter { $0.offsetMeters >= wallLength(for: $0.wallIndex) }
        return features.count + bumps.count
    }

    private func save() {
        // A sub-0.1 m rectangle produces an unbuildable plan (the conversion
        // returns nil) — reject it with a clear message rather than saving.
        guard room.widthMeters >= 0.1, room.lengthMeters >= 0.1 else {
            saveError = "Enter a width and length of at least 0.1 m (about 4 in). The current room is too small to build a plan from."
            return
        }
        let dropped = outOfRangeCount
        if dropped > 0 {
            pendingDropWarning = "\(dropped) item\(dropped == 1 ? "" : "s") start\(dropped == 1 ? "s" : "") past the end of \(dropped == 1 ? "its" : "their") wall and won't appear on the plan. Save anyway?"
            return
        }
        commit()
    }

    private func commit() {
        do {
            try ScanStore.saveManualRoom(room, for: project)
            onSave()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

struct FeatureEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var feature: ManualRoom.Feature
    let imperial: Bool
    let onSave: (ManualRoom.Feature) -> Void

    init(feature: ManualRoom.Feature, imperial: Bool, onSave: @escaping (ManualRoom.Feature) -> Void) {
        _feature = State(initialValue: feature)
        self.imperial = imperial
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $feature.kind) {
                    ForEach(ManualRoom.Feature.Kind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                Picker("Wall", selection: $feature.wallIndex) {
                    ForEach(0..<4) { index in
                        Text(ManualRoom.wallNames[index]).tag(index)
                    }
                }
                DimensionRow(label: "Distance from corner", meters: $feature.offsetMeters, imperial: imperial)
                DimensionRow(label: "Width", meters: $feature.widthMeters, imperial: imperial)
            }
            .navigationTitle(feature.kind.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(feature)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct BumpOutEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var bumpOut: ManualRoom.BumpOut
    let imperial: Bool
    let onSave: (ManualRoom.BumpOut) -> Void

    init(bumpOut: ManualRoom.BumpOut, imperial: Bool, onSave: @escaping (ManualRoom.BumpOut) -> Void) {
        _bumpOut = State(initialValue: bumpOut)
        self.imperial = imperial
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Wall", selection: $bumpOut.wallIndex) {
                    ForEach(0..<4) { index in
                        Text(ManualRoom.wallNames[index]).tag(index)
                    }
                }
                DimensionRow(label: "Distance from corner", meters: $bumpOut.offsetMeters, imperial: imperial)
                DimensionRow(label: "Width along wall", meters: $bumpOut.widthMeters, imperial: imperial)
                DimensionRow(label: "Depth outward", meters: $bumpOut.depthMeters, imperial: imperial)
            }
            .navigationTitle("Bump-Out")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(bumpOut)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// One measurement input row. Imperial mode shows feet + inches fields;
/// metric mode shows a single metres field. The bound value is always metres.
struct DimensionRow: View {
    let label: String
    @Binding var meters: Double
    let imperial: Bool

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            if imperial {
                TextField("0", value: feetBinding, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                    .accessibilityLabel("\(label), feet")
                Text("ft")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("0", value: inchesBinding, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 44)
                    .accessibilityLabel("\(label), inches")
                Text("in")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } else {
                TextField("0.0", value: metersFieldBinding, format: .number.precision(.fractionLength(0...2)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .accessibilityLabel("\(label), metres")
                Text("m")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    private var totalWholeInches: Int {
        Int((meters / 0.0254).rounded())
    }

    private var feetBinding: Binding<Int> {
        Binding(
            get: { totalWholeInches / 12 },
            set: { newFeet in
                meters = Double(max(newFeet, 0) * 12 + totalWholeInches % 12) * 0.0254
            }
        )
    }

    private var inchesBinding: Binding<Int> {
        Binding(
            get: { totalWholeInches % 12 },
            set: { newInches in
                meters = Double((totalWholeInches / 12) * 12 + min(max(newInches, 0), 11)) * 0.0254
            }
        )
    }

    private var metersFieldBinding: Binding<Double> {
        Binding(
            get: { meters },
            set: { meters = max($0, 0) }
        )
    }
}
