#if canImport(UIKit)
import SceneKit
import SwiftUI

struct ReferenceFloorScreen: View {
    var kitchen = PreviewReferenceKitchen.room()
    var savedRooms: [RoomEntry]?
    var finishKey = "walkthrough.sample"
    var store = PreviewChoiceStore.sample
    var revisionTitle: String?
    var savedAt: Date?
    @Environment(\.dismiss) private var dismiss
    @State private var floor: (any FloorWalkthroughScene)?
    @State private var selectedRoom = ""
    @State private var floorID = ""
    @State private var paintID = ""
    @State private var leg = 0
    @State private var pose: PreviewReferenceFloor.Pose?
    @State private var walking = false
    @State private var paused = false
    @State private var lookYaw = 0.0
    @State private var lookPitch = 0.0
    @State private var zoom = 0.0
    @State private var dragDelta = CGSize.zero
    @State private var pinchScale = 1.0
    @State private var unavailable = false
    @State private var walkTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                // On a wide screen the picture stands beside the controls
                // and takes the full height. Stacked there, it would be a
                // small picture between two wide black bars.
                let wide = proxy.size.width > proxy.size.height
                let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    if let floor {
                        ReferenceFloorView(floor: floor)
                            .overlay {
                                Color.clear.contentShape(Rectangle())
                                    .gesture(DragGesture().onChanged { gesture in
                                        guard !walking || paused else { return }
                                        lookYaw -= (gesture.translation.width - dragDelta.width) * 0.34
                                        lookPitch = min(60, max(-60, lookPitch + (gesture.translation.height - dragDelta.height) * 0.34))
                                        dragDelta = gesture.translation
                                        displayPose(floor)
                                    }.onEnded { _ in dragDelta = .zero })
                                    .simultaneousGesture(MagnifyGesture().onChanged { gesture in
                                        guard !walking || paused else { return }
                                        zoom = min(60, max(-55, zoom - log(gesture.magnification / pinchScale) * 52))
                                        pinchScale = gesture.magnification
                                        displayPose(floor)
                                    }.onEnded { _ in pinchScale = 1 })
                                    .accessibilityHidden(true)
                            }
                            .accessibilityLabel(savedRooms == nil ? "Sample floor walkthrough" : "Floor walkthrough")
                            // The lens is built for a 4:3 picture. Any other
                            // shape would stretch the room, so the picture
                            // keeps its shape and the rest is letterboxed.
                            .aspectRatio(PreviewCamera.aspect, contentMode: .fit)
                            .overlay(alignment: .bottomLeading) {
                                Text(savedRooms == nil ? "Sample floor" : "Illustration from the drawing")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .padding(8)
                            }
                            .frame(maxWidth: .infinity, maxHeight: wide ? .infinity : nil)
                            .frame(height: wide ? nil : min(proxy.size.height * 0.53, proxy.size.width / PreviewCamera.aspect))
                            .background(Color.black, ignoresSafeAreaEdges: [])
                        Form {
                            Section("Walkthrough") {
                                if walking {
                                    Button(paused ? "Resume Walkthrough" : "Pause Walkthrough",
                                           systemImage: paused ? "play" : "pause") { paused.toggle() }
                                } else {
                                    Button(leg == floor.walkthroughLegs.count ? "Replay Floor Tour" : "Walk to \(floor.walkthroughLegs[leg].room.name)",
                                       systemImage: "figure.walk") {
                                        walkTask = Task { await walk(floor) }
                                    }
                                }
                                if !walking || paused {
                                    Button("Wide View", systemImage: "arrow.up.left.and.arrow.down.right") {
                                        lookYaw = 0
                                        lookPitch = 0
                                        zoom = 34
                                        displayPose(floor)
                                    }
                                    Button("Zoom Out", systemImage: "minus.magnifyingglass") {
                                        zoom = min(60, zoom + 15)
                                        displayPose(floor)
                                    }
                                    Button("Look Left", systemImage: "arrow.left") {
                                        lookYaw -= 25
                                        displayPose(floor)
                                    }
                                    Button("Look Right", systemImage: "arrow.right") {
                                        lookYaw += 25
                                        displayPose(floor)
                                    }
                                }
                                Text(paused ? "Paused" : walking ? "Walking…" : (floor.walkthroughRooms.first { $0.id == selectedRoom }?.name ?? ""))
                            }
                            Section("Room Finishes") {
                                Picker("Room", selection: $selectedRoom) {
                                    ForEach(floor.walkthroughRooms) { room in
                                        Text(room.name).tag(room.id)
                                    }
                                }
                                Picker("Floor", selection: $floorID) {
                                    ForEach(PreviewFinish.finishes(for: .floor)) { Text($0.name).tag($0.id) }
                                }
                                Picker("Wall Paint", selection: $paintID) {
                                    ForEach(PreviewFinish.finishes(for: .wall)) { Text($0.name).tag($0.id) }
                                }
                            }
                            .disabled(walking)
                            if let message = floor.connectionMessage {
                                Section("Check Doorways") { Text(message) }
                            }
                            Section {
                                Text("Drag to look around and pinch to zoom while stopped or paused.")
                            }
                            Section {
                                if savedRooms == nil {
                                    Label("Sample floor. Not a drawing of this project. Rooms and furniture are placeholders.",
                                          systemImage: "info.circle")
                                } else {
                                    if let assumed = PreviewCaption.assumptionText(floor.assumptions) {
                                        Label(assumed, systemImage: "ruler")
                                    }
                                    if floor.assumptions.contains(where: { if case .genericFixture = $0 { true } else { false } }) {
                                        Label("Plain blocks mark items that are not yet detailed.", systemImage: "cube")
                                    }
                                    Label("Drawn on this device from \(drawingName). Finishes are representative. Confirm colours and products from samples.",
                                          systemImage: "info.circle")
                                }
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        .frame(width: wide ? min(380, proxy.size.width * 0.4) : nil)
                    } else if unavailable {
                        ContentUnavailableView("Floor Preview Unavailable", systemImage: "house",
                            description: Text("A walkthrough needs valid room outlines and matching doors or cased openings. Confirm them in Edit Proposed Layout, then save a new revision."))
                    } else {
                        ProgressView("Preparing floor")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .navigationTitle(savedRooms == nil ? "Sample Floor Walkthrough" : "Floor Walkthrough")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .task {
                guard floor == nil else { return }
                let drawing = kitchen
                let entries = savedRooms?.map { (id: $0.id, name: $0.name, room: $0.room) }
                let saved = store.value([String: String].self, for: finishKey) ?? [:]
                // The floor is built in the finishes it was left in, with
                // its first reflections, before it is shown. Drawing a
                // finish for the first time is slow and belongs off the
                // main thread with the rest of the build.
                let loaded = await Task.detached(priority: .userInitiated) { () -> (any FloorWalkthroughScene)? in
                    let made: (any FloorWalkthroughScene)? = if let entries { SavedFloorWalkthrough(entries: entries) }
                        else { PreviewReferenceFloor(kitchen: drawing) }
                    guard let made else { return nil }
                    for room in made.walkthroughRooms {
                        for slot in [PreviewFinish.Slot.floor, .wall] {
                            if let id = saved["\(room.id).\(slot.rawValue)"],
                               let finish = PreviewFinish.finish(id), finish.slot == slot {
                                made.change(finish, roomID: room.id)
                            }
                        }
                    }
                    made.refreshMirrors(at: made.entrance)
                    return made
                }.value
                guard !Task.isCancelled else { return }
                floor = loaded
                unavailable = loaded == nil
                pose = loaded?.entrance
                selectedRoom = loaded?.walkthroughRooms.first?.id ?? ""
                refreshFinishes()
            }
            .onDisappear { walkTask?.cancel() }
            .onChange(of: selectedRoom) { _, _ in refreshFinishes() }
            .onChange(of: floorID) { _, id in changeFinish(id) }
            .onChange(of: paintID) { _, id in changeFinish(id) }
        }
    }

    private func changeFinish(_ id: String) {
        guard let finish = PreviewFinish.finish(id), let floor,
              floor.finishID(finish.slot, roomID: selectedRoom) != id else { return }
        floor.change(finish, roomID: selectedRoom)
        if let pose { floor.refreshMirrors(at: pose) }
        var saved = store.value([String: String].self, for: finishKey) ?? [:]
        saved["\(selectedRoom).\(finish.slot.rawValue)"] = id
        store.set(saved, for: finishKey)
    }

    /// The revision the floor is drawn from, as it is named on a still.
    private var drawingName: String {
        guard let revisionTitle else { return "the saved drawing" }
        guard let savedAt else { return revisionTitle }
        return "\(revisionTitle), saved \(savedAt.formatted(date: .abbreviated, time: .omitted))"
    }

    private func refreshFinishes() {
        guard let floor else { return }
        floorID = floor.finishID(.floor, roomID: selectedRoom) ?? ""
        paintID = floor.finishID(.wall, roomID: selectedRoom) ?? ""
    }

    private func displayPose(_ floor: any FloorWalkthroughScene) {
        guard let pose else { return }
        floor.placeCamera(.init(x: pose.x, z: pose.z, heading: pose.heading + lookYaw,
                          pitch: min(72, max(-72, pose.pitch + lookPitch)),
                          fov: min(112, max(32, pose.fov + zoom)), y: pose.y))
    }

    @MainActor
    private func walk(_ floor: any FloorWalkthroughScene) async {
        guard !walking else { return }
        walking = true
        defer { walking = false; paused = false }
        if leg == floor.walkthroughLegs.count {
            lookYaw = 0
            lookPitch = 0
            zoom = 0
            pose = floor.entrance
            displayPose(floor)
            floor.refreshMirrors(at: floor.entrance)
            selectedRoom = floor.walkthroughRooms.first?.id ?? ""
            leg = 0
            return
        }
        let next = floor.walkthroughLegs[leg]
        for stop in next.stops {
            guard let previous = pose, !Task.isCancelled else { return }
            let distance = hypot(Double(stop.x - previous.x), Double(stop.z - previous.z))
            let turn = abs((stop.heading - previous.heading + 540).truncatingRemainder(dividingBy: 360) - 180)
            let seconds = max(0.8, distance / 0.72, turn / 82)
            var elapsed = 0.0
            var last = CACurrentMediaTime()
            var mirrorTaken = last
            while elapsed < seconds {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                let now = CACurrentMediaTime()
                let delta = min(0.033, now - last)
                last = now
                if paused { continue }
                elapsed = min(seconds, elapsed + delta)
                pose = previous.interpolated(to: stop, fraction: elapsed / seconds)
                let ease = exp(-delta * 3)
                lookYaw *= ease
                lookPitch *= ease
                zoom *= ease
                displayPose(floor)
                // A mirror in view follows the walker a few times a second.
                if now - mirrorTaken > 0.25, let pose {
                    mirrorTaken = now
                    floor.refreshMirrors(at: pose)
                }
            }
            pose = stop
            // And is exact wherever the walker stops.
            floor.refreshMirrors(at: stop)
        }
        selectedRoom = next.room.id
        leg += 1
    }
}

private struct ReferenceFloorView: UIViewRepresentable {
    let floor: any FloorWalkthroughScene

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = floor.scene
        view.pointOfView = floor.camera
        view.preferredFramesPerSecond = 60
        view.antialiasingMode = .multisampling4X
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {}
}
#endif
