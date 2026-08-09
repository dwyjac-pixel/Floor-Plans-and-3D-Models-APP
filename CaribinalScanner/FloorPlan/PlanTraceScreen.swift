import SwiftUI
import PhotosUI
import PDFKit

/// Digitize a paper plan: import a photo or PDF, calibrate the scale by
/// tapping both ends of one known dimension, then tap the room corners in
/// order. Produces a CornerRoom — same pipeline as a camera capture.
struct PlanTraceScreen: View {
    let project: RenovationProject
    /// Room to retrace in place; nil adds a new room to the project.
    var targetRoomID: UUID? = nil
    var onSave: () -> Void

    private enum Step {
        case pick, scaleA, scaleB, trace
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage("useImperialUnits") private var useImperial = true

    @State private var step: Step = .pick
    @State private var image: UIImage?
    @State private var pickerItem: PhotosPickerItem?
    @State private var showingFileImporter = false
    @State private var scalePointA: CGPoint?
    @State private var scalePointB: CGPoint?
    @State private var knownDistance: Double = 3.0
    @State private var showingDistanceSheet = false
    @State private var metersPerPixel: Double = 0
    @State private var corners: [CGPoint] = []       // image pixel space
    @State private var detectedDimensions: [DimensionOCR.DetectedDimension] = []
    @State private var aiSuggestion: DimensionOCR.DetectedDimension?
    @State private var planAnalysis = PlanVision.Analysis()
    @State private var showingFinishSheet = false
    @State private var ceilingMeters: Double = 2.4
    @State private var squareUpWalls = true
    @State private var saveError: String?
    @State private var pendingSelfIntersectWarning = false

    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var offsetBase: CGSize = .zero

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    traceArea(image: image)
                } else {
                    pickArea
                }
            }
            .navigationTitle("Trace a Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if step == .trace {
                        HStack {
                            Button("Undo") {
                                if !corners.isEmpty { corners.removeLast() }
                            }
                            .disabled(corners.isEmpty)
                            .accessibilityHint("Removes the last placed corner")
                            Button("Finish") { showingFinishSheet = true }
                                .disabled(corners.count < 3)
                                .accessibilityHint("Closes the outline and sets the ceiling height")
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if step == .trace, corners.isEmpty, !planAnalysis.outlineProposal.isEmpty {
                        HStack(spacing: 10) {
                            Button {
                                corners = planAnalysis.outlineProposal
                            } label: {
                                Label("Use AI Outline (\(planAnalysis.outlineProposal.count) corners)",
                                      systemImage: "wand.and.stars")
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Ignore") {
                                planAnalysis.outlineProposal = []
                            }
                            .buttonStyle(.bordered)
                        }
                        .font(.footnote)
                    }
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(.thinMaterial)
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let loaded = UIImage(data: data) {
                    image = loaded
                    step = .scaleA
                }
                pickerItem = nil
            }
        }
        .onChange(of: image) { _, newImage in
            detectedDimensions = []
            aiSuggestion = nil
            planAnalysis = PlanVision.Analysis()
            guard let newImage else { return }
            DimensionOCR.recognize(in: newImage) { found in
                detectedDimensions = found
            }
            PlanVision.analyze(newImage) { analysis in
                planAnalysis = analysis
            }
        }
        .fileImporter(isPresented: $showingFileImporter,
                      allowedContentTypes: [.pdf, .image]) { result in
            if case .success(let url) = result {
                loadFile(url)
            }
        }
        .sheet(isPresented: $showingDistanceSheet) { distanceSheet }
        .sheet(isPresented: $showingFinishSheet) { finishSheet }
        .alert("Could Not Save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private var hint: String {
        switch step {
        case .pick:
            return "Import a photo or PDF of the floor plan."
        case .scaleA:
            return detectedDimensions.isEmpty
                ? "Set the scale: tap ONE end of a dimension you know (zoom in for precision)."
                : "AI read \(detectedDimensions.count) dimension labels (green boxes). Tap ONE end of a labelled wall — the length fills in automatically."
        case .scaleB:
            return "Now tap the OTHER end of that known dimension."
        case .trace:
            return "Tap each room corner in order around the room (\(corners.count) placed). The last wall closes automatically."
        }
    }

    private var pickArea: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("Import Photo", systemImage: "photo")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Choose a photo of the floor plan from your library")
            Button {
                showingFileImporter = true
            } label: {
                Label("Import PDF or File", systemImage: "doc")
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Choose a PDF or image file of the floor plan")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func traceArea(image: UIImage) -> some View {
        GeometryReader { geo in
            let fit = fitInfo(image: image, in: geo.size)
            ZStack {
                Color(white: 0.92)
                Image(uiImage: image)
                    .resizable()
                    .frame(width: fit.size.width, height: fit.size.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                overlayCanvas(fit: fit, in: geo.size)
            }
            .scaleEffect(zoom)
            .offset(offset)
            .contentShape(Rectangle())
            .clipped()
            .onTapGesture { location in
                handleTap(location, size: geo.size, fit: fit)
            }
            .gesture(
                SimultaneousGesture(
                    MagnificationGesture()
                        .onChanged { zoom = min(max(zoomBase * $0, 1), 10) }
                        .onEnded { _ in zoomBase = zoom },
                    DragGesture()
                        .onChanged { offset = CGSize(width: offsetBase.width + $0.translation.width,
                                                     height: offsetBase.height + $0.translation.height) }
                        .onEnded { _ in offsetBase = offset }
                )
            )
        }
    }

    private func overlayCanvas(fit: (size: CGSize, origin: CGPoint, scale: CGFloat), in size: CGSize) -> some View {
        Canvas { context, _ in
            func viewPoint(_ pixel: CGPoint) -> CGPoint {
                CGPoint(x: fit.origin.x + pixel.x * fit.scale,
                        y: fit.origin.y + pixel.y * fit.scale)
            }
            func dot(_ pixel: CGPoint, color: Color) {
                let p = viewPoint(pixel)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)),
                             with: .color(color))
            }
            // Dimension labels the AI recognized, while setting the scale.
            if step == .scaleA || step == .scaleB {
                for dimension in detectedDimensions {
                    let origin = viewPoint(dimension.rect.origin)
                    let rect = CGRect(x: origin.x - 2, y: origin.y - 2,
                                      width: dimension.rect.width * fit.scale + 4,
                                      height: dimension.rect.height * fit.scale + 4)
                    context.stroke(Path(roundedRect: rect, cornerRadius: 3),
                                   with: .color(.green.opacity(0.85)), lineWidth: 1.3)
                }
            }
            if let a = scalePointA { dot(a, color: .blue) }
            if let b = scalePointB { dot(b, color: .blue) }
            if let a = scalePointA, let b = scalePointB {
                var line = Path()
                line.move(to: viewPoint(a))
                line.addLine(to: viewPoint(b))
                context.stroke(line, with: .color(.blue), lineWidth: 2)
            }
            // The AI's proposed outline, until tracing starts.
            if step == .trace, corners.isEmpty, planAnalysis.outlineProposal.count >= 3 {
                var proposal = Path()
                proposal.move(to: viewPoint(planAnalysis.outlineProposal[0]))
                for point in planAnalysis.outlineProposal.dropFirst() {
                    proposal.addLine(to: viewPoint(point))
                }
                proposal.closeSubpath()
                context.stroke(proposal, with: .color(.purple),
                               style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                for point in planAnalysis.outlineProposal { dot(point, color: .purple) }
            }
            if corners.count >= 2 {
                var path = Path()
                path.move(to: viewPoint(corners[0]))
                for corner in corners.dropFirst() {
                    path.addLine(to: viewPoint(corner))
                }
                context.stroke(path, with: .color(.orange), lineWidth: 2)
            }
            for corner in corners { dot(corner, color: .orange) }
        }
        .allowsHitTesting(false)
    }

    private func fitInfo(image: UIImage, in size: CGSize) -> (size: CGSize, origin: CGPoint, scale: CGFloat) {
        let scale = min(size.width / image.size.width, size.height / image.size.height)
        let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2)
        return (fitted, origin, scale)
    }

    private func handleTap(_ location: CGPoint, size: CGSize,
                           fit: (size: CGSize, origin: CGPoint, scale: CGFloat)) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let content = CGPoint(x: (location.x - offset.width - center.x) / zoom + center.x,
                              y: (location.y - offset.height - center.y) / zoom + center.y)
        let pixel = CGPoint(x: (content.x - fit.origin.x) / fit.scale,
                            y: (content.y - fit.origin.y) / fit.scale)
        switch step {
        case .pick:
            break
        case .scaleA:
            scalePointA = pixel
            step = .scaleB
        case .scaleB:
            scalePointB = pixel
            aiSuggestion = bestDimension(nearTo: scalePointA ?? pixel, pixel)
            if let aiSuggestion {
                knownDistance = aiSuggestion.meters
            }
            showingDistanceSheet = true
        case .trace:
            corners.append(snapToDetectedCorner(pixel, fit: fit))
        }
    }

    /// Magnetize a trace tap to the nearest corner the AI found in the
    /// drawing's line work — within a fingertip radius at current zoom.
    private func snapToDetectedCorner(_ pixel: CGPoint,
                                      fit: (size: CGSize, origin: CGPoint, scale: CGFloat)) -> CGPoint {
        let radius = 16 / (fit.scale * zoom)
        var best: (point: CGPoint, distance: CGFloat)?
        for candidate in planAnalysis.cornerCandidates {
            let distance = hypot(candidate.x - pixel.x, candidate.y - pixel.y)
            if distance < radius, distance < (best?.distance ?? .infinity) {
                best = (candidate, distance)
            }
        }
        if let best {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return best.point
        }
        return pixel
    }

    /// The recognized dimension label nearest the two scale points.
    private func bestDimension(nearTo a: CGPoint, _ b: CGPoint) -> DimensionOCR.DetectedDimension? {
        guard let image else { return nil }
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let limit = max(image.size.width, image.size.height) * 0.12
        var best: (dimension: DimensionOCR.DetectedDimension, distance: CGFloat)?
        for dimension in detectedDimensions {
            let center = CGPoint(x: dimension.rect.midX, y: dimension.rect.midY)
            let distance = hypot(center.x - mid.x, center.y - mid.y)
            if distance < limit, distance < (best?.distance ?? .infinity) {
                best = (dimension, distance)
            }
        }
        return best?.dimension
    }

    private var distanceSheet: some View {
        NavigationStack {
            Form {
                Section {
                    if let aiSuggestion {
                        LabeledContent("AI read nearby") {
                            Text(aiSuggestion.text)
                                .bold()
                                .foregroundStyle(.green)
                        }
                    }
                    DimensionRow(label: "Real-world distance", meters: $knownDistance, imperial: useImperial)
                } footer: {
                    Text(aiSuggestion != nil
                         ? "Auto-filled from the drawing's dimension text — adjust it if the AI grabbed the wrong label."
                         : "The actual distance between the two blue points — read it off the drawing's dimension text.")
                }
            }
            .navigationTitle("Set Scale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Redo Points") {
                        scalePointA = nil
                        scalePointB = nil
                        aiSuggestion = nil
                        showingDistanceSheet = false
                        step = .scaleA
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") {
                        guard let a = scalePointA, let b = scalePointB else { return }
                        let pixels = hypot(b.x - a.x, b.y - a.y)
                        guard pixels > 4, knownDistance > 0.05 else { return }
                        metersPerPixel = knownDistance / Double(pixels)
                        showingDistanceSheet = false
                        step = .trace
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }

    private var finishSheet: some View {
        NavigationStack {
            Form {
                Section {
                    DimensionRow(label: "Ceiling height", meters: $ceilingMeters, imperial: useImperial)
                    Toggle("Square up walls", isOn: $squareUpWalls)
                    LabeledContent("Corners traced", value: "\(corners.count)")
                }
            }
            .navigationTitle("Finish Trace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { showingFinishSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .alert("Walls Cross Themselves", isPresented: $pendingSelfIntersectWarning) {
                Button("Save Anyway") { save(force: true) }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("The traced corners make an outline whose walls cross over each other, which under-reports the floor area. Retrace the corners in order around the room, or save anyway if this is intentional.")
            }
        }
        .presentationDetents([.medium])
    }

    private func loadFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return }
            let rect = page.bounds(for: .mediaBox)
            let renderScale = 2400 / max(rect.width, rect.height)
            let size = CGSize(width: rect.width * renderScale, height: rect.height * renderScale)
            let renderer = UIGraphicsImageRenderer(size: size)
            image = renderer.image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                context.cgContext.translateBy(x: 0, y: size.height)
                context.cgContext.scaleBy(x: renderScale, y: -renderScale)
                page.draw(with: .mediaBox, to: context.cgContext)
            }
            step = .scaleA
        } else if let data = try? Data(contentsOf: url), let loaded = UIImage(data: data) {
            image = loaded
            step = .scaleA
        }
    }

    private func save(force: Bool = false) {
        guard metersPerPixel > 0, corners.count >= 3 else { return }
        var points = corners.map {
            CornerRoom.Point(x: Double($0.x) * metersPerPixel, z: Double($0.y) * metersPerPixel)
        }
        if squareUpWalls {
            points = RoomSquarer.squared(points)
        }
        let traced = CornerRoom(corners: points, ceilingHeightMeters: ceilingMeters)
        // A bow-tie / figure-8 outline under-reports its floor area; warn
        // before saving unless the user has confirmed.
        if !force, traced.isSelfIntersecting {
            pendingSelfIntersectWarning = true
            return
        }
        do {
            var rooms = ScanStore.loadRooms(for: project)
            if let targetRoomID, let index = rooms.firstIndex(where: { $0.id == targetRoomID }) {
                rooms[index].room = traced.placedOver(rooms[index].room)
            } else {
                rooms.append(RoomEntry(name: "Room \(rooms.count + 1)",
                                       room: traced.placedAlongside(rooms)))
            }
            try ScanStore.saveRooms(rooms, for: project)
            let dir = try ScanStore.folder(for: project)
            Model3DBuilder.writeUSDZInBackground(rooms: rooms.map(\.room),
                                         to: dir.appendingPathComponent(ScanStore.usdzFileName))
            if let source = image, let data = source.jpegData(compressionQuality: 0.8),
               let name = try? ScanStore.addPhoto(data, to: project) {
                project.photoFileNames.append(name)
            }
            project.scanDate = .now
            try? modelContext.save()
            showingFinishSheet = false
            onSave()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
