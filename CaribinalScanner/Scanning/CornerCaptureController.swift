import Foundation
import Combine
import ARKit
import SceneKit

/// Camera-based corner capture for devices without LiDAR: ARKit detects the
/// floor, the user aims the crosshair at each floor corner and marks it.
/// The corners become the room outline for the floor plan and a simple
/// extruded 3D model.
final class CornerCaptureController: NSObject, ObservableObject, ARSessionDelegate {
    @Published var cornerCount = 0
    @Published var lastWallText: String?
    @Published var hint: String?
    @Published var trackingStatus: String? = "Starting camera…"
    @Published var crosshairReady = false

    private var lastReadyCheck: TimeInterval = 0

    let arView = ARSCNView(frame: .zero)

    private(set) var corners: [SIMD3<Float>] = []
    /// Established floor height (world-space y). Seeded from the first accepted
    /// corner (or a floor-classified plane) and lowered to the lowest accepted
    /// corner. Used to reject raycasts that land on furniture (QA-047).
    private var floorY: Float?
    /// A raycast whose y deviates from the floor by more than this is treated
    /// as furniture (table/counter), not a floor corner.
    private let floorTolerance: Float = 0.2
    private var markerNodes: [SCNNode] = []
    private var lineNodes: [SCNNode] = []
    private var coachingOverlay: ARCoachingOverlayView?

    private let configuration: ARWorldTrackingConfiguration = {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        return configuration
    }()

    private var useImperial: Bool {
        UserDefaults.standard.object(forKey: "useImperialUnits") as? Bool ?? true
    }

    override init() {
        super.init()
        arView.session.delegate = self
        arView.automaticallyUpdatesLighting = true
    }

    func start() {
        corners = []
        floorY = nil
        cornerCount = 0
        lastWallText = nil
        hint = nil
        trackingStatus = "Starting camera…"
        markerNodes.forEach { $0.removeFromParentNode() }
        lineNodes.forEach { $0.removeFromParentNode() }
        markerNodes = []
        lineNodes = []

        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        if coachingOverlay == nil {
            let coaching = ARCoachingOverlayView()
            coaching.session = arView.session
            coaching.goal = .horizontalPlane
            coaching.activatesAutomatically = true
            coaching.frame = arView.bounds
            coaching.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            arView.addSubview(coaching)
            coachingOverlay = coaching
        }
    }

    func stop() {
        arView.session.pause()
    }

    func markCorner() {
        guard let result = raycastFloor() else {
            hint = "Floor not found. Sweep the phone over the floor for a few seconds and wait for the crosshair to turn green."
            return
        }
        let transform = result.worldTransform
        let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        if let cameraTransform = arView.session.currentFrame?.camera.transform {
            let camera = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
            if simd_distance(camera, position) > 8 {
                hint = "That point is too far away. Move closer to the corner and aim at the floor."
                return
            }
        }
        // QA-047: reject hits that sit well above (or below) the established
        // floor — those land on a table/counter and would shift the outline.
        // The first corner always seeds the floor height, so it can't be lost.
        if let floorY, abs(position.y - floorY) > floorTolerance {
            hint = "That looks like furniture (a table or counter), not the floor. Aim at the floor corner."
            return
        }
        hint = nil
        if let last = corners.last, horizontalDistance(last, position) < 0.05 {
            hint = "That point is almost identical to the previous corner. Move to the next corner."
            return
        }
        corners.append(position)
        cornerCount = corners.count
        // Track the floor height from accepted corners, preferring a plane
        // ARKit has classified as the floor when one is available.
        if let planeAnchor = result.anchor as? ARPlaneAnchor, planeAnchor.classification == .floor {
            let planeY = planeAnchor.transform.columns.3.y
            floorY = min(floorY ?? planeY, planeY)
        } else if let existing = floorY {
            floorY = min(existing, position.y)
        } else {
            floorY = position.y
        }
        addMarker(at: position)
        if corners.count >= 2 {
            let previous = corners[corners.count - 2]
            addLine(from: previous, to: position)
            lastWallText = Measure.length(horizontalDistance(previous, position), imperial: useImperial)
        }
    }

