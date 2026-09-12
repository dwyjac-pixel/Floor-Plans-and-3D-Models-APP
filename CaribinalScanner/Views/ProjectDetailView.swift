import SwiftUI
import SwiftData
import RoomPlan
import ARKit

/// Hub for one project: client details, scan + floor plan + 3D model,
/// notes, photos, and the PDF report.
struct ProjectDetailView: View {
    @Bindable var project: RenovationProject

    @Environment(\.modelContext) private var modelContext
    @AppStorage("useImperialUnits") private var useImperial = true

    @State private var showingScanner = false
    @State private var showingModelViewer = false
    @State private var showingManualEntry = false
    @State private var showingCornerCapture = false
    @State private var showingPlanTrace = false
    @State private var rooms: [RoomEntry] = []
    @State private var captureTargetID: UUID?
    @State private var renameTargetID: UUID?
    @State private var renameText = ""
    @State private var showingRename = false
    @State private var showingDeletePlan = false
    @State private var showingConvertScan = false
    @State private var showingEstimate = false
    @State private var showingPlanning = false
    @State private var plan: FloorPlanModel?
    @State private var planSource: String?
    @State private var hasManualRoom = false
    @State private var estimateInputs: EstimateInputs?
    @State private var planningChecklist: PlanningChecklist?
    @State private var exportURL: URL?
    @State private var showingReportPreview = false
    @State private var exportPreview: ExportPreview?
    @State private var permitURL: URL?
    @State private var showingPermitPreview = false
    @State private var isExporting = false
    @State private var isExportingPermit = false
    @State private var isBackingUp = false
    @State private var exportError: String?

    // Cached in reloadScan() so body doesn't hit the disk on every keystroke
    // (QA-025).
    @State private var cachedScanURL: URL?
    @State private var hasLiDARData = false
    @State private var downloadingFromCloud = false
    // The USDZ actually shared for the 3D model, resolved when the preview
    // is opened (QA-032).

    // Dashboard restructure: consolidated entry points (Add Room chooser and
    // Export hub) plus quote figures cached in reloadScan() so the body stays
    // off the disk on every keystroke (QA-025).
    @State private var showingAddRoom = false
    @State private var pendingAddRoom: AddRoomChoice?
    @State private var showingExportHub = false
    @State private var pendingExport: ExportAction?
    @State private var showingEditDetails = false
    @State private var cachedQuoteTotal: Double?
    @State private var hasPricedQuote = false

    private enum AddRoomChoice { case lidar, corner, trace, manual }
    private enum ExportAction { case pdf, permit, image, dxf, model, backup }

    /// The single most useful thing to do next, driven by cached state.
    /// How this project type steers the dashboard (card order, suite
    /// compliance visibility, AI framing).
    private var typeProfile: ProjectTypeProfile {
        ProjectTypeProfile.profile(for: project.projectType)
    }

    private enum NextStep { case addRoom, priceQuote, shareReport }
    private var nextStep: NextStep {
        if plan == nil && rooms.isEmpty { return .addRoom }
        if !rooms.isEmpty && !hasPricedQuote { return .priceQuote }
        return .shareReport
    }

    /// Distinct storey names in room order; floor headers only appear when
    /// the project actually spans more than one.
    private var floorNames: [String] {
        var names: [String] = []
        for entry in rooms where !names.contains(entry.floorDisplayName) {
            names.append(entry.floorDisplayName)
        }
        return names
    }

    private var hasMultipleFloors: Bool { floorNames.count > 1 }

    /// The project's existing floors first, then common presets — so the
    /// Move-to-Floor menu can re-file into an existing storey or start a
    /// new one.
    private var floorChoices: [String] {
        var choices = floorNames
        for preset in [RoomEntry.defaultFloorName, "Basement", "Second Floor", "Garage"]
            where !choices.contains(preset) {
            choices.append(preset)
        }
        return choices
    }

    private var estimateResult: EstimateResult? {
        guard let estimateInputs else { return nil }
        return EstimateCalculator.calculate(inputs: estimateInputs,
                                            planAreaSquareMeters: plan?.approxFloorAreaSquareMeters)
    }

    // MARK: - Dashboard cards

    /// Read-only client/property summary + status, with an Edit button that
    /// opens the details sheet (where the TextFields now live, so the always-
    /// visible body no longer does per-keystroke work).
    private var headerCard: some View {
        DashboardCard(title: "Project", systemImage: "house") {
            VStack(alignment: .leading, spacing: 8) {
                if !project.clientName.isEmpty {
                    infoRow("Client", project.clientName)
                }
                if !project.address.isEmpty {
                    infoRow("Address", project.address)
                }
                if !project.projectType.isEmpty {
                    infoRow("Type", project.projectType)
                }
                infoRow("Estimate", project.estimateStatus)
                infoRow("Permit", project.permitStatus)
                infoRow("Created", project.createdAt.formatted(date: .abbreviated, time: .omitted))
                if let scanDate = project.scanDate {
                    infoRow("Scanned", scanDate.formatted(date: .abbreviated, time: .shortened))
                }
                Button {
                    showingEditDetails = true
                } label: {
                    Label("Edit details", systemImage: "pencil")
                }
                .padding(.top, 4)
                .accessibilityHint("Edit client, property, type, and status")
            }
        }
    }

