import SwiftUI
import SceneKit

/// Interactive 3D model viewer: orbit (drag), zoom (pinch), pan (two-finger
/// drag), with dimension labels, a measurements bar, Reset View, and Done.
/// Corner-captured rooms are rebuilt live with labels; RoomPlan USDZ scans
/// load directly.
struct Model3DScreen: View {
    let project: RenovationProject

    @Environment(\.dismiss) private var dismiss
    @AppStorage("useImperialUnits") private var useImperial = true
    @State private var resetToken = 0

    // Building the scene reads files from disk and extrudes all geometry;
    // both it and the plan summary are cached so `body` re-evaluations
    // (toolbar, layout) don't rebuild them. Rebuilt only on appear and
    // when the units or the reset token change.
    @State private var scene: SCNScene?
    @State private var planSummary: FloorPlanModel?
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            Group {
                if let scene {
                    Interactive3DView(scene: scene)
                        .id("\(resetToken)-\(useImperial)")
                        .ignoresSafeArea(edges: .bottom)
                        .overlay(alignment: .bottom) {
                            infoBar
                        }
                } else if didLoad {
                    ContentUnavailableView(
                        "No 3D Model",
                        systemImage: "cube",
                        description: Text("Scan the room or capture its corners first.")
                    )
                }
            }
            .navigationTitle("3D Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Reset View") { resetToken += 1 }
                }
            }
        }
        .onAppear { if !didLoad { rebuild() } }
        .onChange(of: useImperial) { _, _ in rebuild() }
        .onChange(of: resetToken) { _, _ in rebuild() }
    }

    /// Rebuild the cached scene and plan summary from disk.
    private func rebuild() {
        scene = makeScene()
        planSummary = loadPlanSummary()
        didLoad = true
    }

    private func loadPlanSummary() -> FloorPlanModel? {
        if let room = ScanStore.loadCapturedRoom(for: project) {
            return FloorPlanModel(room: room)
        }
        let rooms = ScanStore.loadRooms(for: project)
        if !rooms.isEmpty {
            return FloorPlanModel(rooms: rooms.map(\.room))
        }
        if let manual = ScanStore.loadManualRoom(for: project) {
            return FloorPlanModel(manual: manual)
        }
        return nil
    }

    private var infoBar: some View {
        VStack(spacing: 6) {
            if let plan = planSummary {
                HStack(spacing: 18) {
                    if let area = plan.approxFloorAreaSquareMeters {
                        Label(Measure.area(area, imperial: useImperial), systemImage: "square.dashed")
                    }
                    if let ceiling = plan.ceilingHeightMeters {
                        Label(Measure.length(ceiling, imperial: useImperial), systemImage: "arrow.up.and.down")
                    }
                    Label("\(plan.walls.count) walls", systemImage: "ruler")
                }
                .font(.footnote.bold())
            }
            Text("Drag to orbit · Pinch to zoom · Press & hold an object to move it")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.bottom, 12)
    }

    private func makeScene() -> SCNScene? {
        Model3DBuilder.viewerScene(for: project, useImperial: useImperial)
    }
}
