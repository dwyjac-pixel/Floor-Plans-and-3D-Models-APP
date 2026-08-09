import SwiftUI
import RoomPlan

/// Bridges RoomPlan's UIKit capture view into SwiftUI.
struct RoomCaptureViewRep: UIViewRepresentable {
    let controller: ScanSessionController

    func makeUIView(context: Context) -> RoomCaptureView {
        ScanDebugLog.log("RoomCaptureViewRep.makeUIView")
        return controller.captureView
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}
