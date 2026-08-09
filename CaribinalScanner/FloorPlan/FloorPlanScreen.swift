import SwiftUI
import SceneKit

/// Interactive floor plan with a 2D/3D switch and drawing tools. 2D: pinch
/// to zoom, drag to pan, twist (or Rotate 90°) to rotate, double-tap to
/// reset. Corner-captured rooms support: wall editing (drag corners, split
/// walls, remove corners), interior walls (closets/partitions), doors,
/// windows, kitchen fixtures, tape-measure dimension corrections, and a
/// customisable drawing style — every change regenerates the 3D model.
struct FloorPlanScreen: View {
    enum ViewMode {
        case plan, model
    }

    /// Groups the 2D plan tools into three intents so the toolbar is a short,
    /// task-focused row instead of one long strip. Purely presentational —
    /// each mode just shows a subset of the existing chip buttons.
    enum EditorMode {
        case view, edit, annotate
    }

    private enum DragTarget {
        case corner(Int)
        case outlineWall(Int)     // whole wall slides perpendicular
        case interiorBody(UUID)   // whole partition slides perpendicular
        case interiorStart(UUID)
        case interiorEnd(UUID)
        case fixture(UUID)
        case opening(UUID)
    }

    let project: RenovationProject

    @AppStorage("useImperialUnits") private var useImperial = true

    @State private var plan: FloorPlanModel
    @State private var rooms: [RoomEntry]
    @State private var selectedRoomID: UUID?   // nil = all rooms (view only)
    @State private var canConvertManualPlan: Bool
    @State private var cornerRoom: CornerRoom?
    @State private var viewMode: ViewMode = .plan
    @State private var editorMode: EditorMode = .view
    @State private var paneScene3D: SCNScene?
    @State private var editVersion = 0
    @State private var style = PlanStyle.load()
    @State private var showingStyleSheet = false
    @State private var layers = PlanLayers.load()
    @State private var showingLayersSheet = false
    @AppStorage("planSnapOrtho") private var snapOrtho = false
    @AppStorage("planSnapGridInches") private var snapGridInches = 0
    @State private var cameraPose: (position: SCNVector3, target: SCNVector3)?
    @State private var cameraPoseToken = 0
    @State private var assemblies = AssemblyStore.load()
    @State private var showingAssemblyName = false
    @State private var assemblyName = ""

    // Markers
    @State private var markers: PlanMarkers
    @State private var placingKind: PlanMarkers.Marker.Kind?
    @State private var pendingKind: PlanMarkers.Marker.Kind?
    @State private var pendingPoint: CGPoint?
    @State private var labelText = ""
    @State private var showingLabelPrompt = false
    @State private var editingMarkerID: UUID?
    @State private var showingEditPrompt = false

    // Zoom, pan, rotation
    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var offsetBase: CGSize = .zero
    @State private var rotationRadians: Double = 0
    @State private var rotationBase: Double = 0

    // Wall editing & drawing tools
    @State private var editingWalls = false
    @State private var drawingWall = false
    @State private var wallDraftStart: CornerRoom.Point?
    @State private var wallDraftCurrent: CornerRoom.Point?
    @State private var draftDragActive = false
    @State private var placingFixtureKind: CornerRoom.Fixture.Kind?
    @State private var placingOpening2D: CornerRoom.Opening.Kind?
    @State private var placing3DOpening: CornerRoom.Opening.Kind?
    // frozenBounds (QA-057): the plan bounds at drag start, so the canvas
    // keeps a fixed fit while a corner is dragged outward instead of
    // re-fitting every frame (which makes the corner drift from the finger).
    @State private var activeDrag: (target: DragTarget, originX: Double, originZ: Double, planScale: CGFloat, frozenBounds: CGRect)?
    @State private var dragIsPan = false
    @State private var wallActionIndex: Int?
    @State private var tapPlanPoint: CGPoint = .zero
    @State private var showingWallActions = false
    @State private var pending3DWall: (index: Int, hit: SCNVector3)?
    @State private var showing3DWallActions = false
    @State private var pendingInteriorWall: (id: UUID, hit: SCNVector3)?
    @State private var showingInteriorWallActions = false
    @State private var paintTarget: WallTarget?
    @State private var showingPaintSheet = false
    @State private var cornerActionIndex: Int?
    @State private var showingCornerActions = false
    @State private var editingOpening: CornerRoom.Opening?
    @State private var editingFixture: CornerRoom.Fixture?
    @State private var editingInterior: CornerRoom.InteriorWall?
    @State private var fixtureActionID: UUID?
    @State private var showingFixtureActions = false
    // Free-rotation mode: a two-finger twist rotates this fixture to any
    // degree while the plan itself stays locked in place.
    @State private var freeRotateFixtureID: UUID?
    @State private var freeRotateBase: Double?
    @State private var openingActionID: UUID?
    @State private var showingOpeningActions = false
    @State private var showingCatalog = false
    @State private var eraserActive = false
    @State private var dragReadout: String?
    @State private var openingDragContext: (ux: Double, uz: Double, len: Double, width: Double)?

    // Undo / redo
    private struct EditSnapshot {
        let room: CornerRoom?
        let markers: PlanMarkers
    }
    @State private var undoStack: [EditSnapshot] = []
    @State private var redoStack: [EditSnapshot] = []
    @State private var dragUndoBaseline: CornerRoom?

    // Dimension editing
    @State private var editingWallIndex: Int?
    @State private var editLength: Double = 0
    @State private var showingWallEdit = false
    @State private var showingCeilingEdit = false
    @State private var editCeiling: Double = 2.4
    @State private var editError: String?

    // Tape-measure accuracy check
    @State private var showingCalibration = false
    @State private var calibrationWallIndex = 0
    @State private var calibrationTape: Double = 3.0

    // Overall exterior size editor
    @State private var showingSizeEdit = false
    @State private var editOverallWidth: Double = 0
    @State private var editOverallDepth: Double = 0

    private let hasLiDARPlan: Bool

    init(plan: FloorPlanModel, project: RenovationProject) {
        self.project = project
        _plan = State(initialValue: plan)
        let hasRoomPlanScan = ScanStore.roomDataURL(for: project) != nil
        self.hasLiDARPlan = hasRoomPlanScan
        let entries = hasRoomPlanScan ? [] : ScanStore.loadRooms(for: project)
        _rooms = State(initialValue: entries)
        _canConvertManualPlan = State(initialValue: !hasRoomPlanScan && entries.isEmpty
                                      && ScanStore.loadManualRoom(for: project) != nil)
        // Open on the first room so the drawing tools are immediately
        // available; "All Rooms" (view only) is one tap away in the picker.
        if let first = entries.first {
            _selectedRoomID = State(initialValue: first.id)
            _cornerRoom = State(initialValue: first.room)
            if entries.count > 1, let roomPlan = FloorPlanModel(cornerRoom: first.room) {
                _plan = State(initialValue: roomPlan)
            }
        } else {
            _selectedRoomID = State(initialValue: nil)
            _cornerRoom = State(initialValue: nil)
        }
        _markers = State(initialValue: ScanStore.loadMarkers(for: project) ?? PlanMarkers())
    }

    private var outlineWallCount: Int {
        cornerRoom?.corners.count ?? plan.walls.count
    }

    private var canEditDimensions: Bool {
        guard let cornerRoom else { return false }
        return plan.walls.count == cornerRoom.corners.count + cornerRoom.interiorWalls.count
    }

    var body: some View {
        layerSheets
    }

