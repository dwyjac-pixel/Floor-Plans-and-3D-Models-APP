#if canImport(UIKit)
import os
import SceneKit
import SwiftUI

/// What the preview is drawn from: one room of one saved revision.
struct FinishedPreviewSource {
    let room: CornerRoom
    let roomName: String
    let revisionTitle: String
    let savedAt: Date?

    static var sample: FinishedPreviewSource {
        FinishedPreviewSource(room: PreviewReferenceRoom.bathroom(), roomName: PreviewReferenceRoom.name,
                              revisionTitle: "Sample drawing", savedAt: nil)
    }
}

/// Timings read on the device itself, so the smoothness claims can be
/// checked on a named iPhone or iPad without extra tools. Shown by
/// tapping the picture three times.
struct PreviewReadout: Equatable {
    var buildSeconds: Double?
    var prepareSeconds: Double?
    var swapMilliseconds: Double?
    var swaps = 0
    var glideFrames = 0
    var glideWorstMilliseconds: Double?
    var glideSlowFrames = 0

    var lines: [String] {
        var lines: [String] = []
        if let buildSeconds, let prepareSeconds {
            lines.append(String(format: "Load %.2f s build, %.2f s prepare", buildSeconds, prepareSeconds))
        }
        if let swapMilliseconds { lines.append(String(format: "Swap %.0f ms (%d so far)", swapMilliseconds, swaps)) }
        if let glideWorstMilliseconds {
            lines.append(String(format: "Glide %d frames, worst %.0f ms, %d over 33 ms",
                                glideFrames, glideWorstMilliseconds, glideSlowFrames))
        }
        return lines.isEmpty ? ["No timings yet"] : lines
    }
}

@MainActor
final class FinishedPreviewModel: ObservableObject {
    enum Phase { case loading, ready, blocked }

    let source: FinishedPreviewSource
    let layout: PreviewLayout
    @Published private(set) var phase: Phase
    @Published private(set) var room: PreviewRoomScene?
    @Published private(set) var selection = PreviewFinish.Selection()
    @Published private(set) var stop: PreviewCamera.Kind = .doorway
    @Published private(set) var readout = PreviewReadout()
    @Published var stageOpacity = 1.0

    let timing = PreviewFrameTiming()
    private let signposter = OSSignposter(subsystem: "com.caribinalcreations.scanner", category: "FinishedPreview")
    private let logger = Logger(subsystem: "com.caribinalcreations.scanner", category: "FinishedPreview")
    private var prepareStarted: CFTimeInterval = 0

    init(source: FinishedPreviewSource) {
        self.source = source
        layout = PreviewLayout(room: source.room)
        phase = layout.problems.isEmpty ? .loading : .blocked
    }

    var stops: [PreviewCamera.Stop] { room?.stops ?? [] }
    var lookName: String { selection.overrides.isEmpty ? selection.look.name : "\(selection.look.name), customised" }

    /// Builds the room and both looks' materials off the main thread. The
    /// picture stays covered until the view reports everything is ready.
    func load() async {
        guard phase == .loading, room == nil else { return }
        let layout = layout
        let started = CACurrentMediaTime()
        let built = await Task.detached(priority: .userInitiated) { () -> PreviewRoomScene in
            let library = PreviewFinishLibrary()
            let room = PreviewRoomScene(layout: layout, library: library)
            _ = library.materials(for: PreviewFinish.looks.map { PreviewFinish.Selection(lookID: $0.id) })
            return room
        }.value
        readout.buildSeconds = CACurrentMediaTime() - started
        prepareStarted = CACurrentMediaTime()
        if let first = built.stops.first { stop = first.kind }
        room = built
    }

    /// Everything the view should upload before the room is shown: the
    /// scene and the materials of every look, so the first swap after the
    /// room appears is as quick as any other.
    var warmUpObjects: [Any] {
        guard let room else { return [] }
        return [room.scene] + room.library.materials(for: PreviewFinish.looks.map { PreviewFinish.Selection(lookID: $0.id) })
    }

