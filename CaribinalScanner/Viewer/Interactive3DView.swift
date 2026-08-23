import SwiftUI
import SceneKit

/// SceneKit viewer with a turntable camera (no roll — the floor stays
/// level), draggable fixtures, and tap callbacks for fixtures and walls.
struct Interactive3DView: UIViewRepresentable {
    let scene: SCNScene
    var onFixtureMoved: ((UUID, Double, Double) -> Void)?
    var onFixtureTapped: ((UUID) -> Void)?
    var onWallTapped: ((Int, SCNVector3) -> Void)?
    var onOpeningTapped: ((UUID) -> Void)?
    var onInteriorTapped: ((UUID, SCNVector3) -> Void)?
    /// How the opening may be dragged: sill = vertical (windows only),
    /// slidable = along its wall. nil = not draggable at all.
    var onOpeningDragBegan: ((UUID) -> (sill: Double?, slidable: Bool)?)?
    var onOpeningDragChanged: ((UUID, Double) -> Void)?
    var onOpeningDragEnded: ((UUID, Double) -> Void)?
    var onOpeningSlideChanged: ((UUID, SCNVector3) -> Void)?
    var onOpeningSlideEnded: ((UUID, SCNVector3) -> Void)?
    /// Standard-view snapping (Top / ¾ / Front): applied when the token
    /// changes, so orbiting freely afterwards is untouched.
    var cameraPose: (position: SCNVector3, target: SCNVector3)?
    var cameraPoseToken = 0
    /// Walkthrough: fly-style camera — drag looks, two-finger drag moves.
    var walkMode = false

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .secondarySystemBackground
        // The SceneKit view is a single opaque element to VoiceOver: its
        // orbit/zoom/drag gestures and the model geometry aren't navigable
        // internally (a known limit). Naming it and marking it an image at
        // least tells VoiceOver users what the view is; the surrounding
        // controls (Reset View, compass, units, catalog) remain reachable.
        view.isAccessibilityElement = true
        view.accessibilityLabel = "3D model of the floor plan"
        view.accessibilityTraits = .image
        view.accessibilityHint = "Interactive 3D view. Drag to orbit, pinch to zoom. The model itself isn't readable by VoiceOver."
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.defaultCameraController.maximumVerticalAngle = 89
        // Never below the horizon — under the ground plane there's only
        // the model's underside.
        view.defaultCameraController.minimumVerticalAngle = 0
        Self.applyOrbitTarget(view)