    private var mainStack: some View {
        VStack(spacing: 0) {
            Picker("Units", selection: $useImperial) {
                Text("Feet & inches").tag(true)
                Text("Metres").tag(false)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            if rooms.count > 1 {
                HStack {
                    Label("Room", systemImage: "square.split.bottomrightquarter")
                        .font(.footnote.weight(.semibold))
                    Picker("Room", selection: $selectedRoomID) {
                        Text("All Rooms (view only)").tag(UUID?.none)
                        ForEach(rooms) { entry in
                            Text(entry.name).tag(Optional(entry.id))
                        }
                    }
                    .pickerStyle(.menu)
                    Spacer()
                    Text(selectedRoomID == nil ? "Viewing all rooms" : "Editing this room")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .onChange(of: selectedRoomID) { _, _ in
                    switchRoom()
                }
            }

            Group {
                if viewMode == .plan {
                    planPane
                } else {
                    modelPane
                }
            }
            .frame(height: 380)
            .padding(.top, 6)

            if viewMode == .plan {
                Picker("Editor mode", selection: $editorMode) {
                    Text("View").tag(EditorMode.view)
                    Text("Edit").tag(EditorMode.edit)
                    Text("Annotate").tag(EditorMode.annotate)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 4)
                .accessibilityLabel("Editor mode")
                .accessibilityHint("Switches the plan tools between viewing, editing walls, and adding fixtures, doors, and markers.")
                // Cancel any armed placement/edit mode so no stale tool leaks
                // across a mode switch (mirrors the picker in the 3D toggle).
                .onChange(of: editorMode) { _, _ in cancelModes() }
            }

            toolStrip

            if let hint = modeHint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }

            detailList
        }
    }

    private var layerChrome: some View {
        mainStack
        .navigationTitle(viewMode == .plan ? "Floor Plan" : "3D Model")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .onChange(of: editVersion) { _, _ in refreshPaneScene() }
        .onChange(of: useImperial) { _, _ in refreshPaneScene() }
        .onChange(of: viewMode) { _, mode in
            if mode == .model, paneScene3D == nil { refreshPaneScene() }
        }
    }

    private var layerAlerts: some View {
        layerChrome
        .alert("Marker Label", isPresented: $showingLabelPrompt) {
            TextField("Label", text: $labelText)
            Button("Add") {
                if let pendingPoint, let pendingKind {
                    appendMarker(kind: pendingKind, label: labelText, at: pendingPoint)
                }
                pendingPoint = nil
                pendingKind = nil
            }
            Button("Cancel", role: .cancel) {
                pendingPoint = nil
                pendingKind = nil
            }
        }
        .alert("Edit Label", isPresented: $showingEditPrompt) {
            TextField("Label", text: $labelText)
            Button("Save") {
                if let editingMarkerID,
                   let index = markers.markers.firstIndex(where: { $0.id == editingMarkerID }) {
                    pushMarkerUndo()
                    markers.markers[index].label = labelText
                    saveMarkers()
                }
                self.editingMarkerID = nil
            }
            Button("Cancel", role: .cancel) { editingMarkerID = nil }
        }
        .alert("Could Not Adjust", isPresented: Binding(
            get: { editError != nil },
            set: { if !$0 { editError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(editError ?? "")
        }
    }

    private var layerDialogs: some View {
        layerAlerts
        .confirmationDialog("Wall \((wallActionIndex ?? 0) + 1)",
                            isPresented: $showingWallActions,
                            titleVisibility: .visible) {
            Button("Add Door") { addOpening(.door) }
            Button("Add Closet Door") { addOpening(.closetDoor) }
            Button("Add Window") { addOpening(.window) }
            Button("Add Cased Opening") { addOpening(.opening) }
            Button("Split Wall Here (Add Corner)") { splitWall() }
            Button("Correct Length…") { correctLengthFromDialog() }
            Button("Paint Colour…") {
                if let index = wallActionIndex {
                    paintTarget = .outline(index)
                    showingPaintSheet = true
                }
            }
            if let index = wallActionIndex, cornerRoom?.outlineWallHex[index] != nil {
                Button("Paint All Walls This Colour") { paintAllWalls(from: index) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Corner \((cornerActionIndex ?? 0) + 1)",
                            isPresented: $showingCornerActions,
                            titleVisibility: .visible) {
            Button("Remove Corner (Merge Walls)", role: .destructive) { removeCorner() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Wall \((pending3DWall?.index ?? 0) + 1)",
                            isPresented: $showing3DWallActions,
                            titleVisibility: .visible) {
            Button("Add Door Here") { place3DOpeningFromDialog(.door) }
            Button("Add Closet Door Here") { place3DOpeningFromDialog(.closetDoor) }
            Button("Add Window Here") { place3DOpeningFromDialog(.window) }
            Button("Add Cased Opening Here") { place3DOpeningFromDialog(.opening) }
            Button("Paint Colour…") {
                if let pending = pending3DWall {
                    paintTarget = .outline(pending.index)
                    showingPaintSheet = true
                }
                pending3DWall = nil
            }
            if let pending = pending3DWall, cornerRoom?.outlineWallHex[pending.index] != nil {
                Button("Paint All Walls This Colour") {
                    paintAllWalls(from: pending.index)
                    pending3DWall = nil
                }
            }
            Button("Cancel", role: .cancel) { pending3DWall = nil }
        }
        .confirmationDialog("Interior Wall",
                            isPresented: $showingInteriorWallActions,
                            titleVisibility: .visible) {
            Button("Add Door Here") { placeInteriorOpeningFromDialog(.door) }
            Button("Add Closet Door Here") { placeInteriorOpeningFromDialog(.closetDoor) }
            Button("Add Window Here") { placeInteriorOpeningFromDialog(.window) }
            Button("Add Cased Opening Here") { placeInteriorOpeningFromDialog(.opening) }
            Button("Paint Colour…") {
                if let pending = pendingInteriorWall {
                    paintTarget = .interior(pending.id)
                    showingPaintSheet = true
                }
                pendingInteriorWall = nil
            }
            Button("Edit Wall…") {
                if let pending = pendingInteriorWall,
                   let wall = cornerRoom?.interiorWalls.first(where: { $0.id == pending.id }) {
                    editingInterior = wall
                }
                pendingInteriorWall = nil
            }
            Button("Cancel", role: .cancel) { pendingInteriorWall = nil }
        }
        .confirmationDialog("Fixture", isPresented: $showingFixtureActions, titleVisibility: .visible) {
            Button("Rotate 90°") { rotateFixture() }
            Button("Rotate Freely (Two-Finger Twist)") {
                freeRotateFixtureID = fixtureActionID
            }
            Button("Edit Size…") {
                if let fixture = cornerRoom?.fixtures.first(where: { $0.id == fixtureActionID }) {
                    editingFixture = fixture
                }
            }
            Button("Delete", role: .destructive) { deleteFixtureFromDialog() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Door / Window", isPresented: $showingOpeningActions, titleVisibility: .visible) {
            if let opening = cornerRoom?.openings.first(where: { $0.id == openingActionID }) {
                if opening.kind == .door {
                    Button("Flip Hinge (Left ↔ Right)") { flipOpeningHinge() }
                }
                if opening.kind == .door || opening.kind == .closetDoor {
                    Button("Flip Swing Direction") { flipOpeningSwing() }
                }
            }
            Button("Edit…") {
                if let opening = cornerRoom?.openings.first(where: { $0.id == openingActionID }) {
                    editingOpening = opening
                }
            }
            Button("Delete", role: .destructive) {
                guard var room = cornerRoom else { return }
                room.openings.removeAll { $0.id == openingActionID }
                persist(room)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var layerSheets: some View {
        layerDialogs
        .sheet(isPresented: $showingCatalog) {
            FixtureCatalogSheet(imperial: useImperial,
                                onPick: { kind in
                                    if viewMode == .plan {
                                        cancelModes()
                                        placingFixtureKind = kind
                                    } else {
                                        addFixtureAtCenter(kind)
                                    }
                                },
                                onPickFloor: { type in
                                    guard var room = cornerRoom else { return }
                                    room.floorType = type
                                    persist(room)
                                    flashConfirmation(type.map { "Flooring: \($0.rawValue)" } ?? "Flooring reset to default")
                                },
                                onPickFloorColor: {
                                    paintTarget = .floor
                                    // Let the catalog sheet finish dismissing
                                    // before presenting the colour sheet.
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                                        showingPaintSheet = true
                                    }
                                },
                                assemblies: assemblies,
                                onPickAssembly: { placeAssembly($0) },
                                onSaveAssembly: (cornerRoom?.fixtures.isEmpty == false) ? {
                                    assemblyName = ""
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                                        showingAssemblyName = true
                                    }
                                } : nil,
                                onDeleteAssembly: { offsets in
                                    var updated = assemblies
                                    updated.remove(atOffsets: offsets)
                                    AssemblyStore.save(updated)
                                    assemblies = updated
                                },
                                onAssembliesChanged: { updated in
                                    assemblies = updated
                                })
        }
        .sheet(isPresented: $showingPaintSheet, onDismiss: commitPaint) { paintSheet }
        .sheet(isPresented: $showingWallEdit) { wallEditSheet }
        .sheet(isPresented: $showingCeilingEdit) { ceilingEditSheet }
        .sheet(isPresented: $showingCalibration) { calibrationSheet }
        .sheet(isPresented: $showingSizeEdit) { sizeEditSheet }
        .sheet(isPresented: $showingLayersSheet) { layersSheet }
        .alert("Name This Assembly", isPresented: $showingAssemblyName) {
            TextField("Name", text: $assemblyName)
            Button("Save") { saveAssembly() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves this room's fixtures as a reusable group for every project.")
        }
        .sheet(isPresented: $showingStyleSheet) { styleSheet }
        .sheet(item: $editingOpening) { opening in
            OpeningEditorSheet(opening: opening,
                               wallCount: outlineWallCount,
                               imperial: useImperial,
                               onSave: { updated in
                                   guard var room = cornerRoom,
                                         let index = room.openings.firstIndex(where: { $0.id == updated.id }) else { return }
                                   room.openings[index] = updated
                                   persist(room)
                               },
                               onDelete: { id in
                                   guard var room = cornerRoom else { return }
                                   room.openings.removeAll { $0.id == id }
                                   persist(room)
                               })
        }
        .sheet(item: $editingFixture) { fixture in
            FixtureEditorSheet(fixture: fixture,
                               imperial: useImperial,
                               ceilingMeters: cornerRoom?.ceilingHeightMeters,
                               onSave: { updated in
                                   guard var room = cornerRoom,
                                         let index = room.fixtures.firstIndex(where: { $0.id == updated.id }) else { return }
                                   room.fixtures[index] = updated
                                   persist(room)
                               },
                               onDelete: { id in
                                   guard var room = cornerRoom else { return }
                                   room.fixtures.removeAll { $0.id == id }
                                   persist(room)
                               })
        }
        .sheet(item: $editingInterior) { wall in
            InteriorWallEditorSheet(wall: wall,
                                    imperial: useImperial,
                                    onSave: { updated in
                                        guard var room = cornerRoom,
                                              let index = room.interiorWalls.firstIndex(where: { $0.id == updated.id }) else { return }
                                        room.interiorWalls[index] = updated
                                        persist(room)
                                    },
                                    onDelete: { id in
                                        deleteInteriorWall(id)
                                    })
        }
        .onChange(of: style) { _, newStyle in
            newStyle.save()
        }
    }

    private var modeHint: String? {
        if cornerRoom == nil, hasLiDARPlan {
            return "LiDAR scan plan — use Convert Scan to Editable Plan on the project screen to unlock measurements editing and drawing tools."
        }
        if cornerRoom == nil, canConvertManualPlan {
            return "Manual plans can't be drawn on — tap Make Editable to turn this one into an editable room."
        }
        if cornerRoom == nil, rooms.count > 1 {
            return "Viewing all rooms — pick a room from the Room menu above to use the drawing tools."
        }
        if eraserActive {
            return "Eraser on — tap a wall, door, window, or fixture to delete it."
        }
        if viewMode == .model {
            if let placing3DOpening {
                return "Tap a wall in the 3D view to place the \(placing3DOpening.rawValue.lowercased())."
            }
            if cornerRoom != nil {
                return "Tap a wall to add a door or window · press & hold a door, window, or fixture to move it"
            }
            return nil
        }
        if eraserActive {
            return "Eraser on — tap a wall, door, window, fixture, or marker to delete it."
        }
        if let placingKind {
            return "Tap the plan to place the \(placingKind.rawValue.lowercased()) marker."
        }
        if let placingOpening2D {
            return "Tap along a wall to place the \(placingOpening2D.rawValue.lowercased())."
        }
        if let placingFixtureKind {
            return "Tap the plan to place \(placingFixtureKind.rawValue.lowercased())."
        }
        if drawingWall {
            return wallDraftStart == nil
                ? "Touch and drag to sketch the wall in one stroke — or tap its start point."
                : "Drag to the end point (dashed preview follows), or tap it."
        }
        if editingWalls {
            return "Drag a corner to move it · drag a wall to push the room wider · tap a wall for doors/paint/split"
        }
        return nil
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 2) {
                Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(undoStack.isEmpty)
                    .accessibilityLabel("Undo")
                Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(redoStack.isEmpty)
                    .accessibilityLabel("Redo")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                viewMode = viewMode == .plan ? .model : .plan
                cancelModes()
            } label: {
                Image(systemName: viewMode == .plan ? "cube" : "map")
            }
            .accessibilityLabel(viewMode == .plan ? "Show 3D model" : "Show 2D plan")
        }
    }

    private func cancelModes() {
        placingKind = nil
        placingFixtureKind = nil
        placingOpening2D = nil
        placing3DOpening = nil
        drawingWall = false
        wallDraftStart = nil
        wallDraftCurrent = nil
        draftDragActive = false
        editingWalls = false
        eraserActive = false
        // Clear free-rotate state so a stale fixture ID can't keep pinch
        // zoom and view rotation disabled after a room switch (QA-055).
        freeRotateFixtureID = nil
        freeRotateBase = nil
    }

    // MARK: - Tool strip

    private func chip(_ title: String, _ systemImage: String, active: Bool = false) -> some View {
        Label(title, systemImage: systemImage)
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(active ? Color.accentColor.opacity(0.18) : Color(uiColor: .tertiarySystemFill),
                        in: Capsule())
            // The visible text already names each tool for VoiceOver; the
            // selected trait announces which mode is currently armed.
            .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var toolStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if placingKind != nil || placingFixtureKind != nil || drawingWall
                    || placing3DOpening != nil || placingOpening2D != nil {
                    Button {
                        cancelModes()
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(Color.red.opacity(0.15), in: Capsule())
                            .foregroundStyle(.red)
                    }
                }
                if viewMode == .plan {
                    if cornerRoom == nil, canConvertManualPlan {
                        Button {
                            convertManualPlanInEditor()
                        } label: {
                            chip("Make Editable", "wand.and.stars", active: true)
                        }
                    }
                    // The same chips as before, grouped by intent. Each
                    // button's action is unchanged — only its visibility is
                    // gated on the current editor mode.
                    switch editorMode {
                    case .view:
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { resetView() }
                        } label: {
                            chip("Fit", "arrow.down.right.and.arrow.up.left")
                        }
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) {
                                rotationRadians += .pi / 2
                                rotationBase = rotationRadians
                            }
                        } label: {
                            chip("Rotate", "arrow.clockwise")
                        }
                        Button {
                            showingStyleSheet = true
                        } label: {
                            chip("Style", "paintpalette")
                        }
                        Button {
                            showingLayersSheet = true
                        } label: {
                            chip("Layers", "square.3.layers.3d",
                                 active: layers != PlanLayers())
                        }
                    case .edit:
                        if cornerRoom != nil {
                            Button {
                                let wasEditing = editingWalls
                                cancelModes()
                                editingWalls = !wasEditing
                            } label: {
                                chip(editingWalls ? "Done" : "Edit",
                                     "arrow.up.and.down.and.arrow.left.and.right",
                                     active: editingWalls)
                            }
                            if editingWalls {
                                Button {
                                    drawingWall.toggle()
                                    eraserActive = false
                                    wallDraftStart = nil
                                } label: {
                                    chip("Draw Wall", "scribble", active: drawingWall)
                                }
                                Button {
                                    eraserActive.toggle()
                                    drawingWall = false
                                    wallDraftStart = nil
                                } label: {
                                    chip("Eraser", "eraser", active: eraserActive)
                                }
                                Menu {
                                    Toggle("Ortho (90° only)", isOn: $snapOrtho)
                                    Picker("Grid snap", selection: $snapGridInches) {
                                        Text("Grid off").tag(0)
                                        Text("Snap to 1\"").tag(1)
                                        Text("Snap to 6\"").tag(6)
                                        Text("Snap to 1'").tag(12)
                                    }
                                } label: {
                                    chip("Snap", "dot.squareshape.split.2x2",
                                         active: snapOrtho || snapGridInches > 0)
                                }
                            }
                        }
                    case .annotate:
                        if cornerRoom != nil {
                            Button {
                                showingCatalog = true
                            } label: {
                                chip("Catalog", "plus.square.on.square")
                            }
                            Menu {
                                ForEach(CornerRoom.Opening.Kind.allCases) { kind in
                                    Button(kind.rawValue) {
                                        cancelModes()
                                        placingOpening2D = kind
                                    }
                                }
                            } label: {
                                chip("Door / Window", "door.left.hand.closed",
                                     active: placingOpening2D != nil)
                            }
                        }
                        Menu {
                            ForEach(PlanMarkers.Marker.Kind.allCases) { kind in
                                Button(kind.rawValue) {
                                    cancelModes()
                                    placingKind = kind
                                }
                            }
                        } label: {
                            chip("Marker", "mappin.circle")
                        }
                    }
                } else if cornerRoom != nil {
                    Button {
                        showingCatalog = true
                    } label: {
                        chip("Catalog", "plus.square.on.square")
                    }
                    Button {
                        let wasOn = eraserActive
                        cancelModes()
                        eraserActive = !wasOn
                    } label: {
                        chip("Eraser", "eraser", active: eraserActive)
                    }
                    Button {
                        cancelModes()
                        placing3DOpening = .door
                    } label: {
                        chip("Door", "door.left.hand.closed", active: placing3DOpening == .door)
                    }
                    Button {
                        cancelModes()
                        placing3DOpening = .window
                    } label: {
                        chip("Window", "window.vertical.closed", active: placing3DOpening == .window)
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 6)
    }

    private func rotateFixture() {
        guard var room = cornerRoom,
              let index = room.fixtures.firstIndex(where: { $0.id == fixtureActionID }) else { return }
        room.fixtures[index].rotationDegrees = (room.fixtures[index].rotationDegrees + 90)
            .truncatingRemainder(dividingBy: 360)
        persist(room)
    }

    private func deleteFixtureFromDialog() {
        guard var room = cornerRoom else { return }
        room.fixtures.removeAll { $0.id == fixtureActionID }
        persist(room)
    }

    private func addFixtureAtCenter(_ kind: CornerRoom.Fixture.Kind) {
        guard var room = cornerRoom else { return }
        let count = Double(max(room.corners.count, 1))
        let cx = room.corners.map(\.x).reduce(0, +) / count
        let cz = room.corners.map(\.z).reduce(0, +) / count
        let defaults = kind.defaultSize
        room.fixtures.append(CornerRoom.Fixture(kind: kind, x: cx, z: cz,
                                                widthMeters: defaults.width,
                                                depthMeters: defaults.depth))
        persist(room)
    }

    private func moveFixture3D(id: UUID, sceneX: Double, sceneZ: Double) {
        guard var room = cornerRoom,
              let index = room.fixtures.firstIndex(where: { $0.id == id }) else { return }
        let minX = room.corners.map(\.x).min() ?? 0
        let minZ = room.corners.map(\.z).min() ?? 0
        room.fixtures[index].x = sceneX + minX
        room.fixtures[index].z = sceneZ + minZ
        persist(room)
    }

    /// Doors and windows slide along their wall in 3D too — live distance
    /// readout from each corner, geometry committed on release.
    private func updateOpeningSlide(id: UUID, world: SCNVector3, commit: Bool) {
        guard var room = cornerRoom,
              let index = room.openings.firstIndex(where: { $0.id == id }) else { return }
        let opening = room.openings[index]
        guard let host = room.hostWall(for: opening), host.length > 0.1 else { return }
        let minX = room.corners.map(\.x).min() ?? 0
        let minZ = room.corners.map(\.z).min() ?? 0
        let length = host.length
        let hitOffset = (Double(world.x) - (host.start.x - minX)) * host.ux
            + (Double(world.z) - (host.start.z - minZ)) * host.uz
        let newOffset = min(max(hitOffset - opening.widthMeters / 2, 0),
                            max(length - opening.widthMeters, 0))
        let left = Measure.length(newOffset, imperial: useImperial)
        let right = Measure.length(max(length - newOffset - opening.widthMeters, 0),
                                   imperial: useImperial)
        dragReadout = "\(left) ◀ \(opening.kind.rawValue) ▶ \(right)"
        if commit {
            room.openings[index].offsetMeters = newOffset
            persist(room)
            dragReadout = nil
        }
    }

    private func handle3DWallTap(wallIndex: Int, hit: SCNVector3) {
        if eraserActive {
            eraseOutlineWall(wallIndex)
            return
        }
        guard let room = cornerRoom, wallIndex >= 0, wallIndex < room.corners.count else { return }
        if let kind = placing3DOpening {
            insert3DOpening(kind: kind, wallIndex: wallIndex, hit: hit)
            placing3DOpening = nil
        } else {
            // No tool armed: ask, like the 2D wall dialog does.
            pending3DWall = (wallIndex, hit)
            showing3DWallActions = true
        }
    }

    private func place3DOpeningFromDialog(_ kind: CornerRoom.Opening.Kind) {
        guard let pending = pending3DWall else { return }
        insert3DOpening(kind: kind, wallIndex: pending.index, hit: pending.hit)
        pending3DWall = nil
    }

    private func insert3DOpening(kind: CornerRoom.Opening.Kind, wallIndex: Int, hit: SCNVector3) {
        guard var room = cornerRoom, wallIndex >= 0, wallIndex < room.corners.count else { return }
        let minX = room.corners.map(\.x).min() ?? 0
        let minZ = room.corners.map(\.z).min() ?? 0
        let count = room.corners.count
        let a = room.corners[wallIndex]
        let b = room.corners[(wallIndex + 1) % count]
        let dx = b.x - a.x
        let dz = b.z - a.z
        let length = (dx * dx + dz * dz).squareRoot()
        guard length > 0.1 else { return }
        let width = min(kind.defaultWidthMeters, length)
        let hitOffset = (Double(hit.x) - (a.x - minX)) * dx / length
            + (Double(hit.z) - (a.z - minZ)) * dz / length
        let offsetOnWall = min(max(hitOffset - width / 2, 0), max(length - width, 0))
        room.openings.append(CornerRoom.Opening(kind: kind, wallIndex: wallIndex,
                                                offsetMeters: offsetOnWall, widthMeters: width))
        persist(room)
        flashConfirmation("\(kind.rawValue) added — Wall \(wallIndex + 1)")
    }

    // MARK: - Panes

    /// Auto room labels: the room's name and area at its centre — the
    /// selected room alone while editing, every room in the merged view.
    private var canvasRoomLabels: [(name: String, area: String, center: CGPoint)] {
        let entries: [RoomEntry]
        if let id = selectedRoomID, let entry = rooms.first(where: { $0.id == id }) {
            entries = [entry]
        } else {
            entries = rooms
        }
        // A lone room doesn't need its name stamped across the drawing —
        // the name lives in the rooms list. Labels exist to tell rooms
        // apart, so they appear only on merged multi-room plans.
        guard entries.count > 1 else { return [] }
        return entries.compactMap { entry in
            guard entry.room.corners.count >= 3 else { return nil }
            let count = Double(entry.room.corners.count)
            let centerX = entry.room.corners.map(\.x).reduce(0, +) / count
            let centerZ = entry.room.corners.map(\.z).reduce(0, +) / count
            return (entry.name,
                    Measure.area(entry.room.floorAreaSquareMeters, imperial: useImperial),
                    CGPoint(x: centerX, y: centerZ))
        }
    }

    private var draftSegmentPoints: (start: CGPoint, end: CGPoint)? {
        guard let start = wallDraftStart, let end = wallDraftCurrent else { return nil }
        return (CGPoint(x: start.x, y: start.z), CGPoint(x: end.x, y: end.z))
    }

    private var rotateBanner: String? {
        guard let id = freeRotateFixtureID,
              let fixture = cornerRoom?.fixtures.first(where: { $0.id == id }) else { return nil }
        return "\(fixture.kind.rawValue) \(Int(fixture.rotationDegrees.rounded()))° — twist with two fingers, tap to finish"
    }

    /// Live wall lengths pinned to the point being dragged — both adjacent
    /// walls for a corner, the wall itself for an interior endpoint or a
    /// sketch in progress.
    private var dragTipLabel: (anchor: CGPoint, lines: [String])? {
        func distance(_ a: CornerRoom.Point, _ b: CornerRoom.Point) -> Double {
            ((b.x - a.x) * (b.x - a.x) + (b.z - a.z) * (b.z - a.z)).squareRoot()
        }
        if draftDragActive, let start = wallDraftStart, let end = wallDraftCurrent {
            return (CGPoint(x: end.x, y: end.z),
                    [Measure.length(distance(start, end), imperial: useImperial)])
        }
        guard let drag = activeDrag, let room = cornerRoom else { return nil }
        switch drag.target {
        case .corner(let index):
            let count = room.corners.count
            guard count >= 2, index < count else { return nil }
            let corner = room.corners[index]
            let previous = room.corners[(index + count - 1) % count]
            let next = room.corners[(index + 1) % count]
            return (CGPoint(x: corner.x, y: corner.z),
                    [Measure.length(distance(previous, corner), imperial: useImperial),
                     Measure.length(distance(corner, next), imperial: useImperial)])
        case .outlineWall(let index):
            let count = room.corners.count
            guard count >= 3, index < count else { return nil }
            let a = room.corners[index]
            let b = room.corners[(index + 1) % count]
            let previous = room.corners[(index + count - 1) % count]
            let next = room.corners[(index + 2) % count]
            return (CGPoint(x: (a.x + b.x) / 2, y: (a.z + b.z) / 2),
                    [Measure.length(distance(previous, a), imperial: useImperial),
                     Measure.length(distance(b, next), imperial: useImperial)])
        case .interiorStart(let id):
            guard let wall = room.interiorWalls.first(where: { $0.id == id }) else { return nil }
            return (CGPoint(x: wall.start.x, y: wall.start.z),
                    [Measure.length(wall.lengthMeters, imperial: useImperial)])
        case .interiorEnd(let id):
            guard let wall = room.interiorWalls.first(where: { $0.id == id }) else { return nil }
            return (CGPoint(x: wall.end.x, y: wall.end.z),
                    [Measure.length(wall.lengthMeters, imperial: useImperial)])
        case .interiorBody, .fixture, .opening:
            return nil   // these show their own top readout instead
        }
    }

    /// Room width remaining on each side of a partition — the number that
    /// matters when sliding it to widen a room. Casts a ray from the wall's
    /// midpoint along both normals to the nearest wall.
    private func partitionWidthReadout(for wall: CornerRoom.InteriorWall,
                                       in room: CornerRoom) -> String? {
        let midX = (wall.start.x + wall.end.x) / 2
        let midZ = (wall.start.z + wall.end.z) / 2
        let dx = wall.end.x - wall.start.x
        let dz = wall.end.z - wall.start.z
        let length = (dx * dx + dz * dz).squareRoot()
        guard length > 0.01 else { return nil }
        let nx = -dz / length
        let nz = dx / length

        func nearestHit(_ sx: Double, _ sz: Double) -> Double? {
            var best: Double?
            func intersect(_ a: CornerRoom.Point, _ b: CornerRoom.Point) {
                let ex = b.x - a.x
                let ez = b.z - a.z
                let denom = sx * ez - sz * ex
                guard abs(denom) > 0.000001 else { return }
                let qx = a.x - midX
                let qz = a.z - midZ
                let t = (qx * ez - qz * ex) / denom
                let u = (qx * sz - qz * sx) / denom
                if t > 0.01, u >= 0, u <= 1 {
                    best = min(best ?? .infinity, t)
                }
            }
            let count = room.corners.count
            for index in 0..<count {
                intersect(room.corners[index], room.corners[(index + 1) % count])
            }
            for other in room.interiorWalls where other.id != wall.id {
                intersect(other.start, other.end)
            }
            return best
        }

        let sideA = nearestHit(nx, nz)
        let sideB = nearestHit(-nx, -nz)
        guard sideA != nil || sideB != nil else { return nil }
        let textA = sideA.map { Measure.length($0, imperial: useImperial) } ?? "—"
        let textB = sideB.map { Measure.length($0, imperial: useImperial) } ?? "—"
        return "\(textA) ◀ partition ▶ \(textB)"
    }

    private var editHandlePoints: [CGPoint] {
        guard editingWalls || drawingWall, let cornerRoom else {
            if let wallDraftStart { return [CGPoint(x: wallDraftStart.x, y: wallDraftStart.z)] }
            return []
        }
        var handles = cornerRoom.corners.map { CGPoint(x: $0.x, y: $0.z) }
        for wall in cornerRoom.interiorWalls {
            handles.append(CGPoint(x: wall.start.x, y: wall.start.z))
            handles.append(CGPoint(x: wall.end.x, y: wall.end.z))
        }
        if let wallDraftStart {
            handles.append(CGPoint(x: wallDraftStart.x, y: wallDraftStart.z))
        }
        return handles
    }

    /// Spoken summary for the plan canvas. The Canvas drawing and its
    /// pinch/drag gestures aren't reachable by VoiceOver (a known limit), so
    /// this element names the plan and points to the reachable controls.
    private var planAccessibilityLabel: String {
        var parts = ["Floor plan"]
        if rooms.count > 1 {
            parts.append("\(rooms.count) rooms")
        }
        if let cornerRoom, !cornerRoom.openings.isEmpty {
            parts.append("\(cornerRoom.openings.count) doors and windows")
        }
        return parts.joined(separator: ", ")
    }

    private var planPane: some View {
        GeometryReader { geo in
            ZStack {
                style.backgroundColor
                FloorPlanCanvas(plan: plan,
                                useImperial: useImperial,
                                markers: markers.markers,
                                editHandles: editHandlePoints,
                                draftSegment: draftSegmentPoints,
                                dragTipLabel: dragTipLabel,
                                roomLabels: canvasRoomLabels,
                                style: style,
                                layers: layers,
                                zoom: zoom,
                                rotationRadians: rotationRadians,
                                panOffset: offset,
                                boundsOverride: activeDrag?.frozenBounds)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(planAccessibilityLabel)
                    .accessibilityHint("The plan drawing isn't readable by VoiceOver. Use the tool buttons and the lists below the plan to edit and review it.")
            }
            .contentShape(Rectangle())
            .clipped()
            .onTapGesture(count: 2) {
                guard !editingWalls, !drawingWall, !eraserActive,
                      placingFixtureKind == nil, placingKind == nil,
                      placingOpening2D == nil, freeRotateFixtureID == nil else { return }
                withAnimation(.easeOut(duration: 0.2)) { resetView() }
            }
            .onTapGesture { location in
                handleTap(location, size: geo.size)
            }
            .gesture(paneGesture(size: geo.size))
            .overlay(alignment: .top) {
                if let banner = rotateBanner ?? dragReadout {
                    Text(banner)
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 8)
                }
            }
        }
    }

    /// Scene matching the editing scope: the selected room alone while
    /// editing, every room merged in "All Rooms", or the LiDAR USDZ.
    /// Cached in `paneScene3D` — rebuilt only on real edits, never on UI
    /// state changes, so the camera stays where the user put it.
    private func buildPaneScene() -> SCNScene? {
        if let cornerRoom {
            return Model3DBuilder.makeScene(room: cornerRoom, useImperial: useImperial, withLabels: true)
        }
        if !rooms.isEmpty {
            return Model3DBuilder.makeScene(rooms: rooms.map(\.room), useImperial: useImperial, withLabels: true)
        }
        return Model3DBuilder.viewerScene(for: project, useImperial: useImperial)
    }

    private func refreshPaneScene() {
        guard viewMode == .model else {
            paneScene3D = nil
            return
        }
        paneScene3D = buildPaneScene()
    }

    private var modelPane: some View {
        Group {
            if let scene = paneScene3D {
                Interactive3DView(scene: scene,
                                  // All-Rooms scope is view-only: passing nil
                                  // stops Interactive3DView from beginning a
                                  // fixture drag that would be silently
                                  // discarded (QA-028).
                                  onFixtureMoved: cornerRoom == nil ? nil : { id, x, z in
                                      moveFixture3D(id: id, sceneX: x, sceneZ: z)
                                  },
                                  onFixtureTapped: { id in
                                      if eraserActive {
                                          if var room = cornerRoom {
                                              room.fixtures.removeAll { $0.id == id }
                                              persist(room)
                                          }
                                      } else if cornerRoom != nil {
                                          fixtureActionID = id
                                          showingFixtureActions = true
                                      }
                                  },
                                  onWallTapped: { index, hit in
                                      handle3DWallTap(wallIndex: index, hit: hit)
                                  },
                                  onOpeningTapped: { id in
                                      if eraserActive {
                                          if var room = cornerRoom {
                                              room.openings.removeAll { $0.id == id }
                                              persist(room)
                                          }
                                      } else if cornerRoom != nil {
                                          openingActionID = id
                                          showingOpeningActions = true
                                      }
                                  },
                                  onInteriorTapped: { id, world in
                                      if eraserActive {
                                          deleteInteriorWall(id)
                                      } else if cornerRoom != nil {
                                          pendingInteriorWall = (id, world)
                                          showingInteriorWallActions = true
                                      }
                                  },
                                  onOpeningDragBegan: { id in
                                      guard let opening = cornerRoom?.openings.first(where: { $0.id == id }) else { return nil }
                                      return (opening.kind == .window ? (opening.sillMeters ?? 0.91) : nil, true)
                                  },
                                  onOpeningDragChanged: { _, sill in
                                      dragReadout = "Sill height: \(Measure.length(sill, imperial: useImperial))"
                                  },
                                  onOpeningDragEnded: { id, sill in
                                      dragReadout = nil
                                      guard var room = cornerRoom,
                                            let index = room.openings.firstIndex(where: { $0.id == id }) else { return }
                                      let ceiling = room.ceilingHeightMeters > 0.5 ? room.ceilingHeightMeters : 2.4
                                      room.openings[index].sillMeters = min(max(sill, 0.1), max(ceiling - 1.2, 0.2))
                                      persist(room)
                                  },
                                  onOpeningSlideChanged: { id, world in
                                      updateOpeningSlide(id: id, world: world, commit: false)
                                  },
                                  onOpeningSlideEnded: { id, world in
                                      updateOpeningSlide(id: id, world: world, commit: true)
                                  },
                                  cameraPose: cameraPose,
                                  cameraPoseToken: cameraPoseToken)
                    .overlay(alignment: .topTrailing) {
                        // Compass poses are computed from corner-room
                        // geometry — hide them on a USDZ-only (LiDAR) scene
                        // where they would silently do nothing.
                        if cornerRoom != nil || !rooms.isEmpty {
                            VStack(spacing: 6) {
                                compassButton("Top", .top)
                                compassButton("¾", .threeQuarter)
                                compassButton("Front", .front)
                            }
                            .padding(8)
                        }
                    }
                    .overlay(alignment: .top) {
                        if let dragReadout {
                            Text(dragReadout)
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.thinMaterial, in: Capsule())
                                .padding(.top, 8)
                        }
                    }
            } else {
                ContentUnavailableView(
                    "No 3D Model",
                    systemImage: "cube",
                    description: Text("Capture the room to generate a model.")
                )
            }
        }
    }

    // MARK: - Detail list

    private var detailList: some View {
        List {
            if let cornerRoom, !cornerRoom.openings.isEmpty {
                Section("Doors & Windows") {
                    ForEach(cornerRoom.openings) { opening in
                        Button {
                            editingOpening = opening
                        } label: {
                            Text("\(opening.kind.rawValue) — \(opening.interiorWallID == nil ? "Wall \(opening.wallIndex + 1)" : "Interior wall"), \(Measure.length(opening.offsetMeters, imperial: useImperial)) from corner, \(Measure.length(opening.widthMeters, imperial: useImperial)) wide")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                        }
                    }
                    .onDelete { offsets in
                        guard var room = self.cornerRoom else { return }
                        room.openings.remove(atOffsets: offsets)
                        persist(room)
                    }
                }
            }

            if let cornerRoom, !cornerRoom.interiorWalls.isEmpty {
                Section("Interior Walls") {
                    ForEach(cornerRoom.interiorWalls) { wall in
                        Button {
                            editingInterior = wall
                        } label: {
                            Text("Interior wall — \(Measure.length(wall.lengthMeters, imperial: useImperial))")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                        }
                    }
                    .onDelete { offsets in
                        guard var room = self.cornerRoom else { return }
                        room.interiorWalls.remove(atOffsets: offsets)
                        persist(room)
                    }
                }
            }

            if let cornerRoom, !cornerRoom.fixtures.isEmpty {
                Section("Fixtures") {
                    ForEach(cornerRoom.fixtures) { fixture in
                        Button {
                            editingFixture = fixture
                        } label: {
                            Text("\(fixture.kind.rawValue) — \(Measure.length(fixture.widthMeters, imperial: useImperial)) × \(Measure.length(fixture.depthMeters, imperial: useImperial))")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                        }
                    }
                    .onDelete { offsets in
                        guard var room = self.cornerRoom else { return }
                        room.fixtures.remove(atOffsets: offsets)
                        persist(room)
                    }
                }
            }

            if !markers.markers.isEmpty {
                Section("Markers") {
                    ForEach(markers.markers) { marker in
                        Button {
                            editingMarkerID = marker.id
                            labelText = marker.label
                            showingEditPrompt = true
                        } label: {
                            HStack(spacing: 6) {
                                Text(marker.kind.rawValue)
                                    .foregroundStyle(.primary)
                                if !marker.label.isEmpty {
                                    Text("— \(marker.label)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(.subheadline)
                        }
                    }
                    .onDelete { offsets in
                        pushMarkerUndo()
                        markers.markers.remove(atOffsets: offsets)
                        saveMarkers()
                    }
                }
            }

            Section {
                ForEach(plan.summaryItems(useImperial: useImperial), id: \.label) { item in
                    LabeledContent(item.label, value: item.value)
                }
                if cornerRoom != nil {
                    Button {
                        editCeiling = cornerRoom?.ceilingHeightMeters ?? 2.4
                        showingCeilingEdit = true
                    } label: {
                        Label("Adjust Ceiling Height", systemImage: "arrow.up.and.down")
                    }
                    Button {
                        if let bounds = cornerRoom?.planBounds {
                            editOverallWidth = bounds.maxX - bounds.minX
                            editOverallDepth = bounds.maxZ - bounds.minZ
                        }
                        showingSizeEdit = true
                    } label: {
                        Label("Edit Overall Size", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    Button {
                        calibrationWallIndex = 0
                        calibrationTape = outlineWallLength(0)
                        showingCalibration = true
                    } label: {
                        Label("Check Accuracy (Tape Measure)", systemImage: "ruler")
                    }
                    if let verified = cornerRoom?.verifiedAccuracyPercent {
                        LabeledContent("Tape-verified",
                                       value: String(format: "±%.1f%% correction applied", verified))
                    }
                }
            } header: {
                Text("Summary")
            } footer: {
                Text("Pinch to zoom, drag to pan, twist to rotate, double-tap to reset. Use the tool chips above the list for the catalog, markers, wall editing, and plan style.")
            }

        }
    }

    // MARK: - Edit sheets

    private var wallEditSheet: some View {
        NavigationStack {
            Form {
                Section {
                    DimensionRow(label: "Correct length", meters: $editLength, imperial: useImperial)
                } footer: {
                    Text("Wall \((editingWallIndex ?? 0) + 1) — opposite walls adjust proportionally so the room stays closed.")
                }
            }
            .navigationTitle("Correct Dimension")
            .keyboardDoneButton()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingWallEdit = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { applyWallEdit() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var ceilingEditSheet: some View {
        NavigationStack {
            Form {
                Section {
                    DimensionRow(label: "Ceiling height", meters: $editCeiling, imperial: useImperial)
                } footer: {
                    Text("Updates the 3D model, summary, and suite assessment.")
                }
            }
            .navigationTitle("Ceiling Height")
            .keyboardDoneButton()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingCeilingEdit = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { applyCeilingEdit() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var styleSheet: some View {
        NavigationStack {
            Form {
                Section("Presets") {
                    Button("Paper (Default)") {
                        applyStylePreset(PlanStyle())
                    }
                    Button("CAD Dark") {
                        var preset = PlanStyle()
                        preset.backgroundHex = "#1B2128"
                        preset.wallHex = "#E8ECF2"
                        preset.doorHex = "#4FC3F7"
                        preset.windowHex = "#35C8D8"
                        preset.wallWidth = 4
                        applyStylePreset(preset)
                    }
                    Button("Blueprint") {
                        var preset = PlanStyle()
                        preset.backgroundHex = "#16406E"
                        preset.wallHex = "#F4F8FC"
                        preset.doorHex = "#FFD54F"
                        preset.windowHex = "#8BE0F0"
                        applyStylePreset(preset)
                    }
                }
                Section("Walls") {
                    Toggle("Drafting walls (double line)", isOn: $style.doubleLineWalls)
                    HStack {
                        Text("Line thickness")
                        Slider(value: $style.wallWidth, in: 2...10, step: 1)
                        Text("\(Int(style.wallWidth))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    ColorPicker("Wall colour", selection: colorBinding(\.wallHex, fallback: .primary), supportsOpacity: false)
                }
                Section("Openings") {
                    ColorPicker("Door colour", selection: colorBinding(\.doorHex, fallback: .orange), supportsOpacity: false)
                    ColorPicker("Window colour", selection: colorBinding(\.windowHex, fallback: .teal), supportsOpacity: false)
                }
                Section("Background") {
                    ColorPicker("Plan background", selection: colorBinding(\.backgroundHex, fallback: style.backgroundColor), supportsOpacity: false)
                }
                Section {
                    Button("Reset to Defaults") {
                        style = PlanStyle()
                    }
                } footer: {
                    Text("The style applies on screen and in PDF and image exports.")
                }
            }
            .navigationTitle("Plan Style")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingStyleSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func applyStylePreset(_ preset: PlanStyle) {
        style = preset
        style.save()
    }

    private func colorBinding(_ keyPath: WritableKeyPath<PlanStyle, String>, fallback: Color) -> Binding<Color> {
        Binding(
            get: { Color(hexString: style[keyPath: keyPath]) ?? fallback },
            set: { style[keyPath: keyPath] = $0.hexString() }
        )
    }

    // MARK: - Gestures & mapping

    private func paneGesture(size: CGSize) -> some Gesture {
        SimultaneousGesture(
            SimultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        // The plan locks in place while a fixture is being
                        // rotated so the twist can't fight the canvas.
                        guard activeDrag == nil, freeRotateFixtureID == nil else { return }
                        zoom = min(max(zoomBase * value, 0.5), 8)
                    }
                    .onEnded { _ in
                        zoomBase = zoom
                    },
                RotateGesture()
                    .onChanged { value in
                        guard activeDrag == nil else { return }
                        if let id = freeRotateFixtureID {
                            guard var updated = cornerRoom,
                                  let index = updated.fixtures.firstIndex(where: { $0.id == id })
                            else { return }
                            if freeRotateBase == nil {
                                freeRotateBase = updated.fixtures[index].rotationDegrees
                                // Snapshot the pre-twist room once so Undo
                                // restores the original angle (QA-020).
                                dragUndoBaseline = cornerRoom
                            }
                            var degrees = (freeRotateBase ?? 0) + value.rotation.degrees
                            degrees = degrees.truncatingRemainder(dividingBy: 360)
                            if degrees < 0 { degrees += 360 }
                            updated.fixtures[index].rotationDegrees = degrees
                            cornerRoom = updated
                            if let newPlan = FloorPlanModel(cornerRoom: updated) {
                                plan = newPlan
                            }
                            return
                        }
                        // View rotation is disabled while editing so it
                        // can't fight fixture drags.
                        guard !editingWalls else { return }
                        rotationRadians = rotationBase + value.rotation.radians
                    }
                    .onEnded { _ in
                        if freeRotateFixtureID != nil {
                            freeRotateBase = nil
                            if let room = cornerRoom { persist(room) }
                            return
                        }
                        rotationBase = rotationRadians
                    }
            ),
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    handleDragChanged(value, size: size)
                }
                .onEnded { _ in
                    handleDragEnded()
                }
        )
    }

    private func resetView() {
        zoom = 1
        zoomBase = 1
        offset = .zero
        offsetBase = .zero
        rotationRadians = 0
        rotationBase = 0
    }

    private func contentPoint(fromView location: CGPoint, size: CGSize) -> CGPoint {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let vx = location.x - offset.width - center.x
        let vy = location.y - offset.height - center.y
        let cosR = cos(-rotationRadians)
        let sinR = sin(-rotationRadians)
        return CGPoint(x: (vx * cosR - vy * sinR) / zoom + center.x,
                       y: (vx * sinR + vy * cosR) / zoom + center.y)
    }

    private func viewPoint(fromContent point: CGPoint, size: CGSize) -> CGPoint {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let cosF = cos(rotationRadians)
        let sinF = sin(rotationRadians)
        return CGPoint(x: center.x + (dx * cosF - dy * sinF) * zoom + offset.width,
                       y: center.y + (dx * sinF + dy * cosF) * zoom + offset.height)
    }

    private func planDelta(_ translation: CGSize, planScale: CGFloat) -> CGPoint {
        let cosR = cos(-rotationRadians)
        let sinR = sin(-rotationRadians)
        let cx = (translation.width * cosR - translation.height * sinR) / zoom
        let cy = (translation.width * sinR + translation.height * cosR) / zoom
        guard planScale > 0 else { return .zero }
        return CGPoint(x: cx / planScale, y: cy / planScale)
    }

    private func planPoint(fromView location: CGPoint, size: CGSize) -> CGPoint? {
        guard let transform = PlanTransform(bounds: plan.bounds, size: size) else { return nil }
        return transform.toPlan(contentPoint(fromView: location, size: size))
    }

    // MARK: - Tap & drag handling

    private func handleTap(_ location: CGPoint, size: CGSize) {
        // A tap ends free-rotation mode with the fixture at its final angle.
        if freeRotateFixtureID != nil {
            freeRotateFixtureID = nil
            freeRotateBase = nil
            flashConfirmation("Rotation locked in")
            return
        }
        if eraserActive {
            guard var room = cornerRoom else { return }
            if let point = planPoint(fromView: location, size: size),
               let fixture = room.fixtures.first(where: { fixtureContains($0, point: point) }) {
                room.fixtures.removeAll { $0.id == fixture.id }
                persist(room)
                return
            }
            if let opening = nearestOpeningSegment(to: location, size: size, in: room) {
                room.openings.removeAll { $0.id == opening.id }
                persist(room)
                return
            }
            if let interior = nearestInteriorWall(to: location, size: size, in: room) {
                deleteInteriorWall(interior.id)
                return
            }
            if let hit = nearestOutlineWall(to: location, size: size, in: room) {
                eraseOutlineWall(hit.index)
                return
            }
            if let transform = PlanTransform(bounds: plan.bounds, size: size) {
                for marker in markers.markers {
                    let view = viewPoint(fromContent: transform.toView(CGPoint(x: marker.x, y: marker.y)), size: size)
                    if hypot(view.x - location.x, view.y - location.y) < 22 {
                        pushMarkerUndo()
                        markers.markers.removeAll { $0.id == marker.id }
                        saveMarkers()
                        return
                    }
                }
            }
            return
        }
        if drawingWall {
            handleWallDraftTap(location, size: size)
            return
        }
        if let kind = placingOpening2D {
            // Placement mode: snap to the nearest wall — outline or
            // interior — no matter where the tap lands. A miss must never
            // fail silently.
            guard let room = cornerRoom,
                  let hit = nearestWallTarget(to: location, size: size, in: room) else { return }
            switch hit.target {
            case .outline(let index):
                insertOpening(kind: kind, wallIndex: index, planPoint: hit.planPoint)
            case .interior(let id):
                insertInteriorOpening(kind: kind, interiorWallID: id, planPoint: hit.planPoint)
            case .floor:
                break
            }
            placingOpening2D = nil
            return
        }
        if let kind = placingFixtureKind {
            guard var room = cornerRoom, let point = planPoint(fromView: location, size: size) else { return }
            let defaults = kind.defaultSize
            let fixture = CornerRoom.Fixture(kind: kind,
                                             x: Double(point.x), z: Double(point.y),
                                             widthMeters: defaults.width,
                                             depthMeters: defaults.depth)
            room.fixtures.append(fixture)
            persist(room)
            placingFixtureKind = nil
            editingFixture = fixture
            return
        }
        if editingWalls {
            guard let room = cornerRoom else { return }
            if let cornerIndex = nearestCornerIndex(to: location, size: size, in: room) {
                cornerActionIndex = cornerIndex
                showingCornerActions = true
                return
            }
            if let point = planPoint(fromView: location, size: size),
               let fixture = room.fixtures.first(where: { fixtureContains($0, point: point) }) {
                fixtureActionID = fixture.id
                showingFixtureActions = true
                return
            }
            if let interior = nearestInteriorWall(to: location, size: size, in: room) {
                editingInterior = interior
                return
            }
            if let hit = nearestOutlineWall(to: location, size: size, in: room) {
                wallActionIndex = hit.index
                tapPlanPoint = hit.planPoint
                showingWallActions = true
            }
            return
        }

        // No tool active: tapping a fixture or a door/window opens its
        // quick actions (Rotate / Edit / Delete).
        if placingKind == nil, let room = cornerRoom {
            if let point = planPoint(fromView: location, size: size),
               let fixture = room.fixtures.first(where: { fixtureContains($0, point: point) }) {
                fixtureActionID = fixture.id
                showingFixtureActions = true
                return
            }
            if let opening = nearestOpeningSegment(to: location, size: size, in: room) {
                openingActionID = opening.id
                showingOpeningActions = true
                return
            }
        }

        guard let kind = placingKind,
              let point = planPoint(fromView: location, size: size) else { return }
        placingKind = nil
        if kind == .roomLabel || kind == .note {
            pendingKind = kind
            pendingPoint = point
            labelText = ""
            showingLabelPrompt = true
        } else {
            appendMarker(kind: kind, label: "", at: point)
        }
    }

    private func handleWallDraftTap(_ location: CGPoint, size: CGSize) {
        guard var room = cornerRoom, let rawPoint = planPoint(fromView: location, size: size) else { return }
        let snappedPoint = snapDraftPoint(CornerRoom.Point(x: Double(rawPoint.x), z: Double(rawPoint.y)), in: room)
        if let start = wallDraftStart {
            // Axis-align mostly-straight walls.
            let end = axisAligned(snappedPoint, from: start)
            let length = ((end.x - start.x) * (end.x - start.x) + (end.z - start.z) * (end.z - start.z)).squareRoot()
            guard length > 0.2 else {
                editError = "That wall would be shorter than 8 inches — tap further away."
                return
            }
            room.interiorWalls.append(CornerRoom.InteriorWall(start: start, end: end))
            persist(room)
            wallDraftStart = nil
            drawingWall = false
        } else {
            wallDraftStart = snappedPoint
        }
    }

    private func snapDraftPoint(_ point: CornerRoom.Point, in room: CornerRoom) -> CornerRoom.Point {
        var candidates = room.corners
        for wall in room.interiorWalls {
            candidates.append(wall.start)
            candidates.append(wall.end)
        }
        for candidate in candidates {
            let dx = candidate.x - point.x
            let dz = candidate.z - point.z
            if (dx * dx + dz * dz).squareRoot() < 0.15 {
                return candidate
            }
        }
        // No corner nearby: snap onto the nearest wall line so a drawn
        // partition tees exactly into it (and the split dimensions show).
        var best: (point: CornerRoom.Point, distance: Double)?
        func consider(_ a: CornerRoom.Point, _ b: CornerRoom.Point) {
            let dx = b.x - a.x
            let dz = b.z - a.z
            let lengthSq = dx * dx + dz * dz
            guard lengthSq > 0.0001 else { return }
            let t = min(max(((point.x - a.x) * dx + (point.z - a.z) * dz) / lengthSq, 0), 1)
            let px = a.x + dx * t
            let pz = a.z + dz * t
            let distance = ((point.x - px) * (point.x - px) + (point.z - pz) * (point.z - pz)).squareRoot()
            if distance < 0.15, distance < (best?.distance ?? .infinity) {
                best = (CornerRoom.Point(x: px, z: pz), distance)
            }
        }
        for index in 0..<room.corners.count {
            consider(room.corners[index], room.corners[(index + 1) % room.corners.count])
        }
        for wall in room.interiorWalls {
            consider(wall.start, wall.end)
        }
        return best?.point ?? point
    }

    private func handleDragChanged(_ value: DragGesture.Value, size: CGSize) {
        // Free-rotate locks the plan: the two-finger twist is driven by the
        // RotateGesture, so the simultaneous drag must not pan or hijack an
        // object, mirroring the MagnificationGesture guard (QA-022).
        guard freeRotateFixtureID == nil else { return }

        // Drawing a wall: a drag sketches it (anchor → finger) with a live
        // dashed preview, and the view never pans. Two single taps still
        // work exactly as before.
        if viewMode == .plan, drawingWall, !eraserActive, let room = cornerRoom {
            if !draftDragActive {
                guard let raw = planPoint(fromView: value.startLocation, size: size) else { return }
                if wallDraftStart == nil {
                    wallDraftStart = snapDraftPoint(CornerRoom.Point(x: Double(raw.x), z: Double(raw.y)),
                                                    in: room)
                }
                draftDragActive = true
            }
            if let start = wallDraftStart, let raw = planPoint(fromView: value.location, size: size) {
                let snappedEnd = snapDraftPoint(CornerRoom.Point(x: Double(raw.x), z: Double(raw.y)),
                                                in: room)
                let end = axisAligned(snappedEnd, from: start)
                wallDraftCurrent = end
                let length = ((end.x - start.x) * (end.x - start.x)
                    + (end.z - start.z) * (end.z - start.z)).squareRoot()
                dragReadout = "Wall: \(Measure.length(length, imperial: useImperial))"
            }
            return
        }

        // Doors/windows slide along their wall — in normal mode only, so
        // Edit mode's wall and corner drags can't be intercepted by an
        // opening sitting near the grab point.
        if viewMode == .plan, !eraserActive, !editingWalls, let room = cornerRoom,
           activeDrag == nil, !dragIsPan,
           let opening = nearestOpeningSegment(to: value.startLocation, size: size, in: room),
           let host = room.hostWall(for: opening),
           let transform = PlanTransform(bounds: plan.bounds, size: size) {
            if host.length > 0.1 {
                activeDrag = (.opening(opening.id), opening.offsetMeters, 0, transform.scale, plan.bounds)
                openingDragContext = (host.ux, host.uz, host.length, opening.widthMeters)
                dragUndoBaseline = room
            }
        }
        // Normal-mode pan: if the first frame didn't grab an opening to
        // slide, commit to panning for the rest of the gesture. Otherwise
        // the sliding plan can carry an opening under the fixed start point
        // on a later frame and hijack the pan mid-stroke (QA-004).
        if viewMode == .plan, !eraserActive, !editingWalls, !drawingWall,
           activeDrag == nil, !dragIsPan {
            dragIsPan = true
        }
        if case .opening(let openingID)? = activeDrag?.target,
           let drag = activeDrag, let context = openingDragContext,
           var room = cornerRoom,
           let index = room.openings.firstIndex(where: { $0.id == openingID }) {
            let delta = planDelta(value.translation, planScale: drag.planScale)
            let along = Double(delta.x) * context.ux + Double(delta.y) * context.uz
            let newOffset = min(max(drag.originX + along, 0), max(context.len - context.width, 0))
            room.openings[index].offsetMeters = newOffset
            cornerRoom = room
            if let newPlan = FloorPlanModel(cornerRoom: room) { plan = newPlan }
            let left = Measure.length(newOffset, imperial: useImperial)
            let right = Measure.length(max(context.len - newOffset - context.width, 0), imperial: useImperial)
            dragReadout = "\(left) ◀ \(room.openings[index].kind.rawValue) ▶ \(right)"
            return
        }
        if editingWalls, let room = cornerRoom {
            if activeDrag == nil && !dragIsPan {
                if let target = dragTarget(at: value.startLocation, size: size, in: room),
                   let transform = PlanTransform(bounds: plan.bounds, size: size) {
                    activeDrag = (target.0, target.1, target.2, transform.scale, plan.bounds)
                    dragUndoBaseline = room
                } else {
                    dragIsPan = true
                }
            }
            if let drag = activeDrag {
                let delta = planDelta(value.translation, planScale: drag.planScale)
                var updated = room
                let newX = drag.originX + Double(delta.x)
                let newZ = drag.originZ + Double(delta.y)
                switch drag.target {
                case .corner(let index):
                    let count = updated.corners.count
                    var pointX = newX
                    var pointZ = newZ
                    if snapOrtho {
                        if abs(pointX - drag.originX) >= abs(pointZ - drag.originZ) {
                            pointZ = drag.originZ
                        } else {
                            pointX = drag.originX
                        }
                    }
                    var moved = CornerRoom.Point(x: gridSnapped(pointX), z: gridSnapped(pointZ))
                    let previous = updated.corners[(index + count - 1) % count]
                    let next = updated.corners[(index + 1) % count]
                    moved = snapped(moved, previous: previous, next: next)
                    updated.corners[index] = moved
                case .outlineWall(let index):
                    // Both corners move together along the wall's normal,
                    // so the wall keeps its length and slides in or out.
                    guard let baseline = dragUndoBaseline,
                          baseline.corners.count == updated.corners.count,
                          index < baseline.corners.count else { break }
                    let count = baseline.corners.count
                    let a0 = baseline.corners[index]
                    let b0 = baseline.corners[(index + 1) % count]
                    let wx = b0.x - a0.x
                    let wz = b0.z - a0.z
                    let wallLength = (wx * wx + wz * wz).squareRoot()
                    guard wallLength > 0.01 else { break }
                    let nx = -wz / wallLength
                    let nz = wx / wallLength
                    let push = gridSnapped(Double(delta.x) * nx + Double(delta.y) * nz)
                    updated.corners[index] = CornerRoom.Point(x: a0.x + nx * push,
                                                              z: a0.z + nz * push)
                    updated.corners[(index + 1) % count] = CornerRoom.Point(x: b0.x + nx * push,
                                                                            z: b0.z + nz * push)
                case .interiorBody(let id):
                    // The whole partition slides perpendicular; the live
                    // readout shows the room width left on each side.
                    guard let baseline = dragUndoBaseline,
                          let baseWall = baseline.interiorWalls.first(where: { $0.id == id }),
                          let wallIndex = updated.interiorWalls.firstIndex(where: { $0.id == id }) else { break }
                    let wx = baseWall.end.x - baseWall.start.x
                    let wz = baseWall.end.z - baseWall.start.z
                    let wallLength = (wx * wx + wz * wz).squareRoot()
                    guard wallLength > 0.01 else { break }
                    let nx = -wz / wallLength
                    let nz = wx / wallLength
                    let push = gridSnapped(Double(delta.x) * nx + Double(delta.y) * nz)
                    updated.interiorWalls[wallIndex].start = CornerRoom.Point(x: baseWall.start.x + nx * push,
                                                                              z: baseWall.start.z + nz * push)
                    updated.interiorWalls[wallIndex].end = CornerRoom.Point(x: baseWall.end.x + nx * push,
                                                                            z: baseWall.end.z + nz * push)
                    dragReadout = partitionWidthReadout(for: updated.interiorWalls[wallIndex], in: updated)
                case .interiorStart(let id):
                    if let index = updated.interiorWalls.firstIndex(where: { $0.id == id }) {
                        let other = updated.interiorWalls[index].end
                        updated.interiorWalls[index].start = snapped(CornerRoom.Point(x: newX, z: newZ),
                                                                     previous: other, next: other)
                    }
                case .interiorEnd(let id):
                    if let index = updated.interiorWalls.firstIndex(where: { $0.id == id }) {
                        let other = updated.interiorWalls[index].start
                        updated.interiorWalls[index].end = snapped(CornerRoom.Point(x: newX, z: newZ),
                                                                   previous: other, next: other)
                    }
                case .fixture(let id):
                    if let index = updated.fixtures.firstIndex(where: { $0.id == id }) {
                        updated.fixtures[index].x = gridSnapped(newX)
                        updated.fixtures[index].z = gridSnapped(newZ)
                    }
                case .opening:
                    break   // handled earlier, before this block
                }
                cornerRoom = updated
                if let newPlan = FloorPlanModel(cornerRoom: updated) {
                    plan = newPlan
                }
                return
            }
        }
        // Panning. If the pan started on a wall outside Edit mode, teach
        // the workflow in the moment instead of failing silently.
        if viewMode == .plan, !editingWalls, !drawingWall, activeDrag == nil,
           let room = cornerRoom, dragReadout == nil,
           nearestOutlineWall(to: value.startLocation, size: size, in: room) != nil
               || nearestInteriorWall(to: value.startLocation, size: size, in: room) != nil {
            dragReadout = "Panning — tap Edit to move walls"
        }
        offset = CGSize(width: offsetBase.width + value.translation.width,
                        height: offsetBase.height + value.translation.height)
    }

    private func handleDragEnded() {
        if draftDragActive {
            commitDraftWall()
            draftDragActive = false
            dragReadout = nil
            return
        }
        // Free-rotate: the drag was ignored in handleDragChanged, so leave
        // the pan base untouched — resyncing it here would jump the view
        // after the twist ends (QA-022).
        if freeRotateFixtureID != nil {
            activeDrag = nil
            dragIsPan = false
            openingDragContext = nil
            return
        }
        if activeDrag != nil, let room = cornerRoom {
            persist(room)
        }
        // Always resync the pan base to the current offset: a hijacked or
        // opening drag can leave `offset` ahead of `offsetBase`, which would
        // otherwise make the next pan jump the whole view (QA-004).
        offsetBase = offset
        activeDrag = nil
        dragIsPan = false
        dragReadout = nil
        openingDragContext = nil
    }

    /// Ends a drag-to-draw stroke. Too-short strokes keep the start point
    /// so the tap-tap flow can finish the wall instead.
    private func commitDraftWall() {
        defer { wallDraftCurrent = nil }
        guard var room = cornerRoom,
              let start = wallDraftStart,
              let end = wallDraftCurrent else { return }
        let length = ((end.x - start.x) * (end.x - start.x)
            + (end.z - start.z) * (end.z - start.z)).squareRoot()
        guard length > 0.2 else { return }
        room.interiorWalls.append(CornerRoom.InteriorWall(start: start, end: end))
        persist(room)
        wallDraftStart = nil
        drawingWall = false
    }

    private func axisAligned(_ end: CornerRoom.Point, from start: CornerRoom.Point) -> CornerRoom.Point {
        var aligned = end
        let dx = end.x - start.x
        let dz = end.z - start.z
        if snapOrtho {
            // Ortho: every drawn wall is exactly horizontal or vertical.
            if abs(dx) >= abs(dz) {
                aligned.z = start.z
            } else {
                aligned.x = start.x
            }
            return aligned
        }
        if abs(dx) > abs(dz) * 2 {
            aligned.z = start.z
        } else if abs(dz) > abs(dx) * 2 {
            aligned.x = start.x
        }
        return aligned
    }

    private func dragTarget(at location: CGPoint, size: CGSize,
                            in room: CornerRoom) -> (DragTarget, Double, Double)? {
        if let index = nearestCornerIndex(to: location, size: size, in: room) {
            return (.corner(index), room.corners[index].x, room.corners[index].z)
        }
        guard let transform = PlanTransform(bounds: plan.bounds, size: size) else { return nil }
        for wall in room.interiorWalls {
            let startView = viewPoint(fromContent: transform.toView(CGPoint(x: wall.start.x, y: wall.start.z)), size: size)
            if hypot(startView.x - location.x, startView.y - location.y) < 30 {
                return (.interiorStart(wall.id), wall.start.x, wall.start.z)
            }
            let endView = viewPoint(fromContent: transform.toView(CGPoint(x: wall.end.x, y: wall.end.z)), size: size)
            if hypot(endView.x - location.x, endView.y - location.y) < 30 {
                return (.interiorEnd(wall.id), wall.end.x, wall.end.z)
            }
        }
        if let point = planPoint(fromView: location, size: size),
           let fixture = room.fixtures.first(where: { fixtureContains($0, point: point) }) {
            return (.fixture(fixture.id), fixture.x, fixture.z)
        }
        // Grabbing a wall's body slides the whole wall perpendicular — the
        // push/pull way to resize a room. Partitions first (they sit inside
        // the outline), then outline walls, with a generous grab zone.
        if let interior = nearestInteriorWall(to: location, size: size, in: room) {
            return (.interiorBody(interior.id), 0, 0)
        }
        if let hit = nearestOutlineWall(to: location, size: size, in: room, within: 44) {
            return (.outlineWall(hit.index),
                    room.corners[hit.index].x, room.corners[hit.index].z)
        }
        return nil
    }

    private func fixtureContains(_ fixture: CornerRoom.Fixture, point: CGPoint) -> Bool {
        let radians = fixture.rotationDegrees * .pi / 180
        let dx = Double(point.x) - fixture.x
        let dz = Double(point.y) - fixture.z
        let localX = dx * cos(radians) + dz * sin(radians)
        let localZ = -dx * sin(radians) + dz * cos(radians)
        return abs(localX) <= fixture.widthMeters / 2 + 0.08
            && abs(localZ) <= fixture.depthMeters / 2 + 0.08
    }

    private func snapped(_ point: CornerRoom.Point,
                         previous: CornerRoom.Point,
                         next: CornerRoom.Point) -> CornerRoom.Point {
        var result = point
        if abs(result.x - previous.x) < 0.08 {
            result.x = previous.x
        } else if abs(result.x - next.x) < 0.08 {
            result.x = next.x
        }
        if abs(result.z - previous.z) < 0.08 {
            result.z = previous.z
        } else if abs(result.z - next.z) < 0.08 {
            result.z = next.z
        }
        return result
    }

    private func nearestCornerIndex(to location: CGPoint, size: CGSize, in room: CornerRoom) -> Int? {
        guard let transform = PlanTransform(bounds: plan.bounds, size: size) else { return nil }
        var best: (index: Int, distance: CGFloat)?
        for (index, corner) in room.corners.enumerated() {
            let content = transform.toView(CGPoint(x: corner.x, y: corner.z))
            let view = viewPoint(fromContent: content, size: size)
            let distance = hypot(view.x - location.x, view.y - location.y)
            if distance < 34, distance < (best?.distance ?? .infinity) {
                best = (index, distance)
            }
        }
        return best?.index
    }

    private func nearestOutlineWall(to location: CGPoint, size: CGSize,
                                    in room: CornerRoom,
                                    within maxDistance: CGFloat = 26) -> (index: Int, planPoint: CGPoint)? {
        guard let transform = PlanTransform(bounds: plan.bounds, size: size) else { return nil }
        let count = room.corners.count
        var best: (index: Int, distance: CGFloat)?
        for index in 0..<count {
            let a = room.corners[index]
            let b = room.corners[(index + 1) % count]
            let va = viewPoint(fromContent: transform.toView(CGPoint(x: a.x, y: a.z)), size: size)
            let vb = viewPoint(fromContent: transform.toView(CGPoint(x: b.x, y: b.z)), size: size)
            let distance = distanceToSegment(location, va, vb)
            if distance < maxDistance, distance < (best?.distance ?? .infinity) {
                best = (index, distance)
            }
        }
        guard let best, let point = planPoint(fromView: location, size: size) else { return nil }
        return (best.index, point)
    }

    private func nearestInteriorWall(to location: CGPoint, size: CGSize,
                                     in room: CornerRoom) -> CornerRoom.InteriorWall? {
        guard let transform = PlanTransform(bounds: plan.bounds, size: size) else { return nil }
        var best: (wall: CornerRoom.InteriorWall, distance: CGFloat)?
        for wall in room.interiorWalls {
            let va = viewPoint(fromContent: transform.toView(CGPoint(x: wall.start.x, y: wall.start.z)), size: size)
            let vb = viewPoint(fromContent: transform.toView(CGPoint(x: wall.end.x, y: wall.end.z)), size: size)
            let distance = distanceToSegment(location, va, vb)
            if distance < 22, distance < (best?.distance ?? .infinity) {
                best = (wall, distance)
            }
        }
        return best?.wall
    }

    private func nearestOpeningSegment(to location: CGPoint, size: CGSize,
                                       in room: CornerRoom) -> CornerRoom.Opening? {
        guard let transform = PlanTransform(bounds: plan.bounds, size: size) else { return nil }
        var best: (opening: CornerRoom.Opening, distance: CGFloat)?
        for opening in room.openings {
            guard let host = room.hostWall(for: opening) else { continue }
            let from = min(max(opening.offsetMeters, 0), host.length)
            let to = min(from + max(opening.widthMeters, 0.05), host.length)
            guard to > from else { continue }
            let va = viewPoint(fromContent: transform.toView(
                CGPoint(x: host.start.x + host.ux * from, y: host.start.z + host.uz * from)), size: size)
            let vb = viewPoint(fromContent: transform.toView(
                CGPoint(x: host.start.x + host.ux * to, y: host.start.z + host.uz * to)), size: size)
            let distance = distanceToSegment(location, va, vb)
            if distance < 22, distance < (best?.distance ?? .infinity) {
                best = (opening, distance)
            }
        }
        return best?.opening
    }

    private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 1 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: - Wall editing actions

    private func addOpening(_ kind: CornerRoom.Opening.Kind) {
        guard let index = wallActionIndex else { return }
        insertOpening(kind: kind, wallIndex: index, planPoint: tapPlanPoint)
    }

    private func insertOpening(kind: CornerRoom.Opening.Kind, wallIndex: Int, planPoint: CGPoint) {
        guard var room = cornerRoom, wallIndex >= 0, wallIndex < room.corners.count else { return }
        let count = room.corners.count
        let a = room.corners[wallIndex]
        let b = room.corners[(wallIndex + 1) % count]
        let dx = b.x - a.x
        let dz = b.z - a.z
        let length = (dx * dx + dz * dz).squareRoot()
        guard length > 0.1 else { return }
        let width = min(kind.defaultWidthMeters, length)
        let projection = ((Double(planPoint.x) - a.x) * dx + (Double(planPoint.y) - a.z) * dz) / length
        let offsetOnWall = min(max(projection - width / 2, 0), max(length - width, 0))
        room.openings.append(CornerRoom.Opening(kind: kind, wallIndex: wallIndex,
                                                offsetMeters: offsetOnWall, widthMeters: width))
        persist(room)
        flashConfirmation("\(kind.rawValue) added — Wall \(wallIndex + 1)")
    }

    private enum WallTarget {
        case outline(Int)
        case interior(UUID)
        case floor
    }

    /// The nearest wall of any kind — outline or interior — with no
    /// distance limit; used by the opening placement tool.
    private func nearestWallTarget(to location: CGPoint, size: CGSize,
                                   in room: CornerRoom) -> (target: WallTarget, planPoint: CGPoint)? {
        guard let transform = PlanTransform(bounds: plan.bounds, size: size) else { return nil }
        var best: (target: WallTarget, distance: CGFloat)?
        let count = room.corners.count
        for index in 0..<count {
            let a = room.corners[index]
            let b = room.corners[(index + 1) % count]
            let va = viewPoint(fromContent: transform.toView(CGPoint(x: a.x, y: a.z)), size: size)
            let vb = viewPoint(fromContent: transform.toView(CGPoint(x: b.x, y: b.z)), size: size)
            let distance = distanceToSegment(location, va, vb)
            if distance < (best?.distance ?? .infinity) {
                best = (.outline(index), distance)
            }
        }
        for wall in room.interiorWalls {
            let va = viewPoint(fromContent: transform.toView(CGPoint(x: wall.start.x, y: wall.start.z)), size: size)
            let vb = viewPoint(fromContent: transform.toView(CGPoint(x: wall.end.x, y: wall.end.z)), size: size)
            let distance = distanceToSegment(location, va, vb)
            if distance < (best?.distance ?? .infinity) {
                best = (.interior(wall.id), distance)
            }
        }
        guard let best, let point = planPoint(fromView: location, size: size) else { return nil }
        return (best.target, point)
    }

    private func insertInteriorOpening(kind: CornerRoom.Opening.Kind,
                                       interiorWallID: UUID, planPoint: CGPoint) {
        guard var room = cornerRoom,
              let wall = room.interiorWalls.first(where: { $0.id == interiorWallID }) else { return }
        let dx = wall.end.x - wall.start.x
        let dz = wall.end.z - wall.start.z
        let length = (dx * dx + dz * dz).squareRoot()
        guard length > 0.3 else { return }
        let width = min(kind.defaultWidthMeters, length)
        let projection = ((Double(planPoint.x) - wall.start.x) * dx
            + (Double(planPoint.y) - wall.start.z) * dz) / length
        let offsetOnWall = min(max(projection - width / 2, 0), max(length - width, 0))
        var opening = CornerRoom.Opening(kind: kind, wallIndex: 0,
                                         offsetMeters: offsetOnWall, widthMeters: width)
        opening.interiorWallID = interiorWallID
        room.openings.append(opening)
        persist(room)
        flashConfirmation("\(kind.rawValue) added — interior wall")
    }

    private func placeInteriorOpeningFromDialog(_ kind: CornerRoom.Opening.Kind) {
        guard let pending = pendingInteriorWall, let room = cornerRoom else { return }
        let minX = room.corners.map(\.x).min() ?? 0
        let minZ = room.corners.map(\.z).min() ?? 0
        insertInteriorOpening(kind: kind, interiorWallID: pending.id,
                              planPoint: CGPoint(x: Double(pending.hit.x) + minX,
                                                 y: Double(pending.hit.z) + minZ))
        pendingInteriorWall = nil
    }

    // MARK: - Layers, snap, camera, assemblies

    private var layersSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Dimensions", isOn: layerBinding(\.dimensions))
                    Toggle("Doors & Windows", isOn: layerBinding(\.openings))
                    Toggle("Interior Walls", isOn: layerBinding(\.interiorWalls))
                    Toggle("Fixtures", isOn: layerBinding(\.fixtures))
                    Toggle("Markers", isOn: layerBinding(\.markers))
                    Toggle("Right-Angle Squares", isOn: layerBinding(\.rightAngles))
                } footer: {
                    Text("Layers apply on screen and in every export — hide clutter for a client plan, show everything for a permit set.")
                }
                Button("Show All Layers") {
                    layers = PlanLayers()
                    layers.save()
                }
            }
            .navigationTitle("Layers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingLayersSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func layerBinding(_ keyPath: WritableKeyPath<PlanLayers, Bool>) -> Binding<Bool> {
        Binding(
            get: { layers[keyPath: keyPath] },
            set: {
                layers[keyPath: keyPath] = $0
                layers.save()
            }
        )
    }

    /// Grid snap: coordinates land on clean tape-measure increments.
    private func gridSnapped(_ value: Double) -> Double {
        guard snapGridInches > 0 else { return value }
        let step = Double(snapGridInches) * 0.0254
        return (value / step).rounded() * step
    }

    private enum CameraView {
        case top, threeQuarter, front
    }

    private func compassButton(_ label: String, _ mode: CameraView) -> some View {
        Button {
            snapCamera(mode)
        } label: {
            Text(label)
                .font(.caption.bold())
                .frame(width: 46)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
        }
        .accessibilityLabel(cameraViewName(mode))
        .accessibilityHint("Snaps the 3D view to a standard angle")
    }

    private func cameraViewName(_ mode: CameraView) -> String {
        switch mode {
        case .top: return "Top-down view"
        case .threeQuarter: return "Three-quarter view"
        case .front: return "Front view"
        }
    }

    private func snapCamera(_ mode: CameraView) {
        let sceneRooms: [CornerRoom] = cornerRoom.map { [$0] } ?? rooms.map(\.room)
        let allCorners = sceneRooms.flatMap(\.corners)
        guard let minX = allCorners.map(\.x).min(),
              let maxX = allCorners.map(\.x).max(),
              let minZ = allCorners.map(\.z).min(),
              let maxZ = allCorners.map(\.z).max() else { return }
        let height = sceneRooms.map { $0.ceilingHeightMeters > 0.5 ? $0.ceilingHeightMeters : 2.4 }.max() ?? 2.4
        let centerX = Float((maxX - minX) / 2)
        let centerZ = Float((maxZ - minZ) / 2)
        let maxDimension = Float(max(maxX - minX, maxZ - minZ, height))
        switch mode {
        case .top:
            cameraPose = (SCNVector3(centerX, maxDimension * 1.9, centerZ + 0.02),
                          SCNVector3(centerX, 0, centerZ))
        case .threeQuarter:
            cameraPose = Model3DBuilder.aerialPose(centerX: centerX, centerZ: centerZ,
                                                   maxDimension: maxDimension,
                                                   maxHeight: Float(height))
        case .front:
            cameraPose = (SCNVector3(centerX, Float(height) * 0.6, centerZ + maxDimension * 1.9),
                          SCNVector3(centerX, Float(height) * 0.45, centerZ))
        }
        cameraPoseToken += 1
    }

    private func placeAssembly(_ assembly: FixtureAssembly) {
        guard var room = cornerRoom, !assembly.fixtures.isEmpty,
              !room.corners.isEmpty else { return }
        let centroidX = room.corners.map(\.x).reduce(0, +) / Double(room.corners.count)
        let centroidZ = room.corners.map(\.z).reduce(0, +) / Double(room.corners.count)
        let baseX = assembly.fixtures.map(\.x).reduce(0, +) / Double(assembly.fixtures.count)
        let baseZ = assembly.fixtures.map(\.z).reduce(0, +) / Double(assembly.fixtures.count)
        for var fixture in assembly.fixtures {
            fixture.id = UUID()
            fixture.x = fixture.x - baseX + centroidX
            fixture.z = fixture.z - baseZ + centroidZ
            room.fixtures.append(fixture)
        }
        persist(room)
        flashConfirmation("\(assembly.name) placed — drag pieces into position")
    }

    private func saveAssembly() {
        guard let room = cornerRoom, !room.fixtures.isEmpty else { return }
        let trimmed = assemblyName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var updated = assemblies
        updated.append(FixtureAssembly(name: trimmed, fixtures: room.fixtures))
        AssemblyStore.save(updated)
        assemblies = updated
        flashConfirmation("Saved “\(trimmed)” to My Assemblies")
    }

    // MARK: - Wall paint

    private var paintSheet: some View {
        NavigationStack {
            Form {
                ColorPicker("Wall colour", selection: paintColorBinding, supportsOpacity: false)
                Button("Reset to Default Finish") {
                    applyPaint(nil)
                    showingPaintSheet = false
                }
            }
            .navigationTitle({
                if case .floor = paintTarget { return "Floor Colour" }
                return "Paint Wall"
            }())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingPaintSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var paintColorBinding: Binding<Color> {
        Binding(
            get: {
                guard let room = cornerRoom else { return .gray }
                switch paintTarget {
                case .outline(let index):
                    return room.outlineWallHex[index].flatMap { Color(hexString: $0) } ?? .gray
                case .interior(let id):
                    let hex = room.interiorWalls.first(where: { $0.id == id })?.paintHex
                    return hex.flatMap { Color(hexString: $0) } ?? .gray
                case .floor:
                    return room.floorHex.flatMap { Color(hexString: $0) } ?? .brown
                case nil:
                    return .gray
                }
            },
            set: { applyPaint($0.hexString()) }
        )
    }

    /// Live while the picker moves; saved once when the sheet closes.
    private func applyPaint(_ hex: String?) {
        guard var room = cornerRoom else { return }
        // Capture the pre-paint room before the first live mutation so the
        // commit's Undo snapshot restores the original colour (QA-020).
        if dragUndoBaseline == nil { dragUndoBaseline = cornerRoom }
        switch paintTarget {
        case .outline(let index):
            room.outlineWallHex[index] = hex
        case .interior(let id):
            guard let wallIndex = room.interiorWalls.firstIndex(where: { $0.id == id }) else { return }
            room.interiorWalls[wallIndex].paintHex = hex
        case .floor:
            room.floorHex = hex
        case nil:
            return
        }
        cornerRoom = room
        if let newPlan = FloorPlanModel(cornerRoom: room) {
            plan = newPlan
        }
    }

    private func commitPaint() {
        guard paintTarget != nil, let room = cornerRoom else { return }
        paintTarget = nil
        persist(room)
    }

    /// Match properties: one wall's paint applied to every wall.
    private func paintAllWalls(from index: Int) {
        guard var room = cornerRoom, let hex = room.outlineWallHex[index] else { return }
        for wallIndex in 0..<room.corners.count {
            room.outlineWallHex[wallIndex] = hex
        }
        for wallIndex in room.interiorWalls.indices {
            room.interiorWalls[wallIndex].paintHex = hex
        }
        persist(room)
        flashConfirmation("All walls painted to match")
    }

    private func flipOpeningHinge() {
        guard var room = cornerRoom,
              let index = room.openings.firstIndex(where: { $0.id == openingActionID }) else { return }
        room.openings[index].hingeOnEnd = !(room.openings[index].hingeOnEnd ?? false)
        persist(room)
    }

    private func flipOpeningSwing() {
        guard var room = cornerRoom,
              let index = room.openings.firstIndex(where: { $0.id == openingActionID }) else { return }
        room.openings[index].swingsOutward = !(room.openings[index].swingsOutward ?? false)
        persist(room)
    }

    /// Removes an interior wall together with the openings that live on it.
    private func deleteInteriorWall(_ id: UUID) {
        guard var room = cornerRoom else { return }
        room.interiorWalls.removeAll { $0.id == id }
        room.openings.removeAll { $0.interiorWallID == id }
        persist(room)
    }

    /// Brief on-plan confirmation so an add can never fail silently.
    private func flashConfirmation(_ text: String) {
        dragReadout = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if dragReadout == text {
                dragReadout = nil
            }
        }
    }

    private func splitWall() {
        guard let index = wallActionIndex, var room = cornerRoom else { return }
        let count = room.corners.count
        let a = room.corners[index]
        let b = room.corners[(index + 1) % count]
        let dx = b.x - a.x
        let dz = b.z - a.z
        let lengthSquared = dx * dx + dz * dz
        guard lengthSquared > 0.001 else { return }
        let raw = ((Double(tapPlanPoint.x) - a.x) * dx + (Double(tapPlanPoint.y) - a.z) * dz) / lengthSquared
        let t = min(max(raw, 0.1), 0.9)
        let corner = CornerRoom.Point(x: a.x + dx * t, z: a.z + dz * t)
        let splitOffset = t * lengthSquared.squareRoot()
        room.corners.insert(corner, at: index + 1)
        var splitHex: [Int: String] = [:]
        for (wallIndex, hex) in room.outlineWallHex {
            if wallIndex > index {
                splitHex[wallIndex + 1] = hex
            } else if wallIndex == index {
                splitHex[index] = hex
                splitHex[index + 1] = hex
            } else {
                splitHex[wallIndex] = hex
            }
        }
        room.outlineWallHex = splitHex
        room.openings = room.openings.map { opening in
            var updated = opening
            guard updated.interiorWallID == nil else { return updated }
            if updated.wallIndex > index {
                updated.wallIndex += 1
            } else if updated.wallIndex == index, updated.offsetMeters >= splitOffset {
                updated.wallIndex += 1
                updated.offsetMeters -= splitOffset
            }
            return updated
        }
        persist(room)
    }

    private func eraseOutlineWall(_ index: Int) {
        guard let room = cornerRoom else { return }
        guard room.corners.count > 3 else {
            editError = "A room needs at least 3 walls — move corners instead of deleting."
            return
        }
        cornerActionIndex = (index + 1) % room.corners.count
        removeCorner()
    }

    private func removeCorner() {
        guard let index = cornerActionIndex, var room = cornerRoom else { return }
        guard room.corners.count > 3 else {
            editError = "A room needs at least 3 corners."
            return
        }
        let count = room.corners.count
        let previousIndex = (index + count - 1) % count
        let a = room.corners[previousIndex]
        let b = room.corners[index]
        let previousLength = ((b.x - a.x) * (b.x - a.x) + (b.z - a.z) * (b.z - a.z)).squareRoot()
        room.corners.remove(at: index)
        var mergedHex: [Int: String] = [:]
        for (wallIndex, hex) in room.outlineWallHex {
            if wallIndex == index { continue }   // absorbed by the previous wall
            mergedHex[wallIndex > index ? wallIndex - 1 : wallIndex] = hex
        }
        room.outlineWallHex = mergedHex
        room.openings = room.openings.map { opening in
            var updated = opening
            guard updated.interiorWallID == nil else { return updated }
            if updated.wallIndex == index {
                updated.wallIndex = previousIndex
                updated.offsetMeters += previousLength
            }
            if updated.wallIndex > index {
                updated.wallIndex -= 1
            }
            if updated.wallIndex >= room.corners.count {
                updated.wallIndex = room.corners.count - 1
            }
            return updated
        }
        // Reindexing adds the absorbed wall's length to the offset, which can
        // push an opening past the merged (chord) wall's end and make it
        // vanish from the plan. Clamp every opening back onto its host wall
        // using the merged geometry (QA-021).
        for i in room.openings.indices {
            guard let host = room.hostWall(for: room.openings[i]) else { continue }
            let maxOffset = max(host.length - room.openings[i].widthMeters, 0)
            room.openings[i].offsetMeters = min(max(room.openings[i].offsetMeters, 0), maxOffset)
        }
        persist(room)
    }

    private func correctLengthFromDialog() {
        guard let index = wallActionIndex, let room = cornerRoom else { return }
        let count = room.corners.count
        let a = room.corners[index]
        let b = room.corners[(index + 1) % count]
        editingWallIndex = index
        editLength = ((b.x - a.x) * (b.x - a.x) + (b.z - a.z) * (b.z - a.z)).squareRoot()
        showingWallEdit = true
    }

    // MARK: - Undo / redo

    private func pushMarkerUndo() {
        undoStack.append(EditSnapshot(room: cornerRoom, markers: markers))
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(EditSnapshot(room: cornerRoom, markers: markers))
        applySnapshot(snapshot)
    }

    private func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(EditSnapshot(room: cornerRoom, markers: markers))
        applySnapshot(snapshot)
    }

    private func applySnapshot(_ snapshot: EditSnapshot) {
        markers = snapshot.markers
        // Surface save failures instead of silently letting disk diverge
        // from the UI, matching persist() (QA-054).
        do {
            try ScanStore.saveMarkers(markers, for: project)
            if let room = snapshot.room {
                try saveRoom(room)
                cornerRoom = room
                if let newPlan = FloorPlanModel(cornerRoom: room) {
                    plan = newPlan
                }
                editVersion += 1
            }
        } catch {
            editError = error.localizedDescription
        }
    }

    // MARK: - Markers

    private func appendMarker(kind: PlanMarkers.Marker.Kind, label: String, at point: CGPoint) {
        pushMarkerUndo()
        markers.markers.append(PlanMarkers.Marker(kind: kind, label: label,
                                                  x: Double(point.x), y: Double(point.y)))
        saveMarkers()
    }

    private func saveMarkers() {
        do {
            try ScanStore.saveMarkers(markers, for: project)
        } catch {
            editError = error.localizedDescription
        }
    }

    /// Applies the same plan-space transform a rescale / resize / length
    /// correction used to the markers that sit inside the room's old bounds,
    /// so pinned features (electrical, mechanical, notes) keep their place on
    /// the geometry instead of being left behind. Saves once if anything
    /// moved. Markers share the plan coordinate space of the room's corners.
    private func remapMarkers(inOldBounds oldBounds: (minX: Double, maxX: Double, minZ: Double, maxZ: Double),
                              map: (CGPoint) -> CGPoint) {
        guard !markers.markers.isEmpty else { return }
        let pad = 0.5   // include markers sitting on the walls themselves
        var changed = false
        for index in markers.markers.indices {
            let mx = markers.markers[index].x
            let my = markers.markers[index].y
            guard mx >= oldBounds.minX - pad, mx <= oldBounds.maxX + pad,
                  my >= oldBounds.minZ - pad, my <= oldBounds.maxZ + pad else { continue }
            let mapped = map(CGPoint(x: mx, y: my))
            markers.markers[index].x = Double(mapped.x)
            markers.markers[index].y = Double(mapped.y)
            changed = true
        }
        if changed { saveMarkers() }
    }

    /// Displacement of the nearest point on the old outline, interpolated
    /// between the two host corners' displacements — mirrors the private
    /// helper in `RoomDimensionEditor.settingWallLength` so markers move with
    /// the walls a length correction shifted.
    private static func outlineDisplacement(near p: CornerRoom.Point,
                                            oldCorners: [CornerRoom.Point],
                                            newCorners: [CornerRoom.Point]) -> (dx: Double, dz: Double) {
        let count = oldCorners.count
        guard count >= 3, newCorners.count == count else { return (0, 0) }
        var best = (distance: Double.infinity, dx: 0.0, dz: 0.0)
        for i in 0..<count {
            let a = oldCorners[i]
            let b = oldCorners[(i + 1) % count]
            let abx = b.x - a.x
            let abz = b.z - a.z
            let lengthSquared = abx * abx + abz * abz
            var t = lengthSquared > 0 ? ((p.x - a.x) * abx + (p.z - a.z) * abz) / lengthSquared : 0
            t = min(max(t, 0), 1)
            let nx = a.x + abx * t
            let nz = a.z + abz * t
            let distance = ((p.x - nx) * (p.x - nx) + (p.z - nz) * (p.z - nz)).squareRoot()
            if distance < best.distance {
                let next = (i + 1) % count
                let da = (x: newCorners[i].x - a.x, z: newCorners[i].z - a.z)
                let db = (x: newCorners[next].x - oldCorners[next].x, z: newCorners[next].z - oldCorners[next].z)
                best = (distance, da.x + (db.x - da.x) * t, da.z + (db.z - da.z) * t)
            }
        }
        return (best.dx, best.dz)
    }

    // MARK: - Overall exterior size

    private var sizeEditSheet: some View {
        NavigationStack {
            Form {
                Section {
                    DimensionRow(label: "Overall width", meters: $editOverallWidth, imperial: useImperial)
                    DimensionRow(label: "Overall depth", meters: $editOverallDepth, imperial: useImperial)
                } footer: {
                    Text("The exterior extents of the whole outline. The room scales to match; door and window sizes stay true, and everything inside keeps its position in proportion.")
                }
                Section {
                    Button("Apply New Size") { applyOverallSize() }
                        .disabled(editOverallWidth < 0.3 || editOverallDepth < 0.3)
                }
            }
            .navigationTitle("Overall Size")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingSizeEdit = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func applyOverallSize() {
        guard var room = cornerRoom, let bounds = room.planBounds else { return }
        let oldWidth = bounds.maxX - bounds.minX
        let oldDepth = bounds.maxZ - bounds.minZ
        guard oldWidth > 0.1, oldDepth > 0.1 else { return }
        let xFactor = editOverallWidth / oldWidth
        let zFactor = editOverallDepth / oldDepth
        room = room.resized(xFactor: xFactor, zFactor: zFactor)
        if persist(room) {
            // Markers follow the same per-axis scale about the min corner.
            remapMarkers(inOldBounds: bounds) { p in
                CGPoint(x: bounds.minX + (Double(p.x) - bounds.minX) * xFactor,
                        y: bounds.minZ + (Double(p.y) - bounds.minZ) * zFactor)
            }
        }
        showingSizeEdit = false
    }

    // MARK: - Tape-measure accuracy check

    private var calibrationSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Wall", selection: $calibrationWallIndex) {
                        ForEach(0..<(cornerRoom?.corners.count ?? 0), id: \.self) { index in
                            Text("Wall \(index + 1) — \(Measure.length(outlineWallLength(index), imperial: useImperial))")
                                .tag(index)
                        }
                    }
                    DimensionRow(label: "Tape measurement", meters: $calibrationTape, imperial: useImperial)
                } footer: {
                    Text("Measure one wall with a tape, pick it here, and enter the real length. Scaling stretches the whole room to match, keeping everything in proportion.")
                }
                Section {
                    LabeledContent("Plan length",
                                   value: Measure.length(outlineWallLength(calibrationWallIndex), imperial: useImperial))
                    LabeledContent("Deviation") {
                        Text(calibrationDeviationText).bold()
                    }
                    Button("Scale Room to Match Tape") { applyCalibration() }
                        .disabled(calibrationFactor == nil)
                }
            }
            .navigationTitle("Accuracy Check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showingCalibration = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func outlineWallLength(_ index: Int) -> Double {
        guard let room = cornerRoom, room.corners.count >= 2,
              index >= 0, index < room.corners.count else { return 0 }
        let a = room.corners[index]
        let b = room.corners[(index + 1) % room.corners.count]
        return ((b.x - a.x) * (b.x - a.x) + (b.z - a.z) * (b.z - a.z)).squareRoot()
    }

    private var calibrationFactor: Double? {
        let measured = outlineWallLength(calibrationWallIndex)
        guard measured > 0.1, calibrationTape > 0.1 else { return nil }
        let factor = calibrationTape / measured
        // Beyond ±50% it's the wrong wall, not drift.
        guard factor > 0.5, factor < 2 else { return nil }
        return factor
    }

    private var calibrationDeviationText: String {
        guard let factor = calibrationFactor else { return "—" }
        return String(format: "%+.1f%%", (factor - 1) * 100)
    }

    private func applyCalibration() {
        guard let factor = calibrationFactor, var room = cornerRoom else { return }
        let oldBounds = room.planBounds
        room = room.scaled(by: factor)
        room.verifiedAccuracyPercent = abs(factor - 1) * 100
        if persist(room), let oldBounds {
            // Markers ride the same uniform scale about the min corner so
            // they stay pinned to the geometry they annotate.
            remapMarkers(inOldBounds: oldBounds) { p in
                CGPoint(x: oldBounds.minX + (Double(p.x) - oldBounds.minX) * factor,
                        y: oldBounds.minZ + (Double(p.y) - oldBounds.minZ) * factor)
            }
        }
        showingCalibration = false
    }

    // MARK: - Dimension editing

    private func applyWallEdit() {
        guard let index = editingWallIndex, let room = cornerRoom else {
            showingWallEdit = false
            return
        }
        if let updated = RoomDimensionEditor.settingWallLength(editLength, at: index, in: room) {
            let oldBounds = room.planBounds
            let oldCorners = room.corners
            let newCorners = updated.corners
            if persist(updated), let oldBounds {
                // Markers follow the outline displacement the length
                // correction applied, using the same interpolation the
                // dimension editor uses for fixtures.
                remapMarkers(inOldBounds: oldBounds) { p in
                    let d = Self.outlineDisplacement(near: CornerRoom.Point(x: Double(p.x), z: Double(p.y)),
                                                     oldCorners: oldCorners, newCorners: newCorners)
                    return CGPoint(x: Double(p.x) + d.dx, y: Double(p.y) + d.dz)
                }
            }
            showingWallEdit = false
        } else {
            editError = "This wall can't be adjusted automatically — correct the opposite wall instead, or recapture the room."
        }
    }

    private func applyCeilingEdit() {
        guard var room = cornerRoom else {
            showingCeilingEdit = false
            return
        }
        room.ceilingHeightMeters = max(editCeiling, 0)
        persist(room)
        showingCeilingEdit = false
    }

    @discardableResult
    private func persist(_ updated: CornerRoom) -> Bool {
        // Build the Undo snapshot up front but only commit it — and clear
        // redo / the drag baseline — after the save succeeds, so a failed
        // write can't corrupt the undo/redo stacks (QA-053).
        let snapshot = EditSnapshot(room: dragUndoBaseline ?? cornerRoom, markers: markers)
        do {
            try saveRoom(updated)
            undoStack.append(snapshot)
            if undoStack.count > 30 { undoStack.removeFirst() }
            redoStack.removeAll()
            dragUndoBaseline = nil
            cornerRoom = updated
            if let newPlan = FloorPlanModel(cornerRoom: updated) {
                plan = newPlan
            }
            editVersion += 1
            return true
        } catch {
            editError = error.localizedDescription
            return false
        }
    }

    /// Writes the edited room back into the project's room list and
    /// regenerates the shared USDZ from every room.
    private func saveRoom(_ updated: CornerRoom) throws {
        if let id = selectedRoomID, let index = rooms.firstIndex(where: { $0.id == id }) {
            rooms[index].room = updated
        } else if rooms.isEmpty {
            let entry = RoomEntry(name: "Room 1", room: updated)
            rooms = [entry]
            selectedRoomID = entry.id
        }
        try ScanStore.saveRooms(rooms, for: project)
        let dir = try ScanStore.folder(for: project)
        Model3DBuilder.writeUSDZInBackground(rooms: rooms.map(\.room),
                                      to: dir.appendingPathComponent(ScanStore.usdzFileName))
    }

    /// Turns the manual measurements into a captured-style room right here
    /// in the editor, then selects it so the tools appear immediately.
    private func convertManualPlanInEditor() {
        guard let manual = ScanStore.loadManualRoom(for: project),
              let converted = CornerRoom(manual: manual) else {
            editError = "The manual measurements couldn't be converted — check the room's width and length."
            return
        }
        var entries = rooms
        entries.append(RoomEntry(name: "Room \(entries.count + 1)",
                                 room: converted.placedAlongside(entries)))
        do {
            try ScanStore.saveRooms(entries, for: project)
            ScanStore.removeFile(named: ScanStore.manualRoomFileName, for: project)
            let dir = try ScanStore.folder(for: project)
            Model3DBuilder.writeUSDZInBackground(rooms: entries.map(\.room),
                                          to: dir.appendingPathComponent(ScanStore.usdzFileName))
            rooms = entries
            canConvertManualPlan = false
            selectedRoomID = entries.last?.id
            switchRoom()
        } catch {
            editError = error.localizedDescription
        }
    }

    /// Editing scope follows the room picker: a selected room is editable,
    /// "All Rooms" shows the merged plan read-only (markers still work).
    private func switchRoom() {
        cancelModes()
        undoStack.removeAll()
        redoStack.removeAll()
        dragUndoBaseline = nil
        if let id = selectedRoomID, let entry = rooms.first(where: { $0.id == id }) {
            cornerRoom = entry.room
            if let roomPlan = FloorPlanModel(cornerRoom: entry.room) { plan = roomPlan }
        } else {
            cornerRoom = nil
            if let mergedPlan = FloorPlanModel(rooms: rooms.map(\.room)) { plan = mergedPlan }
        }
        editVersion += 1
        resetView()
    }
}

// MARK: - Fixture catalog

struct FixtureCatalogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let imperial: Bool
    let onPick: (CornerRoom.Fixture.Kind) -> Void
    var onPickFloor: ((CornerRoom.FloorType?) -> Void)?
    var onPickFloorColor: (() -> Void)?
    var assemblies: [FixtureAssembly] = []
    var onPickAssembly: ((FixtureAssembly) -> Void)?
    var onSaveAssembly: (() -> Void)?
    var onDeleteAssembly: ((IndexSet) -> Void)?
    /// Called with the surviving list after the saved-assemblies manager
    /// edits the store, so the presenter can refresh its cached copy.
    var onAssembliesChanged: (([FixtureAssembly]) -> Void)?

    var body: some View {
        NavigationStack {
            List {
                ForEach(CornerRoom.Fixture.Kind.Category.allCases) { category in
                    Section(category.rawValue) {
                        ForEach(CornerRoom.Fixture.Kind.allCases.filter { $0.category == category }) { kind in
                            Button {
                                onPick(kind)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: kind.sfSymbol)
                                        .frame(width: 32)
                                        .foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(kind.rawValue)
                                            .foregroundStyle(.primary)
                                        Text("\(Measure.length(kind.defaultSize.width, imperial: imperial)) × \(Measure.length(kind.defaultSize.depth, imperial: imperial))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                if !assemblies.isEmpty || onSaveAssembly != nil {
                    Section {
                        ForEach(assemblies) { assembly in
                            Button {
                                onPickAssembly?(assembly)
                                dismiss()
                            } label: {
                                Label("\(assembly.name) — \(assembly.fixtures.count) pieces",
                                      systemImage: "square.stack.3d.up")
                                    .foregroundStyle(.primary)
                            }
                        }
                        .onDelete { offsets in
                            onDeleteAssembly?(offsets)
                        }
                        if let onSaveAssembly {
                            Button {
                                onSaveAssembly()
                                dismiss()
                            } label: {
                                Label("Save This Room's Fixtures…", systemImage: "plus.square.on.square")
                            }
                        }
                        NavigationLink {
                            FixtureAssemblyScreen(onChange: onAssembliesChanged)
                        } label: {
                            Label("Saved Assemblies…", systemImage: "square.stack.3d.up.fill")
                        }
                    } header: {
                        Text("My Assemblies")
                    } footer: {
                        Text("Saved groups drop in at the room centre keeping their layout. Swipe to delete, or tap Saved Assemblies to manage them.")
                    }
                }
                if let onPickFloor {
                    Section {
                        ForEach(CornerRoom.FloorType.allCases) { type in
                            Button {
                                onPickFloor(type)
                                dismiss()
                            } label: {
                                Label(type.rawValue, systemImage: "square.grid.3x3")
                                    .foregroundStyle(.primary)
                            }
                        }
                        Button {
                            onPickFloor(nil)
                            dismiss()
                        } label: {
                            Label("Default Finish", systemImage: "arrow.uturn.backward")
                        }
                        if let onPickFloorColor {
                            Button {
                                onPickFloorColor()
                                dismiss()
                            } label: {
                                Label("Floor Colour…", systemImage: "paintpalette")
                            }
                        }
                    } header: {
                        Text("Flooring — whole room")
                    } footer: {
                        Text("Applies to this room's floor in the 3D model.")
                    }
                }
            }
            .navigationTitle("Fixture Catalog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Editor sheets

struct OpeningEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var opening: CornerRoom.Opening
    let wallCount: Int
    let imperial: Bool
    let onSave: (CornerRoom.Opening) -> Void
    let onDelete: (UUID) -> Void

    init(opening: CornerRoom.Opening, wallCount: Int, imperial: Bool,
         onSave: @escaping (CornerRoom.Opening) -> Void,
         onDelete: @escaping (UUID) -> Void) {
        _opening = State(initialValue: opening)
        self.wallCount = wallCount
        self.imperial = imperial
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $opening.kind) {
                    ForEach(CornerRoom.Opening.Kind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                if opening.interiorWallID == nil {
                    Picker("Wall", selection: $opening.wallIndex) {
                        ForEach(0..<max(wallCount, 1), id: \.self) { index in
                            Text("Wall \(index + 1)").tag(index)
                        }
                    }
                } else {
                    LabeledContent("Wall", value: "Interior wall")
                }
                DimensionRow(label: "Distance from corner", meters: $opening.offsetMeters, imperial: imperial)
                DimensionRow(label: "Width", meters: $opening.widthMeters, imperial: imperial)
                if opening.kind == .window {
                    DimensionRow(label: "Sill height", meters: Binding(
                        get: { opening.sillMeters ?? 0.91 },
                        set: { opening.sillMeters = $0 }
                    ), imperial: imperial)
                    DimensionRow(label: "Window height", meters: Binding(
                        get: { opening.heightMeters ?? 1.07 },
                        set: { opening.heightMeters = $0 }
                    ), imperial: imperial)
                    DimensionRow(label: "Clear opening width", meters: Binding(
                        get: { opening.clearWidthMeters ?? 0 },
                        set: { opening.clearWidthMeters = $0 > 0.01 ? $0 : nil }
                    ), imperial: imperial)
                    DimensionRow(label: "Clear opening height", meters: Binding(
                        get: { opening.clearHeightMeters ?? 0 },
                        set: { opening.clearHeightMeters = $0 > 0.01 ? $0 : nil }
                    ), imperial: imperial)
                }
                if opening.kind == .door || opening.kind == .closetDoor {
                    DimensionRow(label: "Door height", meters: Binding(
                        get: { opening.heightMeters ?? 2.03 },
                        set: { opening.heightMeters = $0 }
                    ), imperial: imperial)
                }
                if opening.kind == .door {
                    Picker("Hinge", selection: Binding(
                        get: { opening.hingeOnEnd ?? false },
                        set: { opening.hingeOnEnd = $0 }
                    )) {
                        Text("Left").tag(false)
                        Text("Right").tag(true)
                    }
                }
                if opening.kind == .door || opening.kind == .closetDoor {
                    Picker("Swing", selection: Binding(
                        get: { opening.swingsOutward ?? false },
                        set: { opening.swingsOutward = $0 }
                    )) {
                        Text("Into room").tag(false)
                        Text("Opposite side").tag(true)
                    }
                }
                Section {
                    Button("Delete", role: .destructive) {
                        onDelete(opening.id)
                        dismiss()
                    }
                }
            }
            .navigationTitle(opening.kind.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(opening)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct FixtureEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var fixture: CornerRoom.Fixture
    let imperial: Bool
    var ceilingMeters: Double?
    let onSave: (CornerRoom.Fixture) -> Void
    let onDelete: (UUID) -> Void

    init(fixture: CornerRoom.Fixture, imperial: Bool,
         ceilingMeters: Double? = nil,
         onSave: @escaping (CornerRoom.Fixture) -> Void,
         onDelete: @escaping (UUID) -> Void) {
        _fixture = State(initialValue: fixture)
        self.imperial = imperial
        self.ceilingMeters = ceilingMeters
        self.onSave = onSave
        self.onDelete = onDelete
    }

    private var isStairs: Bool { fixture.kind == .stairs }
    private var stepCount: Int { max(3, Int(fixture.widthMeters / 0.25)) }

    var body: some View {
        NavigationStack {
            Form {
                DimensionRow(label: isStairs ? "Run (horizontal length)" : "Width",
                             meters: $fixture.widthMeters, imperial: imperial)
                DimensionRow(label: isStairs ? "Stair width" : "Depth",
                             meters: $fixture.depthMeters, imperial: imperial)
                if isStairs {
                    Section {
                        LabeledContent("Treads", value: "\(stepCount)")
                        LabeledContent("Tread depth",
                                       value: Measure.length(fixture.widthMeters / Double(stepCount),
                                                             imperial: imperial))
                        if let ceilingMeters, ceilingMeters > 0.5 {
                            LabeledContent("Rise per step",
                                           value: Measure.length(ceilingMeters / Double(stepCount),
                                                                 imperial: imperial))
                        }
                    } footer: {
                        Text("Steps lay out along the run and climb to the ceiling in the 3D model. A comfortable stair is roughly 10\" treads with a 7–7¾\" rise.")
                    }
                }
                Section {
                    HStack {
                        Slider(value: $fixture.rotationDegrees, in: 0...359, step: 1)
                        Text("\(Int(fixture.rotationDegrees.rounded()))°")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        ForEach([0.0, 45, 90, 135, 180, 270], id: \.self) { degrees in
                            Button("\(Int(degrees))°") {
                                fixture.rotationDegrees = degrees
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                } header: {
                    Text("Rotation")
                } footer: {
                    Text("For fine alignment you can also twist the fixture with two fingers right on the plan: tap it, choose Rotate Freely.")
                }
                Section {
                    Button("Delete", role: .destructive) {
                        onDelete(fixture.id)
                        dismiss()
                    }
                } footer: {
                    Text("Drag the fixture on the plan in Edit Walls mode to reposition it.")
                }
            }
            .navigationTitle(fixture.kind.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(fixture)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct InteriorWallEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var wall: CornerRoom.InteriorWall
    let imperial: Bool
    let onSave: (CornerRoom.InteriorWall) -> Void
    let onDelete: (UUID) -> Void

    init(wall: CornerRoom.InteriorWall, imperial: Bool,
         onSave: @escaping (CornerRoom.InteriorWall) -> Void,
         onDelete: @escaping (UUID) -> Void) {
        _wall = State(initialValue: wall)
        self.imperial = imperial
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DimensionRow(label: "Length", meters: lengthBinding, imperial: imperial)
                } footer: {
                    Text("Adjusting the length moves the wall's end point along its current direction. Drag the endpoints on the plan in Edit Walls mode to reposition it.")
                }
                Section {
                    Button("Delete", role: .destructive) {
                        onDelete(wall.id)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Interior Wall")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(wall)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var lengthBinding: Binding<Double> {
        Binding(
            get: { wall.lengthMeters },
            set: { newLength in
                let current = wall.lengthMeters
                guard newLength > 0.05 else { return }
                let dirX = current > 0.001 ? (wall.end.x - wall.start.x) / current : 1
                let dirZ = current > 0.001 ? (wall.end.z - wall.start.z) / current : 0
                wall.end = CornerRoom.Point(x: wall.start.x + dirX * newLength,
                                            z: wall.start.z + dirZ * newLength)
            }
        )
    }
}