    func didPrepare() {
        guard phase == .loading else { return }
        readout.prepareSeconds = CACurrentMediaTime() - prepareStarted
        phase = .ready
        logger.info("Preview ready: build \(self.readout.buildSeconds ?? 0, format: .fixed(precision: 2)) s, prepare \(self.readout.prepareSeconds ?? 0, format: .fixed(precision: 2)) s")
    }

    // MARK: Finishes

    func choose(look: PreviewFinish.Look) { show(PreviewFinish.Selection(lookID: look.id)) }

    func choose(_ finish: PreviewFinish.Finish) {
        var next = selection
        if selection.look.finishes[finish.slot] == finish.id {
            next.overrides[finish.slot] = nil
        } else {
            next.overrides[finish.slot] = finish.id
        }
        show(next)
    }

    /// Swaps materials and times the change from the tap to the first
    /// frame that shows it.
    private func show(_ next: PreviewFinish.Selection) {
        guard phase == .ready, let room, next != selection else { return }
        let state = signposter.beginInterval("FinishSwap")
        timing.beginSwap { [weak self] milliseconds in
            guard let self else { return }
            self.signposter.endInterval("FinishSwap", state)
            self.readout.swapMilliseconds = milliseconds
            self.readout.swaps += 1
            self.logger.info("Finish swap \(milliseconds, format: .fixed(precision: 1)) ms")
        }
        selection = next
        room.apply(next)
    }

    // MARK: Camera

    func go(to kind: PreviewCamera.Kind) {
        guard phase == .ready, let room, kind != stop,
              let target = room.stops.first(where: { $0.kind == kind }) else { return }
        let from = room.currentStop
        stop = kind
        if let from, PreviewCamera.glideIsClear(from: from, to: target, in: layout) {
            let duration = 1.4
            timing.beginGlide()
            room.place(at: target, duration: duration)
            Task {
                try? await Task.sleep(for: .seconds(duration + 0.15))
                let result = timing.endGlide()
                readout.glideFrames = result.frames
                readout.glideWorstMilliseconds = result.worst
                readout.glideSlowFrames = result.slow
                logger.info("Glide \(result.frames) frames, worst \(result.worst, format: .fixed(precision: 1)) ms, \(result.slow) over 33 ms")
            }
        } else {
            // No clear path (or a change of lens): fade through, never fly through a wall.
            Task {
                withAnimation(.easeIn(duration: 0.14)) { stageOpacity = 0 }
                try? await Task.sleep(for: .seconds(0.15))
                room.place(at: target)
                withAnimation(.easeOut(duration: 0.2)) { stageOpacity = 1 }
            }
        }
    }

    // MARK: Pictures

    struct Picture: Identifiable {
        let id = UUID()
        let title: String
        let image: UIImage
        let url: URL
    }

    private func captionLines(look: String, useImperial: Bool) -> [String] {
        PreviewCaption.lines(revisionTitle: source.revisionTitle, savedAt: source.savedAt, roomName: source.roomName,
                             look: look, layout: layout, useImperial: useImperial)
    }

    private func write(_ image: CGImage, named name: String) -> Picture? {
        guard let data = PreviewStill.png(image) else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FinishedPreview", isDirectory: true)
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("\(safe.prefix(90)).png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return Picture(title: name, image: UIImage(cgImage: image), url: url)
        } catch {
            return nil
        }
    }

    /// A captioned still of what is on screen now.
    func picture(useImperial: Bool) -> Picture? {
        guard phase == .ready, let room, let stop = room.currentStop,
              let shot = PreviewStill.render(room, from: stop, width: 1440),
              let final = PreviewStill.captioned(shot, lines: captionLines(look: lookName, useImperial: useImperial)) else { return nil }
        return write(final, named: "\(source.roomName) \(lookName) \(stop.kind.title)")
    }

