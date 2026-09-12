import SwiftUI

/// Site measurements required on basement development / secondary suite
/// permit applications that aren't part of room geometry: clearances under
/// beams and bulkheads, stair head clearance, and the bedroom count being
/// created. Window/door sizes and ceilings come from the captured rooms.
struct PermitMeasurements: Codable {
    var beamHeightMeters: Double = 0        // finish height under beam / bulkhead
    var stairHeadClearanceMeters: Double = 0
    var bedroomsCreated: Int = 0
    var notes = ""

    init() {}

    private enum CodingKeys: String, CodingKey {
        case beamHeightMeters, stairHeadClearanceMeters, bedroomsCreated, notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        beamHeightMeters = try container.decodeIfPresent(Double.self, forKey: .beamHeightMeters) ?? 0
        stairHeadClearanceMeters = try container.decodeIfPresent(Double.self, forKey: .stairHeadClearanceMeters) ?? 0
        bedroomsCreated = try container.decodeIfPresent(Int.self, forKey: .bedroomsCreated) ?? 0
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

/// One screen holding every number the permit application asks for —
/// live values pulled from the captured rooms, plus on-site entries.
struct PermitMeasurementsScreen: View {
    let project: RenovationProject
    var onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("useImperialUnits") private var useImperial = true

    @State private var measurements: PermitMeasurements
    private let rooms: [RoomEntry]

    init(project: RenovationProject, onSave: @escaping () -> Void) {
        self.project = project
        self.onSave = onSave
        _measurements = State(initialValue: ScanStore.loadPermitMeasurements(for: project) ?? PermitMeasurements())
        self.rooms = ScanStore.loadRooms(for: project)
    }

    private func sizeText(w: Double, h: Double) -> String {
        "\(Measure.length(w, imperial: useImperial)) × \(Measure.length(h, imperial: useImperial))"
    }

    var body: some View {
        Form {
            Section {
                DimensionRow(label: "Finish height under beam / bulkhead",
                             meters: $measurements.beamHeightMeters, imperial: useImperial)
                DimensionRow(label: "Head clearance at stairs",
                             meters: $measurements.stairHeadClearanceMeters, imperial: useImperial)
                Stepper("Bedrooms being created: \(measurements.bedroomsCreated)",
                        value: $measurements.bedroomsCreated, in: 0...6)
            } header: {
                Text("Measure On Site")
            } footer: {
                Text("These print in the permit package alongside the room-derived measurements below.")
            }

            Section("Ceiling Heights") {
                if rooms.isEmpty {
                    Text("No captured rooms yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(rooms) { entry in
                    LabeledContent(entry.name,
                                   value: Measure.length(entry.room.ceilingHeightMeters > 0
                                                         ? entry.room.ceilingHeightMeters : 2.4,
                                                         imperial: useImperial))
                }
            }

            Section {
                let windows = rooms.flatMap { entry in
                    entry.room.openings.filter { $0.kind == .window }.map { (entry.name, $0) }
                }
                if windows.isEmpty {
                    Text("No windows captured yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(windows.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        LabeledContent("\(item.0) window",
                                       value: sizeText(w: item.1.widthMeters,
                                                       h: item.1.heightMeters ?? 1.07))
                        if let cw = item.1.clearWidthMeters, let ch = item.1.clearHeightMeters {
                            Text("Clear opening: \(sizeText(w: cw, h: ch))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Clear opening not recorded. Tap the window on the floor plan to add it (required for egress).")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            } header: {
                Text("Windows (Size · Unobstructed Opening)")
            }

            Section("Door Sizes (New Areas)") {
                let doors = rooms.flatMap { entry in
                    entry.room.openings.filter { $0.kind == .door || $0.kind == .closetDoor }
                        .map { (entry.name, $0) }
                }
                if doors.isEmpty {
                    Text("No doors captured yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(doors.enumerated()), id: \.offset) { _, item in
                    LabeledContent("\(item.0) \(item.1.kind == .closetDoor ? "closet door" : "door")",
                                   value: sizeText(w: item.1.widthMeters,
                                                   h: item.1.heightMeters ?? 2.03))
                }
            }

            Section("Notes") {
                TextField("Anything else the examiner should know", text: $measurements.notes, axis: .vertical)
            }
        }
        .navigationTitle("Permit Measurements")
        .keyboardDoneButton()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    try? ScanStore.savePermitMeasurements(measurements, for: project)
                    onSave()
                    dismiss()
                }
            }
        }
    }
}