    /// A prominent card pointing at the single best next action.
    @ViewBuilder
    private var nextStepCard: some View {
        switch nextStep {
        case .addRoom:
            PromptCard(title: "Add your first room",
                       message: "Scan, capture, trace, or type a room to start the plan.",
                       systemImage: "plus.viewfinder",
                       actionTitle: "Add a Room") {
                showingAddRoom = true
            }
        case .priceQuote:
            NavigationLink {
                TakeoffDestination(rooms: rooms, project: project)
            } label: {
                PromptCardLabel(title: "Price your quote",
                                message: "Set prices on the material takeoff to build the client quote.",
                                systemImage: "list.clipboard",
                                actionTitle: "Open Quote")
            }
            .buttonStyle(.plain)
        case .shareReport:
            PromptCard(title: "Share the client report",
                       message: "Export a PDF, permit package, drawings, or the 3D model.",
                       systemImage: "square.and.arrow.up",
                       actionTitle: "Export & Share") {
                showingExportHub = true
            }
        }
    }

    /// PLAN: floor plan, 3D model, the rooms list (with its per-room menu),
    /// the single Add-Room entry, plus convert/delete plan actions.
    private var planCard: some View {
        DashboardCard(title: "Plan & Rooms", systemImage: "map") {
            VStack(alignment: .leading, spacing: 10) {
                if let plan {
                    navRow(title: "Floor Plan", systemImage: "map",
                           detail: planSource) {
                        FloorPlanScreen(plan: plan, project: project)
                    }
                }
                if cachedScanURL != nil {
                    buttonRow(title: "View 3D Model", systemImage: "cube") {
                        showingModelViewer = true
                    }
                }

                if !rooms.isEmpty {
                    Divider()
                    if hasMultipleFloors {
                        ForEach(floorNames, id: \.self) { floor in
                            Text(floor)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                            ForEach(rooms.filter { $0.floorDisplayName == floor }) { entry in
                                roomRow(entry)
                            }
                        }
                    } else {
                        ForEach(rooms) { entry in
                            roomRow(entry)
                        }
                    }
                    if rooms.count > 1 {
                        Text("Rooms are shown together on the floor plan; use the ⋯ menu to rename, recapture, or delete a room.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Use the ⋯ menu to rename, recapture, or delete the room.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                }

                buttonRow(title: rooms.isEmpty ? "Add a Room" : "Add Another Room",
                          systemImage: "plus.viewfinder") {
                    showingAddRoom = true
                }
                if hasLiDARData {
                    buttonRow(title: "Convert Scan to Editable Plan",
                              systemImage: "wand.and.stars") {
                        showingConvertScan = true
                    }
                }
                if hasManualRoom {
                    buttonRow(title: "Convert Manual Plan to Editable Room",
                              systemImage: "wand.and.stars") {
                        convertManualPlan()
                    }
                }
                if plan != nil {
                    buttonRow(title: "Delete Floor Plan…",
                              systemImage: "trash",
                              role: .destructive) {
                        showingDeletePlan = true
                    }
                }
            }
        }
    }

    /// QUOTE: material takeoff, AI review, quick estimate, and the current
    /// quote grand total (cached in reloadScan per the CONTRACT formula).
    private var quoteCard: some View {
        DashboardCard(title: "Quote & Estimate", systemImage: "dollarsign.circle") {
            VStack(alignment: .leading, spacing: 10) {
                if let total = cachedQuoteTotal {
                    infoRow("Quote total", Money.format(total))
                }
                if !rooms.isEmpty, plan != nil {
                    navRow(title: "Material Takeoff / Quote", systemImage: "list.clipboard") {
                        // The takeoff is computed in the destination's own body
                        // so it doesn't run on every parent body eval (QA-025).
                        TakeoffDestination(rooms: rooms, project: project)
                    }
                    navRow(title: "AI Quote Review", systemImage: "sparkles") {
                        QuoteAdvisorScreen(project: project)
                    }
                } else if hasLiDARData {
                    Text("The takeoff uses captured or traced rooms. Add rooms to itemize materials. Direct LiDAR-scan takeoff is coming.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Capture or trace a room to generate a material takeoff.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                // Always visible: the screen itself walks the user through
                // whatever is missing (rooms, prices, Apple Intelligence),
                // which beats an invisible feature.
                navRow(title: "AI Price Analysis (On-Device)", systemImage: "wand.and.sparkles") {
                    PriceAnalysisScreen(project: project)
                }
                if let result = estimateResult {
                    infoRow("Rough range", result.rangeText)
                }
                buttonRow(title: estimateInputs == nil ? "Set Up Quick Estimate" : "Edit Quick Estimate",
                          systemImage: "dollarsign.circle") {
                    showingEstimate = true
                }
            }
        }
    }

    /// COMPLIANCE & PERMIT: suite compliance, permit measurements, planning.
    private var complianceCard: some View {
        DashboardCard(title: "Compliance & Permit", systemImage: "checkmark.shield") {
            VStack(alignment: .leading, spacing: 10) {
                // Suite-code compliance only applies when the job creates or
                // legalizes a dwelling unit (basement dev, legal suite,
                // multi-family) — hidden for flips/renos/exterior work.
                if typeProfile.isSuiteProject, plan != nil || !rooms.isEmpty {
                    navRow(title: "Suite Compliance", systemImage: "checkmark.shield") {
                        // Evaluation runs in the destination's own body rather
                        // than on every parent body eval (QA-025).
                        ComplianceDestination(rooms: rooms,
                                              planAreaSquareMeters: plan?.approxFloorAreaSquareMeters,
                                              planning: planningChecklist,
                                              estimate: estimateInputs)
                    }
                }
                navRow(title: "Permit Measurements", systemImage: "ruler") {
                    PermitMeasurementsScreen(project: project, onSave: reloadScan)
                }
                if let planningChecklist, planningChecklist.plannedCount > 0 {
                    infoRow("Planned items",
                            "\(planningChecklist.plannedCount) of \(planningChecklist.items.count)")
                }
                buttonRow(title: planningChecklist == nil ? "Start Renovation Planning" : "Edit Renovation Planning",
                          systemImage: "checklist") {
                    showingPlanning = true
                }
            }
        }
    }

    /// INVESTMENT: the simple contractor-facing Suite ROI & Payback.
    private var investmentCard: some View {
        DashboardCard(title: "Investment", systemImage: "chart.line.uptrend.xyaxis") {
            VStack(alignment: .leading, spacing: 10) {
                navRow(title: "Suite ROI & Payback",
                       systemImage: "chart.line.uptrend.xyaxis") {
                    ROIScreen(project: project,
                              estimateMidpoint: estimateResult.map { ($0.totalLow + $0.totalHigh) / 2 })
                }
            }
        }
    }

    /// PHOTOS & NOTES: the existing PhotoSection plus the notes editor.
    private var photosNotesCard: some View {
        DashboardCard(title: "Photos & Notes", systemImage: "photo.on.rectangle") {
            VStack(alignment: .leading, spacing: 12) {
                PhotoSection(project: project)
                Divider()
                Text("Notes")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $project.notes)
                    .frame(minHeight: 120)
                    .padding(8)
                    .background(Color(.tertiarySystemFill),
                                in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    /// EXPORT & SHARE: a single entry to the export hub, replacing the six
    /// scattered export buttons.
    private var exportCard: some View {
        DashboardCard(title: "Export & Share", systemImage: "square.and.arrow.up") {
            VStack(alignment: .leading, spacing: 8) {
                if isExporting {
                    ProgressView("Creating PDF…")
                } else if isExportingPermit {
                    ProgressView("Creating Permit Package…")
                } else if isBackingUp {
                    ProgressView("Backing Up…")
                }
                buttonRow(title: "Export & Share…", systemImage: "square.and.arrow.up") {
                    showingExportHub = true
                }
                .accessibilityHint("PDF report, permit package, floor plan image, CAD file, 3D model, or a project backup")
            }
        }
    }

    // MARK: - Card row helpers

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func navRow<Destination: View>(title: String,
                                           systemImage: String,
                                           detail: String? = nil,
                                           @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func buttonRow(title: String,
                           systemImage: String,
                           role: ButtonRole? = nil,
                           action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if downloadingFromCloud {
                    Label("Downloading project files from iCloud… Content fills in as it arrives.",
                          systemImage: "icloud.and.arrow.down")
                        .font(.footnote.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.blue)
                }
                headerCard
                nextStepCard
                planCard
                // The type decides which card carries the job's centre of
                // gravity: suites lead with compliance, flips with the deal,
                // renovations with the quote. Nothing is removed — only
                // reordered.
                switch typeProfile.emphasis {
                case .compliance:
                    complianceCard
                    quoteCard
                    investmentCard
                case .investment:
                    investmentCard
                    quoteCard
                    complianceCard
                case .plan, .quote:
                    quoteCard
                    complianceCard
                    investmentCard
                }
                photosNotesCard
                exportCard
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            // Cap the content to a readable width so it doesn't stretch
            // edge-to-edge on iPad / landscape; a no-op on narrower iPhone
            // screens.
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(project.name)
        .keyboardDoneButton()
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingEditDetails, onDismiss: reloadScan) {
            EditDetailsSheet(project: project)
        }
        .sheet(isPresented: $showingAddRoom, onDismiss: presentPendingAddRoom) {
            AddRoomSheet(
                onLiDAR: { pendingAddRoom = .lidar },
                onCorner: { pendingAddRoom = .corner },
                onTrace: { pendingAddRoom = .trace },
                onManual: { pendingAddRoom = .manual })
        }
        .sheet(isPresented: $showingExportHub, onDismiss: runPendingExport) {
            ExportHubScreen(
                hasPlan: plan != nil,
                hasModel: cachedScanURL != nil,
                onPDFReport: { pendingExport = .pdf },
                onPermitPackage: { pendingExport = .permit },
                onFloorPlanImage: { pendingExport = .image },
                onCADFile: { pendingExport = .dxf },
                onModel: { pendingExport = .model },
                onBackup: { pendingExport = .backup })
        }
        .fullScreenCover(isPresented: $showingScanner, onDismiss: reloadScan) {
            ScanScreen(project: project)
        }
        .fullScreenCover(isPresented: $showingCornerCapture, onDismiss: {
            captureTargetID = nil
            reloadScan()
        }) {
            CornerCaptureScreen(project: project, targetRoomID: captureTargetID)
        }
        .confirmationDialog("Convert Scan", isPresented: $showingConvertScan, titleVisibility: .visible) {
            Button("Convert to Editable Plan") { convertScanToRoom() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Turns the LiDAR scan into an editable room: every wall length, the ceiling height, and each door and window carry over with their measured sizes, and all drawing and correction tools unlock. The 3D scan model is kept.")
        }
        .sheet(isPresented: $showingReportPreview) {
            if let exportURL {
                PDFPreviewSheet(url: exportURL)
            }
        }
        .sheet(isPresented: $showingPermitPreview) {
            if let permitURL {
                PDFPreviewSheet(url: permitURL)
            }
        }
        // One item-driven sheet for every file preview: presenting with
        // `isPresented` plus a separately stored URL can build the sheet
        // against stale state and show an empty panel.
        .sheet(item: $exportPreview) { preview in
            switch preview {
            case .image(let url):
                ExportPreviewSheet(title: "Floor Plan Image", url: url) {
                    if let image = UIImage(contentsOfFile: url.path) {
                        ZStack {
                            Color.white
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .padding()
                        }
                    } else {
                        ContentUnavailableView("Preview Unavailable", systemImage: "photo")
                    }
                }
            case .dxf(let url):
                ExportPreviewSheet(title: "CAD File (DXF)", url: url) {
                    VStack(spacing: 12) {
                        if let plan {
                            FloorPlanCanvas(plan: plan,
                                            useImperial: useImperial,
                                            markers: ScanStore.loadMarkers(for: project)?.markers ?? [],
                                            layers: PlanLayers(),
                                            exportBackground: true)
                                .padding()
                                .background(Color.white)
                        }
                        Text("This is the geometry the CAD file contains. Walls, doors, windows, fixtures, dimensions, and labels export on separate layers (DXF R12, millimetres).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .padding(.vertical)
                }
            case .backup(let url):
                ExportPreviewSheet(title: "Project Backup", url: url) {
                    VStack(spacing: 14) {
                        Image(systemName: "externaldrive.badge.timemachine")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text(project.name)
                            .font(.headline)
                        VStack(spacing: 4) {
                            Text("Everything in this project: rooms, floor plan, estimate, planning, compliance inputs, markers, and \(project.photoFileNames.count) photo\(project.photoFileNames.count == 1 ? "" : "s").")
                            Text("Save it to Files or iCloud Drive, or AirDrop it to another device. Import from the dashboard's ⋯ menu.")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    }
                    .padding()
                }
            case .model(let url):
                ExportPreviewSheet(title: "3D Model (USDZ)", url: url) {
                    if let scene = Model3DBuilder.viewerScene(for: project, useImperial: useImperial) {
                        Interactive3DView(scene: scene)
                    } else {
                        ContentUnavailableView("No 3D Model", systemImage: "cube")
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showingPlanTrace, onDismiss: {
            captureTargetID = nil
            reloadScan()
        }) {
            PlanTraceScreen(project: project, targetRoomID: captureTargetID, onSave: reloadScan)
        }
        .fullScreenCover(isPresented: $showingModelViewer) {
            Model3DScreen(project: project)
        }
        .sheet(isPresented: $showingManualEntry, onDismiss: reloadScan) {
            NavigationStack {
                ManualRoomEntryScreen(project: project, onSave: reloadScan)
            }
        }
        .sheet(isPresented: $showingEstimate, onDismiss: reloadScan) {
            NavigationStack {
                EstimateScreen(project: project,
                               planAreaSquareMeters: plan?.approxFloorAreaSquareMeters,
                               onSave: reloadScan)
            }
        }
        .sheet(isPresented: $showingPlanning, onDismiss: reloadScan) {
            NavigationStack {
                PlanningScreen(project: project,
                               areaSquareMeters: plan?.approxFloorAreaSquareMeters,
                               ceilingMeters: plan?.ceilingHeightMeters,
                               estimate: estimateInputs,
                               onSave: reloadScan)
            }
        }
        .alert("Something Went Wrong", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .alert("Rename Room", isPresented: $showingRename) {
            TextField("Name", text: $renameText)
            Button("Save") { applyRename() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete Floor Plan",
                            isPresented: $showingDeletePlan,
                            titleVisibility: .visible) {
            if hasLiDARData {
                Button("Delete LiDAR Scan", role: .destructive) { deleteLiDARScan() }
            }
            if !rooms.isEmpty {
                Button(rooms.count > 1 ? "Delete All \(rooms.count) Rooms" : "Delete Captured Room",
                       role: .destructive) { deleteAllRooms() }
            }
            if hasManualRoom {
                Button("Delete Manual Measurements", role: .destructive) { deleteManualRoom() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Photos, notes, estimate, and planning are kept. This can't be undone.")
        }
        .onAppear(perform: reloadScan)
        // While files are downloading from iCloud, re-check once a second
        // and reload when they land — otherwise the banner (and the empty
        // content behind it) would sit frozen until the user re-entered
        // the project.
        .task(id: downloadingFromCloud) {
            guard downloadingFromCloud else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if !ScanStore.hasUndownloadedFiles(for: project) {
                    reloadScan()
                    break
                }
            }
        }
    }

    /// Turns the hand-entered measurements into a captured-style room so
    /// the full drawing toolset applies; the manual file is retired.
    private func convertManualPlan() {
        guard let manual = ScanStore.loadManualRoom(for: project),
              let converted = CornerRoom(manual: manual) else {
            exportError = "The manual measurements couldn't be converted. Check the room's width and length."
            return
        }
        var updated = rooms
        updated.append(RoomEntry(name: "Room \(updated.count + 1)",
                                 room: converted.placedAlongside(updated)))
        do {
            try ScanStore.saveRooms(updated, for: project)
            ScanStore.removeFile(named: ScanStore.manualRoomFileName, for: project)
            let dir = try ScanStore.folder(for: project)
            Model3DBuilder.writeUSDZInBackground(rooms: updated.map(\.room),
                                          to: dir.appendingPathComponent(ScanStore.usdzFileName))
            reloadScan()
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func deleteLiDARScan() {
        ScanStore.removeFile(named: ScanStore.roomDataFileName, for: project)
        ScanStore.removeFile(named: ScanStore.lidarUSDZFileName, for: project)
        cleanUpAfterPlanDelete()
    }

    private func deleteAllRooms() {
        try? ScanStore.saveRooms([], for: project)
        // The legacy single-room file would otherwise re-migrate if
        // rooms.json ever went missing.
        ScanStore.removeFile(named: ScanStore.cornerRoomFileName, for: project)
        cleanUpAfterPlanDelete()
    }

    private func deleteManualRoom() {
        ScanStore.removeFile(named: ScanStore.manualRoomFileName, for: project)
        cleanUpAfterPlanDelete()
    }

    /// After a plan source is deleted: rebuild or remove the 3D model,
    /// clear the scan date when no capture remains, and drop markers once
    /// no plan is left for them to sit on.
    private func cleanUpAfterPlanDelete() {
        let remainingRooms = ScanStore.loadRooms(for: project)
        let hasLiDAR = ScanStore.roomDataURL(for: project) != nil
        if let dir = try? ScanStore.folder(for: project) {
            let usdzURL = dir.appendingPathComponent(ScanStore.usdzFileName)
            if hasLiDAR {
                // The LiDAR export still owns the model — leave it.
            } else if !remainingRooms.isEmpty {
                Model3DBuilder.writeUSDZInBackground(rooms: remainingRooms.map(\.room), to: usdzURL)
            } else {
                // Supersede any pending background write so a late write can't
                // resurrect the just-deleted model (QA-036).
                Model3DBuilder.cancelUSDZWrite(to: usdzURL)
                // Coordinated delete also removes an undownloaded
                // placeholder — a raw removeItem would no-op on it and the
                // deleted model would re-sync everywhere.
                ScanStore.coordinatedDelete(at: usdzURL)
            }
        }
        if !hasLiDAR, remainingRooms.isEmpty {
            project.scanDate = nil
            try? modelContext.save()
            if ScanStore.loadManualRoom(for: project) == nil {
                ScanStore.removeFile(named: ScanStore.markersFileName, for: project)
            }
        }
        reloadScan()
    }

    private func applyRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        guard let id = renameTargetID,
              let index = rooms.firstIndex(where: { $0.id == id }),
              !trimmed.isEmpty else { return }
        rooms[index].name = trimmed
        try? ScanStore.saveRooms(rooms, for: project)
    }

    private func roomRow(_ entry: RoomEntry) -> some View {
        HStack {
            Label(entry.name, systemImage: "square.dashed")
            Spacer()
            Text(Measure.area(entry.room.floorAreaSquareMeters, imperial: useImperial))
                .foregroundStyle(.secondary)
            // Visible handle for the same actions as the
            // context menu, so deleting one scan doesn't rely
            // on a hidden gesture.
            Menu {
                roomRowActions(entry)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("\(entry.name) actions")
            .accessibilityHint("Rename, recapture, or delete this room")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.name), \(Measure.area(entry.room.floorAreaSquareMeters, imperial: useImperial))")
        .contextMenu {
            roomRowActions(entry)
        }
    }

    @ViewBuilder
    private func roomRowActions(_ entry: RoomEntry) -> some View {
        Button {
            renameTargetID = entry.id
            renameText = entry.name
            showingRename = true
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
        if ARWorldTrackingConfiguration.isSupported {
            Button {
                captureTargetID = entry.id
                showingCornerCapture = true
            } label: {
                Label("Recapture with Camera", systemImage: "camera.viewfinder")
            }
        }
        Button {
            captureTargetID = entry.id
            showingPlanTrace = true
        } label: {
            Label("Retrace from Photo / PDF", systemImage: "doc.viewfinder")
        }
        Menu {
            ForEach(floorChoices, id: \.self) { floor in
                Button {
                    moveRoom(entry.id, toFloor: floor)
                } label: {
                    if entry.floorDisplayName == floor {
                        Label(floor, systemImage: "checkmark")
                    } else {
                        Text(floor)
                    }
                }
            }
        } label: {
            Label("Move to Floor…", systemImage: "square.3.stack.3d")
        }
        Button(role: .destructive) {
            deleteRoom(entry.id)
        } label: {
            Label("Delete Room", systemImage: "trash")
        }
    }

    private func moveRoom(_ id: UUID, toFloor floor: String) {
        guard let index = rooms.firstIndex(where: { $0.id == id }) else { return }
        // nil keeps the room on the legacy default floor, so a project moved
        // back to a single storey reads like a pre-floors file.
        rooms[index].floorName = floor == RoomEntry.defaultFloorName ? nil : floor
        try? ScanStore.saveRooms(rooms, for: project)
    }

    private func deleteRoom(_ id: UUID) {
        var updated = rooms
        updated.removeAll { $0.id == id }
        try? ScanStore.saveRooms(updated, for: project)
        // Route through the shared cleanup so removing the last room also
        // clears scanDate, the "Captured" badge, and the markers file
        // instead of leaving them stale (QA-035); it also rebuilds or removes
        // the USDZ (cancelling any in-flight write first — QA-036).
        cleanUpAfterPlanDelete()
    }

    private func convertScanToRoom() {
        guard let captured = ScanStore.loadCapturedRoom(for: project) else {
            exportError = "This scan's saved data couldn't be read. Rescan the room and try again."
            return
        }
        guard let converted = ScanConverter.convert(captured) else {
            exportError = "Couldn't build a clean outline from this scan. Try rescanning with a slower walk-through."
            return
        }
        do {
            var current = ScanStore.loadRooms(for: project)
            current.append(RoomEntry(name: "Scanned Room \(current.count + 1)",
                                     room: converted.placedAlongside(current)))
            try ScanStore.saveRooms(current, for: project)
            // The editable rooms own the plan now; the LiDAR USDZ stays for
            // 3D viewing and sharing.
            if let url = ScanStore.roomDataURL(for: project) {
                try? FileManager.default.removeItem(at: url)
            }
            reloadScan()
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func reloadScan() {
        // Surface files that exist in iCloud but haven't landed here yet
        // (also kicks their download) — otherwise a syncing project renders
        // as empty and invites edits that clobber the real data.
        downloadingFromCloud = ScanStore.hasUndownloadedFiles(for: project)
        let manual = ScanStore.loadManualRoom(for: project)
        hasManualRoom = manual != nil
        rooms = ScanStore.loadRooms(for: project)
        estimateInputs = ScanStore.loadEstimate(for: project)
        planningChecklist = ScanStore.loadPlanning(for: project)
        if let room = ScanStore.loadCapturedRoom(for: project),
           let scanPlan = FloorPlanModel(room: room) {
            plan = scanPlan
            planSource = "LiDAR scan"
        } else if !rooms.isEmpty, let mergedPlan = FloorPlanModel(rooms: rooms.map(\.room)) {
            plan = mergedPlan
            planSource = rooms.count > 1 ? "\(rooms.count) rooms (camera / trace)" : "Camera capture / trace"
        } else if let manual, let manualPlan = FloorPlanModel(manual: manual) {
            plan = manualPlan
            planSource = "Manual entry"
        } else {
            plan = nil
            planSource = nil
        }
        // Cache disk-backed lookups so body reads stay off the disk (QA-025).
        hasLiDARData = ScanStore.roomDataURL(for: project) != nil
        cachedScanURL = ScanStore.lidarUSDZURL(for: project) ?? ScanStore.usdzURL(for: project)
        // Cache the quote grand total and "is anything priced" flag here too,
        // so the dashboard's Quote card and next-step prompt don't recompute
        // the takeoff or hit the disk on every Notes keystroke (QA-025).
        if rooms.isEmpty {
            cachedQuoteTotal = nil
            hasPricedQuote = false
        } else {
            let adjustments = ScanStore.loadTakeoffAdjustments(for: project) ?? TakeoffAdjustments()
            let takeoff = MaterialTakeoff.calculate(rooms: rooms.map(\.room))
            let settings = ScanStore.loadQuoteSettings(for: project)
            cachedQuoteTotal = QuoteTotals(subtotal: adjustments.total(for: takeoff),
                                           settings: settings).grandTotal
            // Priced = at least one included line carries an entered price.
            hasPricedQuote = adjustments.prices.contains { key, _ in
                !adjustments.excludedKeys.contains(key)
            }
        }
    }

    // MARK: - Consolidated entry-point handlers

    /// Presents the capture flow chosen in the Add-Room chooser, after that
    /// sheet has fully dismissed — so a fullScreenCover isn't raised while a
    /// sheet is still animating away. Drives the SAME existing state.
    private func presentPendingAddRoom() {
        switch pendingAddRoom {
        case .lidar:
            showingScanner = true
        case .corner:
            captureTargetID = nil
            showingCornerCapture = true
        case .trace:
            captureTargetID = nil
            showingPlanTrace = true
        case .manual:
            showingManualEntry = true
        case .none:
            break
        }
        pendingAddRoom = nil
    }

    /// Runs the export chosen in the Export hub, after that sheet has fully
    /// dismissed — so each export's own preview sheet can present on the
    /// dashboard. Invokes the SAME existing export functions/state.
    private func runPendingExport() {
        switch pendingExport {
        case .pdf:
            export()
        case .permit:
            exportPermitPackage()
        case .image:
            exportPlanImage()
        case .dxf:
            exportDXF()
        case .model:
            // Resolve the file to share now, so it matches the previewed
            // scene (QA-032).
            if let url = sharableModelURL() {
                exportPreview = .model(url)
            } else {
                exportError = "There is no 3D model to share yet."
            }
        case .backup:
            exportBackup()
        case .none:
            break
        }
        pendingExport = nil
    }

    @MainActor
    private func exportPlanImage() {
        guard let plan else { return }
        let markers = ScanStore.loadMarkers(for: project)?.markers ?? []
        // Room-label centroids live in traced-room space; on a LiDAR plan
        // (ARKit world space) they would land at arbitrary positions.
        let isLiDARPlan = ScanStore.roomDataURL(for: project) != nil
        let labels: [(name: String, area: String, center: CGPoint)] = isLiDARPlan ? [] : rooms.compactMap { entry in
            guard entry.room.corners.count >= 3 else { return nil }
            let count = Double(entry.room.corners.count)
            return (entry.name,
                    Measure.area(entry.room.floorAreaSquareMeters, imperial: useImperial),
                    CGPoint(x: entry.room.corners.map(\.x).reduce(0, +) / count,
                            y: entry.room.corners.map(\.z).reduce(0, +) / count))
        }
        let renderer = ImageRenderer(content:
            FloorPlanCanvas(plan: plan, useImperial: useImperial, markers: markers,
                            roomLabels: labels, layers: PlanLayers(), exportBackground: true)
                .frame(width: 800, height: 800)
                .background(Color.white)
                .environment(\.colorScheme, .light)
        )
        renderer.scale = 2
        guard let image = renderer.uiImage, let data = image.pngData() else {
            exportError = "Could not create the floor plan image."
            return
        }
        let safeName = project.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName) - Floor Plan.png")
        do {
            try data.write(to: url)
            exportPreview = .image(url)
        } catch {
            exportError = "Could not save the floor plan image."
        }
    }

    private func exportPermitPackage() {
        guard !isExportingPermit else { return }
        isExportingPermit = true
        permitURL = nil
        // Generate off the main thread so the UI stays responsive and photo
        // memory isn't held on the main actor (QA-033). A background
        // SwiftData context resolves the project so its properties aren't
        // read across threads. Prices/exclusions (QA-008) and all-on layers
        // (QA-031) are passed explicitly.
        let container = modelContext.container
        let id = project.persistentModelID
        let plan = plan
        let estimate = estimateInputs
        let planning = planningChecklist
        let imperial = useImperial
        Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let url: URL? = (context.model(for: id) as? RenovationProject).flatMap { bgProject in
                let adjustments = ScanStore.loadTakeoffAdjustments(for: bgProject) ?? TakeoffAdjustments()
                return PDFExporter.makePermitPackage(for: bgProject,
                                                     plan: plan,
                                                     estimate: estimate,
                                                     planning: planning,
                                                     useImperial: imperial,
                                                     takeoffAdjustments: adjustments,
                                                     layers: PlanLayers())
            }
            await MainActor.run {
                if let url {
                    permitURL = url
                    showingPermitPreview = true
                } else {
                    exportError = "Could not create the permit package."
                }
                isExportingPermit = false
            }
        }
    }

    private func exportBackup() {
        guard !isBackingUp else { return }
        isBackingUp = true
        // Serialize the whole project folder off the main thread (QA-034); a
        // background SwiftData context resolves the project so its properties
        // aren't read across threads.
        let container = modelContext.container
        let id = project.persistentModelID
        Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            guard let bgProject = context.model(for: id) as? RenovationProject else {
                await MainActor.run {
                    exportError = "Could not back up this project."
                    isBackingUp = false
                }
                return
            }
            do {
                let url = try ProjectBackup.export(bgProject)
                await MainActor.run {
                    exportPreview = .backup(url)
                    isBackingUp = false
                }
            } catch {
                await MainActor.run {
                    exportError = error.localizedDescription
                    isBackingUp = false
                }
            }
        }
    }

    private func exportDXF() {
        guard let plan else { return }
        let reportMarkers = ScanStore.loadMarkers(for: project)?.markers ?? []
        // Room-label centroids live in traced-room space; on a LiDAR plan
        // (ARKit world space) they land at arbitrary coordinates, so drop
        // them — mirroring the PDF/image guard (QA-029).
        let isLiDARPlan = ScanStore.roomDataURL(for: project) != nil
        let dxf = DXFExporter.make(plan: plan, rooms: isLiDARPlan ? [] : rooms,
                                   markers: reportMarkers, useImperial: useImperial)
        let safeName = project.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName) - Floor Plan.dxf")
        // R12 DXF is an ASCII format; user-typed labels degrade lossily
        // rather than failing the export.
        guard let data = dxf.data(using: .ascii, allowLossyConversion: true) else {
            exportError = "Could not create the CAD file."
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            exportPreview = .dxf(url)
        } catch {
            exportError = "Could not save the CAD file."
        }
    }

    private func export() {
        guard !isExporting else { return }
        isExporting = true
        exportURL = nil
        // Generate off the main thread (QA-033); a background SwiftData
        // context resolves the project so its properties aren't read across
        // threads. Takeoff prices/exclusions (QA-008) and all-on layers
        // (QA-031) are passed explicitly.
        let container = modelContext.container
        let id = project.persistentModelID
        let plan = plan
        let estimate = estimateInputs
        let planning = planningChecklist
        let imperial = useImperial
        Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let url: URL? = (context.model(for: id) as? RenovationProject).flatMap { bgProject in
                let adjustments = ScanStore.loadTakeoffAdjustments(for: bgProject) ?? TakeoffAdjustments()
                return PDFExporter.makeReport(for: bgProject,
                                              plan: plan,
                                              estimate: estimate,
                                              planning: planning,
                                              useImperial: imperial,
                                              takeoffAdjustments: adjustments,
                                              layers: PlanLayers())
            }
            await MainActor.run {
                if let url {
                    exportURL = url
                    showingReportPreview = true
                } else {
                    exportError = "Could not create the PDF report."
                }
                isExporting = false
            }
        }
    }

    /// The USDZ to actually share for the 3D model. When editable rooms own
    /// the plan, share their generated model (matching the previewed scene),
    /// regenerating it in place if the on-disk copy is missing or older than
    /// the rooms — rather than a stale lidar_scan.usdz (QA-032).
    private func sharableModelURL() -> URL? {
        guard !rooms.isEmpty, let dir = try? ScanStore.folder(for: project) else {
            return ScanStore.lidarUSDZURL(for: project) ?? ScanStore.usdzURL(for: project)
        }
        let fm = FileManager.default
        let usdzURL = dir.appendingPathComponent(ScanStore.usdzFileName)
        let roomsURL = dir.appendingPathComponent(ScanStore.roomsFileName)
        let usdzDate = (try? fm.attributesOfItem(atPath: usdzURL.path))?[.modificationDate] as? Date
        let roomsDate = (try? fm.attributesOfItem(atPath: roomsURL.path))?[.modificationDate] as? Date
        let stale = !fm.fileExists(atPath: usdzURL.path)
            || (usdzDate.flatMap { u in roomsDate.map { u < $0 } } ?? false)
        if stale {
            try? Model3DBuilder.writeUSDZ(rooms: rooms.map(\.room), to: usdzURL)
        }
        return fm.fileExists(atPath: usdzURL.path)
            ? usdzURL
            : (ScanStore.lidarUSDZURL(for: project) ?? ScanStore.usdzURL(for: project))
    }
}

/// Builds the material takeoff in its own body so the calculation doesn't
/// run on every ProjectDetailView body eval — only when navigated to
/// (QA-025).
/// A generated file waiting in its preview sheet. Identified by path so
/// re-exporting the same file re-presents the sheet.
private enum ExportPreview: Identifiable {
    case image(URL), dxf(URL), backup(URL), model(URL)

    var id: String {
        switch self {
        case .image(let url): "image:\(url.path)"
        case .dxf(let url): "dxf:\(url.path)"
        case .backup(let url): "backup:\(url.path)"
        case .model(let url): "model:\(url.path)"
        }
    }
}

private struct TakeoffDestination: View {
    let rooms: [RoomEntry]
    let project: RenovationProject

    var body: some View {
        MaterialTakeoffScreen(takeoff: MaterialTakeoff.calculate(rooms: rooms.map(\.room)),
                              project: project)
    }
}

/// Evaluates suite compliance in its own body, deferring the work off the
/// parent's per-keystroke body eval (QA-025).
private struct ComplianceDestination: View {
    let rooms: [RoomEntry]
    let planAreaSquareMeters: Double?
    let planning: PlanningChecklist?
    let estimate: EstimateInputs?

    var body: some View {
        ComplianceScreen(compliance: SuiteCompliance.evaluate(
            rooms: rooms,
            planAreaSquareMeters: planAreaSquareMeters,
            planning: planning,
            estimate: estimate))
    }
}

/// A titled container that gives each dashboard section its "card" look while
/// keeping the app's Label/semantic-font idioms.
private struct DashboardCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16))
    }
}

/// The shared look of the prominent next-step prompt, so the button and the
/// NavigationLink variants render identically.
private struct PromptCardLabel: View {
    let title: String
    let message: String
    let systemImage: String
    let actionTitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title)
                .foregroundStyle(.white)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                Text(actionTitle)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.white, in: Capsule())
                    .foregroundStyle(.tint)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.accentColor.gradient,
                    in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message)")
        .accessibilityHint(actionTitle)
    }
}

/// A tappable prompt card driven by an action closure.
private struct PromptCard: View {
    let title: String
    let message: String
    let systemImage: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PromptCardLabel(title: title,
                            message: message,
                            systemImage: systemImage,
                            actionTitle: actionTitle)
        }
        .buttonStyle(.plain)
    }
}

/// The client & property fields, moved out of the always-visible dashboard so
/// editing them no longer does per-keystroke work in the main body. Status
/// pickers live here too so status stays editable off the read-only header.
private struct EditDetailsSheet: View {
    @Bindable var project: RenovationProject
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Client & Property") {
                    TextField("Project name", text: $project.name)
                    TextField("Client name", text: $project.clientName)
                    TextField("Property address", text: $project.address)
                    TextField("Postal / ZIP code", text: $project.postalCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Phone", text: $project.phone)
                        .keyboardType(.phonePad)
                    TextField("Email", text: $project.email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                    Picker("Type", selection: $project.projectType) {
                        ForEach(RenovationProject.projectTypes, id: \.self) { Text($0) }
                        // Projects saved before a type was in the list keep it.
                        if !RenovationProject.projectTypes.contains(project.projectType) {
                            Text(project.projectType).tag(project.projectType)
                        }
                    }
                }

                Section("Status") {
                    Picker("Estimate status", selection: $project.estimateStatus) {
                        ForEach(RenovationProject.estimateStatuses, id: \.self) { Text($0) }
                    }
                    Picker("Permit status", selection: $project.permitStatus) {
                        ForEach(RenovationProject.permitStatuses, id: \.self) { Text($0) }
                    }
                }
            }
            .navigationTitle("Edit Details")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