    /// The same view in every curated look. Camera, lens, exposure and
    /// lights are identical; only the finishes differ.
    func comparison(useImperial: Bool) -> [Picture] {
        guard phase == .ready, let room, let stop = room.currentStop else { return [] }
        let shown = selection
        defer { room.apply(shown) }
        return PreviewFinish.looks.compactMap { look in
            room.apply(PreviewFinish.Selection(lookID: look.id))
            guard let shot = PreviewStill.render(room, from: stop, width: 1440),
                  let final = PreviewStill.captioned(shot, lines: captionLines(look: look.name, useImperial: useImperial)) else { return nil }
            return write(final, named: "\(source.roomName) \(look.name) \(stop.kind.title)")
        }
    }
}

/// Frame and swap timing gathered on the render thread.
final class PreviewFrameTiming: NSObject, SCNSceneRendererDelegate {
    private struct State {
        var swapStarted: CFTimeInterval?
        var swapDone: ((Double) -> Void)?
        var glideStamps: [CFTimeInterval]?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func beginSwap(_ done: @escaping @MainActor (Double) -> Void) {
        state.withLock {
            $0.swapStarted = CACurrentMediaTime()
            $0.swapDone = { milliseconds in Task { @MainActor in done(milliseconds) } }
        }
    }

    func beginGlide() { state.withLock { $0.glideStamps = [] } }

    func endGlide() -> (frames: Int, worst: Double, slow: Int) {
        let stamps = state.withLock { state -> [CFTimeInterval] in
            defer { state.glideStamps = nil }
            return state.glideStamps ?? []
        }
        let gaps = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }
        return (stamps.count, gaps.max() ?? 0, gaps.filter { $0 > 33.4 }.count)
    }

    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        let now = CACurrentMediaTime()
        let finished = state.withLock { state -> (Double, ((Double) -> Void)?)? in
            state.glideStamps?.append(now)
            guard let started = state.swapStarted else { return nil }
            defer {
                state.swapStarted = nil
                state.swapDone = nil
            }
            return ((now - started) * 1000, state.swapDone)
        }
        if let finished { finished.1?(finished.0) }
    }
}

private struct PreviewSceneView: UIViewRepresentable {
    @ObservedObject var model: FinishedPreviewModel

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero, options: nil)
        view.backgroundColor = UIColor(red: 0.15, green: 0.16, blue: 0.17, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.isJitteringEnabled = true
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = false
        view.isUserInteractionEnabled = false
        view.delegate = model.timing
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        guard let room = model.room, view.scene !== room.scene else { return }
        view.scene = room.scene
        view.pointOfView = room.cameraNode
        let model = model
        view.prepare(model.warmUpObjects) { _ in
            Task { @MainActor in model.didPrepare() }
        }
    }
}

/// Preview Renovation: the finished room, drawn on the device from one
/// room of a saved revision.
struct FinishedPreviewScreen: View {
    @StateObject private var model: FinishedPreviewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("useImperialUnits") private var useImperial = true
    @State private var shared: FinishedPreviewModel.Picture?
    @State private var compared: [FinishedPreviewModel.Picture] = []
    @State private var showingComparison = false
    @State private var working = false
    @State private var pictureFailed = false
    @State private var showingReadout = false