    func undo() {
        guard !corners.isEmpty else { return }
        corners.removeLast()
        cornerCount = corners.count
        if let node = markerNodes.popLast() {
            node.removeFromParentNode()
        }
        while lineNodes.count > max(corners.count - 1, 0) {
            lineNodes.popLast()?.removeFromParentNode()
        }
        if corners.count >= 2 {
            lastWallText = Measure.length(
                horizontalDistance(corners[corners.count - 2], corners[corners.count - 1]),
                imperial: useImperial)
        } else {
            lastWallText = nil
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.trackingStatus = "Camera problem: \(error.localizedDescription)"
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        // Resume after interruptions (permission dialog, app switch, calls).
        DispatchQueue.main.async {
            self.arView.session.run(self.configuration)
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        DispatchQueue.main.async {
            switch camera.trackingState {
            case .normal:
                self.trackingStatus = nil
            case .notAvailable:
                self.trackingStatus = "Starting camera…"
            case .limited(.initializing):
                self.trackingStatus = "Move the phone slowly to map the room…"
            case .limited(.excessiveMotion):
                self.trackingStatus = "Moving too fast. Slow down."
            case .limited(.insufficientFeatures):
                self.trackingStatus = "Not enough detail. Add light or aim at a textured area."
            case .limited(.relocalizing):
                self.trackingStatus = "Re-finding position. Move the phone slowly."
            case .limited:
                self.trackingStatus = "Limited tracking. Move the phone slowly."
            }
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Cheap readiness probe so the crosshair can show when a corner
        // would actually be captured. Delegate runs on the main queue.
        guard frame.timestamp - lastReadyCheck > 0.15 else { return }
        lastReadyCheck = frame.timestamp
        let ready = raycastFloor() != nil
        if ready != crosshairReady {
            crosshairReady = ready
        }
    }

    // MARK: - Helpers

    /// Raycast from the crosshair with progressively more permissive
    /// targets. Non-LiDAR phones rarely hit `.estimatedPlane` right at wall
    /// corners, so fall back to the detected floor plane extended
    /// infinitely — once the floor is found anywhere, corners always hit.
    private func raycastFloor() -> ARRaycastResult? {
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        let targets: [ARRaycastQuery.Target] = [.existingPlaneGeometry, .estimatedPlane, .existingPlaneInfinite]
        for target in targets {
            if let query = arView.raycastQuery(from: center, allowing: target, alignment: .horizontal),
               let result = arView.session.raycast(query).first {
                return result
            }
        }
        return nil
    }

    private func horizontalDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Double {
        let dx = Double(b.x - a.x)
        let dz = Double(b.z - a.z)
        return (dx * dx + dz * dz).squareRoot()
    }

    private func addMarker(at position: SIMD3<Float>) {
        let sphere = SCNSphere(radius: 0.035)
        sphere.firstMaterial?.diffuse.contents = UIColor.systemOrange
        let node = SCNNode(geometry: sphere)
        node.simdPosition = position
        arView.scene.rootNode.addChildNode(node)
        markerNodes.append(node)
    }

    private func addLine(from a: SIMD3<Float>, to b: SIMD3<Float>) {
        let dx = b.x - a.x
        let dz = b.z - a.z
        let length = CGFloat(horizontalDistance(a, b))
        guard length > 0 else { return }
        let box = SCNBox(width: length, height: 0.015, length: 0.015, chamferRadius: 0)
        box.firstMaterial?.diffuse.contents = UIColor.systemOrange
        let node = SCNNode(geometry: box)
        node.simdPosition = (a + b) / 2
        node.eulerAngles = SCNVector3(0, -atan2(dz, dx), 0)
        arView.scene.rootNode.addChildNode(node)
        lineNodes.append(node)
    }
}