        // Press-and-hold picks an object up (with a haptic), then the finger
        // drags it. Quick swipes never trigger it, so the camera's own
        // orbit/zoom gestures are never fighting an object drag.
        let press = UILongPressGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.handlePress(_:)))
        press.minimumPressDuration = 0.3
        press.delegate = context.coordinator
        view.addGestureRecognizer(press)
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.scnView = view
        return view
    }

    /// Orbit about the model's centre. Without an explicit target the
    /// camera controller orbits the world origin — the corner of the plan.
    private static func applyOrbitTarget(_ view: SCNView) {
        guard let scene = view.scene else { return }
        if let target = scene.rootNode.childNode(withName: "orbit-target", recursively: false) {
            view.defaultCameraController.target = target.worldPosition
        } else {
            // Loaded USDZ scenes have no marker; use the model's centre.
            view.defaultCameraController.target = scene.rootNode.boundingSphere.center
        }
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.parent = self
        uiView.defaultCameraController.interactionMode = walkMode ? .fly : .orbitTurntable
        // Never swap the scene mid-drag — the coordinator holds node
        // references into the current one.
        if uiView.scene !== scene, !context.coordinator.isDragging {
            // Carry the user's camera across the swap: edits regenerate the
            // scene, and a zoomed-in view has to stay where they put it.
            let previousPOV = uiView.pointOfView
            uiView.scene = scene
            if let previousPOV {
                let carried = previousPOV.clone()
                scene.rootNode.addChildNode(carried)
                uiView.pointOfView = carried
            }
            Self.applyOrbitTarget(uiView)
        }
        if cameraPoseToken != context.coordinator.lastPoseToken,
           let pose = cameraPose, let scene = uiView.scene {
            context.coordinator.lastPoseToken = cameraPoseToken
            let cameraNode = SCNNode()
            let camera = SCNCamera()
            Model3DBuilder.configureCamera(camera)
            cameraNode.camera = camera
            cameraNode.position = pose.position
            scene.rootNode.addChildNode(cameraNode)
            cameraNode.look(at: pose.target)
            uiView.pointOfView = cameraNode
            Self.applyOrbitTarget(uiView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: Interactive3DView
        weak var scnView: SCNView?
        private var draggingNode: SCNNode?
        private var draggingID: UUID?
        private var dragOffsetX: Float = 0
        private var dragOffsetZ: Float = 0

        var isDragging: Bool { draggingNode != nil || draggingOpeningID != nil }
        var lastPoseToken = 0

        // Every surface under the finger, nearest first — so labels, the
        // studio ground, or the floor slab can't swallow a tap or press.
        private let hitOptions: [SCNHitTestOption: Any] = [
            .searchMode: SCNHitTestSearchMode.all.rawValue,
        ]

        init(_ parent: Interactive3DView) {
            self.parent = parent
        }

        // Only let the hold begin on a movable object, so everywhere else
        // the camera keeps its own orbit/pan/zoom gestures untouched.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer is UILongPressGestureRecognizer else { return true }
            switch firstEntity(at: gestureRecognizer.location(in: scnView)) {
            case .fixture:
                return parent.onFixtureMoved != nil
            case .opening:
                return parent.onOpeningDragBegan != nil
            default:
                return false
            }
        }

        /// What the finger is actually on: the nearest hit that resolves
        /// to a named entity wins, so a fixture or opening BEHIND the wall
        /// being tapped can never steal the touch. Unnamed geometry
        /// (labels, ground, floor slab) is looked through.
        enum HitEntity {
            case fixture(SCNNode, UUID)
            case opening(UUID, SCNVector3)
            case interior(UUID, SCNVector3)
            case wall(Int, SCNVector3)
        }

        private func firstEntity(at point: CGPoint) -> HitEntity? {
            guard let view = scnView else { return nil }
            // SceneKit does not reliably sort .all results by distance —
            // sort them ourselves from the camera, or a tap on the near
            // wall can resolve to the wall (or a fixture) behind it.
            let origin = view.pointOfView?.worldPosition ?? SCNVector3Zero
            func squaredDistance(_ v: SCNVector3) -> Float {
                let dx = v.x - origin.x
                let dy = v.y - origin.y
                let dz = v.z - origin.z
                return dx * dx + dy * dy + dz * dz
            }
            let hits = view.hitTest(point, options: hitOptions).sorted {
                squaredDistance($0.worldCoordinates) < squaredDistance($1.worldCoordinates)
            }
            for hit in hits {
                var node: SCNNode? = hit.node
                while let current = node {
                    if let name = current.name {
                        if name.hasPrefix("fixture-"),
                           let id = UUID(uuidString: String(name.dropFirst(8))) {
                            return .fixture(current, id)
                        }
                        if name.hasPrefix("opening-"),
                           let id = UUID(uuidString: String(name.dropFirst(8))) {
                            return .opening(id, hit.worldCoordinates)
                        }
                        if name.hasPrefix("interior-"),
                           let id = UUID(uuidString: String(name.dropFirst(9))) {
                            return .interior(id, hit.worldCoordinates)
                        }
                        if name.hasPrefix("wall-") {
                            // A wall is opaque: it blocks picking anything
                            // behind it. Single-room walls ("wall-<index>")
                            // are tappable; multi-room walls
                            // ("wall-<room>-<index>") don't parse to a single
                            // index and are view-only, but must still occlude
                            // fixtures/openings behind them rather than being
                            // looked through — so return here either way.
                            if let index = Int(name.dropFirst(5)) {
                                return .wall(index, hit.worldCoordinates)
                            }
                            return nil
                        }
                    }
                    node = current.parent
                }
            }
            return nil
        }

        private var draggingOpeningID: UUID?
        private var openingStartSill: Double = 0
        private var openingLastSill: Double = 0
        private var openingDepthZ: Float = 0
        private var openingStartWorldY: Float = 0
        // 0 = undecided, 1 = sill (vertical), 2 = slide (along the wall) —
        // decided by the dominant direction of the first finger movement.
        private var openingMode = 0
        private var openingSillAvailable = false
        private var openingSlidable = false
        private var openingPressStart: CGPoint = .zero
        private var openingLastWorld = SCNVector3Zero

        private func floorPoint(at point: CGPoint) -> SCNVector3? {
            guard let view = scnView else { return nil }
            let near = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 0))
            let far = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 1))
            let dy = far.y - near.y
            guard abs(dy) > 0.0001 else { return nil }
            let t = -near.y / dy
            guard t > 0 else { return nil }
            return SCNVector3(near.x + (far.x - near.x) * t, 0, near.z + (far.z - near.z) * t)
        }

        @objc func handlePress(_ gesture: UILongPressGestureRecognizer) {
            guard let view = scnView else { return }
            let location = gesture.location(in: view)
            switch gesture.state {
            case .began:
                switch firstEntity(at: location) {
                case .opening(let id, let world):
                    guard let info = parent.onOpeningDragBegan?(id) else { break }
                    draggingOpeningID = id
                    openingMode = 0
                    openingSillAvailable = info.sill != nil
                    openingSlidable = info.slidable
                    openingStartSill = info.sill ?? 0
                    openingLastSill = openingStartSill
                    openingDepthZ = view.projectPoint(world).z
                    openingPressStart = location
                    openingStartWorldY = view.unprojectPoint(
                        SCNVector3(Float(location.x), Float(location.y), openingDepthZ)).y
                    openingLastWorld = world
                    view.allowsCameraControl = false
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                case .fixture(let node, let id):
                    guard let floor = floorPoint(at: location) else { break }
                    draggingNode = node
                    draggingID = id
                    dragOffsetX = node.position.x - floor.x
                    dragOffsetZ = node.position.z - floor.z
                    view.allowsCameraControl = false
                    node.opacity = 0.7
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                default:
                    break
                }
            case .changed:
                if let id = draggingOpeningID {
                    if openingMode == 0 {
                        let dx = location.x - openingPressStart.x
                        let dy = location.y - openingPressStart.y
                        guard hypot(dx, dy) > 8 else { return }
                        if abs(dy) > abs(dx), openingSillAvailable {
                            openingMode = 1
                        } else if openingSlidable {
                            openingMode = 2
                        } else {
                            openingMode = 1
                        }
                    }
                    if openingMode == 1 {
                        let worldY = view.unprojectPoint(
                            SCNVector3(Float(location.x), Float(location.y), openingDepthZ)).y
                        openingLastSill = max(0.1, openingStartSill + Double(worldY - openingStartWorldY))
                        parent.onOpeningDragChanged?(id, openingLastSill)
                    } else {
                        let world = view.unprojectPoint(
                            SCNVector3(Float(location.x), Float(location.y), openingDepthZ))
                        openingLastWorld = world
                        parent.onOpeningSlideChanged?(id, world)
                    }
                    return
                }
                if let node = draggingNode, let floor = floorPoint(at: location) {
                    node.position = SCNVector3(floor.x + dragOffsetX, node.position.y, floor.z + dragOffsetZ)
                }
            case .ended, .cancelled, .failed:
                if let id = draggingOpeningID {
                    if openingMode == 2 {
                        parent.onOpeningSlideEnded?(id, openingLastWorld)
                    } else if openingMode == 1 {
                        parent.onOpeningDragEnded?(id, openingLastSill)
                    }
                    draggingOpeningID = nil
                    view.allowsCameraControl = true
                    return
                }
                if let node = draggingNode, let id = draggingID {
                    node.opacity = 1.0
                    parent.onFixtureMoved?(id, Double(node.position.x), Double(node.position.z))
                }
                draggingNode = nil
                draggingID = nil
                view.allowsCameraControl = true
            default:
                break
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard scnView != nil else { return }
            let location = gesture.location(in: scnView)
            switch firstEntity(at: location) {
            case .fixture(_, let id):
                parent.onFixtureTapped?(id)
            case .opening(let id, _):
                parent.onOpeningTapped?(id)
            case .interior(let id, let world):
                parent.onInteriorTapped?(id, world)
            case .wall(let index, let world):
                parent.onWallTapped?(index, world)
            case nil:
                break
            }
        }
    }
}