    init(source: FinishedPreviewSource) {
        _model = StateObject(wrappedValue: FinishedPreviewModel(source: source))
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.phase == .blocked {
                    blocked
                } else {
                    GeometryReader { proxy in
                        if proxy.size.width > proxy.size.height {
                            HStack(spacing: 0) {
                                stage.frame(maxHeight: .infinity).background(Color.black)
                                controls.frame(width: min(380, proxy.size.width * 0.4))
                            }
                        } else {
                            VStack(spacing: 0) {
                                stage
                                controls
                            }
                        }
                    }
                }
            }
            .navigationTitle("Preview Renovation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Share This Picture", systemImage: "photo") { sharePicture() }
                        Button("Compare Looks", systemImage: "rectangle.split.2x1") { compareLooks() }
                    } label: {
                        if working { ProgressView() } else { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                    .disabled(model.phase != .ready || working)
                }
            }
        }
        .task { await model.load() }
        .sheet(item: $shared) { picture in
            ExportPreviewSheet(title: "Finished Preview", url: picture.url) {
                Image(uiImage: picture.image).resizable().scaledToFit().padding()
                    .accessibilityLabel(picture.title)
            }
        }
        .sheet(isPresented: $showingComparison) { PreviewComparisonSheet(pictures: compared) }
        .alert("Could Not Make the Picture", isPresented: $pictureFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: Picture

    private var stage: some View {
        ZStack {
            Color(red: 0.15, green: 0.16, blue: 0.17)
            PreviewSceneView(model: model)
                .opacity(model.phase == .ready ? model.stageOpacity : 0)
                .accessibilityElement()
                .accessibilityLabel("Finished preview of \(model.source.roomName), \(model.lookName), \(model.stop.title) view")
            if model.phase == .loading {
                ProgressView("Preparing both looks")
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .aspectRatio(PreviewCamera.aspect, contentMode: .fit)
        .overlay(alignment: .bottomLeading) {
            Text("Illustration from the drawing")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(8)
                .opacity(model.phase == .ready ? 1 : 0)
        }
        .overlay(alignment: .topTrailing) {
            if showingReadout {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.readout.lines, id: \.self) { Text($0) }
                }
                .font(.caption2.monospacedDigit())
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 3) { showingReadout.toggle() }
    }

    // MARK: Controls

    private var controls: some View {
        Form {
            if model.stops.count > 1 {
                Section("View") {
                    Picker("View", selection: Binding(get: { model.stop }, set: { model.go(to: $0) })) {
                        ForEach(model.stops, id: \.kind) { Text($0.kind.title).tag($0.kind) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            Section("Look") {
                Picker("Look", selection: Binding(get: { model.selection.lookID }, set: { id in
                    if let look = PreviewFinish.looks.first(where: { $0.id == id }) { model.choose(look: look) }
                })) {
                    ForEach(PreviewFinish.looks) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Section("Finishes") {
                ForEach(PreviewFinish.Slot.choices, id: \.self) { slot in
                    let current = model.selection.resolved[slot]
                    Picker(slot.title, selection: Binding(get: { current ?? "" }, set: { id in
                        if let finish = PreviewFinish.finish(id) { model.choose(finish) }
                    })) {
                        ForEach(PreviewFinish.finishes(for: slot)) { Text($0.name).tag($0.id) }
                    }
                }
            }
            Section {
                if let assumed = PreviewCaption.assumptionText(model.layout.assumptions) {
                    Label(assumed, systemImage: "ruler")
                }
                Label("Drawn on this device from \(model.source.revisionTitle). Finishes are representative. Confirm colours and products from samples.",
                      systemImage: "info.circle")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .disabled(model.phase != .ready)
    }

    private var blocked: some View {
        ContentUnavailableView {
            Label("Not Ready to Preview", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 8) {
                Text("The picture has to match the drawing, so these need fixing in the floor plan first. Then save a new proposed revision.")
                ForEach(Array(model.layout.problems.enumerated()), id: \.offset) { _, problem in
                    Text(PreviewCaption.problemText(problem, useImperial: useImperial))
                }
            }
        }
    }

    // MARK: Actions

    private func sharePicture() {
        working = true
        Task {
            await Task.yield()
            if let picture = model.picture(useImperial: useImperial) { shared = picture } else { pictureFailed = true }
            working = false
        }
    }

    private func compareLooks() {
        working = true
        Task {
            await Task.yield()
            compared = model.comparison(useImperial: useImperial)
            if compared.count == PreviewFinish.looks.count { showingComparison = true } else { pictureFailed = true }
            working = false
        }
    }
}

/// Every curated look from the same camera, one above the other.
private struct PreviewComparisonSheet: View {
    let pictures: [FinishedPreviewModel.Picture]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    ForEach(pictures) { picture in
                        VStack(spacing: 8) {
                            Image(uiImage: picture.image).resizable().scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .accessibilityLabel(picture.title)
                            ShareLink(item: picture.url) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .accessibilityLabel("Share \(picture.title)")
                        }
                    }
                    Text("Same camera, lens and lighting in each picture. Only the finishes differ.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Compare Looks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
#endif
