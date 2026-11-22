import SceneKit
import simd

/// The finished room as a SceneKit scene, built once from a
/// `PreviewLayout`.
///
/// Every surface belongs to a finish slot. Changing a finish assigns
/// ready materials to the slot's geometry and touches nothing else: no
/// node is added, moved or removed and the camera is left alone.
///
/// This is separate from `Model3DBuilder` on purpose. The editor and the
/// USDZ export keep their own scene; nothing here can change them.
final class PreviewRoomScene {
    typealias V3 = SIMD3<Float>

    let scene = SCNScene()
    let layout: PreviewLayout
    let stops: [PreviewCamera.Stop]
    let cameraNode = SCNNode()
    let library: PreviewFinishLibrary
    private(set) var selection: PreviewFinish.Selection
    private(set) var currentStop: PreviewCamera.Stop?
    private var geometries: [PreviewFinish.Slot: [SCNGeometry]] = [:]
    /// Ceiling, bulkheads and light trims. Hidden from the overhead stop so
    /// the camera looks straight into the room.
    let overheadHidden = SCNNode()

    /// How many rooms have been built. A finish swap must never raise it.
    private(set) static var buildCount = 0

    init(layout: PreviewLayout, selection: PreviewFinish.Selection = .init(),
         library: PreviewFinishLibrary = PreviewFinishLibrary()) {
        self.layout = layout
        self.selection = selection
        self.library = library
        stops = PreviewCamera.stops(for: layout)
        Self.buildCount += 1
        scene.background.contents = PreviewTextures.color("26282B")
        scene.lightingEnvironment.contents = PreviewFinishLibrary.environment
        scene.lightingEnvironment.intensity = 1.2
        overheadHidden.name = "ceiling-group"
        scene.rootNode.addChildNode(overheadHidden)
        buildShell()
        buildOpenings()
        buildFixtures()
        buildLights()
        buildCamera()
        apply(selection)
        if let first = stops.first { place(at: first) }
    }

    // MARK: Finishes

    /// Shows a selection. Only materials change.
    func apply(_ selection: PreviewFinish.Selection) {
        self.selection = selection
        let resolved = selection.resolved
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        for (slot, list) in geometries {
            guard let id = resolved[slot] else { continue }
            let material = library.material(id)
            for geometry in list where geometry.firstMaterial !== material { geometry.materials = [material] }
        }
        SCNTransaction.commit()
    }

    /// The finish each slot is showing right now, read back from the scene.
    var shownFinishes: [PreviewFinish.Slot: String] {
        geometries.compactMapValues { $0.first?.firstMaterial?.name }
    }

    var nodeCount: Int {
        var count = 0
        scene.rootNode.enumerateHierarchy { _, _ in count += 1 }
        return count
    }

    @discardableResult
    func add(_ geometry: SCNGeometry, slot: PreviewFinish.Slot, to parent: SCNNode, name: String? = nil) -> SCNNode {
        geometries[slot, default: []].append(geometry)
        let node = SCNNode(geometry: geometry)
        node.name = name
        if slot == .glass || slot == .daylight || slot == .lamp { node.castsShadow = false }
        if slot == .glass { node.renderingOrder = 10 }
        parent.addChildNode(node)
        return node
    }

    // MARK: Helpers

    func v(_ x: Double, _ y: Double, _ z: Double) -> V3 { V3(Float(x), Float(y), Float(z)) }
    func v(_ p: PreviewLayout.Point, _ y: Double) -> V3 { V3(Float(p.x), Float(y), Float(p.z)) }
    var up: V3 { V3(0, 1, 0) }

    // MARK: Shell

    private func buildShell() {
        let root = SCNNode()
        root.name = "shell"
        scene.rootNode.addChildNode(root)
        let height = layout.ceilingHeight

        var floor = PreviewMesh()
        let triangles = layout.floorTriangles()
        floor.polygon(layout.floor.map { v($0, 0) }, triangles: triangles, normal: up) { PreviewMesh.V2($0.x, $0.z) }
        add(floor.geometry(), slot: .floor, to: root, name: "floor").castsShadow = false

        var ceiling = PreviewMesh()
        ceiling.polygon(layout.floor.map { v($0, height) }, triangles: triangles, normal: -up) { PreviewMesh.V2($0.x, $0.z) }
        // One sided and facing down, so the overhead view looks straight in.
        add(ceiling.geometry(), slot: .ceiling, to: overheadHidden, name: "ceiling").castsShadow = false

        var paint = PreviewMesh(), wet = PreviewMesh(), trim = PreviewMesh(), cut = PreviewMesh()
        for wall in layout.walls {
            let direction = v(wall.direction, 0), inward = v(wall.inward, 0)
            for cell in layout.cells(for: wall) {
                let origin = v(wall.point(at: cell.u0), cell.v0)
                let u = direction * Float(cell.u1 - cell.u0), rise = up * Float(cell.v1 - cell.v0)
                let uv = PreviewMesh.V2(Float(cell.u0), Float(cell.v0))
                if cell.surface == .wetTile {
                    wet.rect(origin: origin, u: u, v: rise, facing: inward, uvOrigin: uv)
                } else {
                    paint.rect(origin: origin, u: u, v: rise, facing: inward, uvOrigin: uv)
                }
            }
            // Baseboard on painted stretches.
            var gaps = layout.baseboardGaps(on: wall).sorted { $0.lowerBound < $1.lowerBound }
            gaps.append(wall.length...wall.length)
            var cursor = 0.0
            for gap in gaps {
                if gap.lowerBound - cursor > 0.03 {
                    trim.box(origin: v(wall.point(at: cursor), 0), u: direction * Float(gap.lowerBound - cursor),
                             v: up * 0.09, w: inward * 0.012)
                }
                cursor = max(cursor, gap.upperBound)
            }
            // The cut top of the wall, seen only from overhead.
            cut.polygon([v(wall.start, height), v(wall.end, height), v(wall.outerEnd, height), v(wall.outerStart, height)],
                        triangles: [0, 1, 2, 0, 2, 3], normal: up) { _ in .zero }
        }
        for (mesh, slot, name) in [(paint, PreviewFinish.Slot.wall, "walls"), (wet, .wetWall, "wet-walls"),
                                    (trim, .trim, "baseboard"), (cut, .shadowGap, "wall-tops")] where !mesh.isEmpty {
            add(mesh.geometry(), slot: slot, to: root, name: name).castsShadow = false
        }
    }

    // MARK: Doors and windows

    private func buildOpenings() {
        let root = SCNNode()
        root.name = "openings"
        scene.rootNode.addChildNode(root)
        let thickness = Float(PreviewLayout.wallThickness)
        let entryID = PreviewCamera.entry(in: layout)?.void.id
        var trim = PreviewMesh(), glow = PreviewMesh()

        for wall in layout.walls {
            let direction = v(wall.direction, 0), inward = v(wall.inward, 0)
            for void in wall.voids {
                let from = v(wall.point(at: void.from), 0), to = v(wall.point(at: void.to), 0)
                let sill = up * Float(void.sill), head = up * Float(void.head)
                let rise = up * Float(void.head - void.sill), span = direction * Float(void.width)
                let through = -inward * thickness
                // Lined reveals through the wall thickness.
                trim.rect(origin: from + sill, u: through, v: rise, facing: direction)
                trim.rect(origin: to + sill, u: through, v: rise, facing: -direction)
                trim.rect(origin: from + head, u: span, v: through, facing: -up)
                let isDoorway = void.sill < 0.05
                if !isDoorway { trim.rect(origin: from + sill, u: span, v: through, facing: up) }

                // Casing on the room side, kept on the wall.
                let casing: Float = 0.065, proud: Float = 0.014
                let left = max(0, Float(void.from) - casing), right = min(Float(wall.length), Float(void.to) + casing)
                let base = v(wall.start, 0)
                let top = min(Float(layout.ceilingHeight), Float(void.head) + casing)
                let bottom = isDoorway ? 0 : max(0, Float(void.sill) - casing)
                if Float(void.from) - left > 0.01 {
                    trim.box(origin: base + direction * left + up * bottom, u: direction * (Float(void.from) - left),
                             v: up * (top - bottom), w: inward * proud)
                }
                if right - Float(void.to) > 0.01 {
                    trim.box(origin: base + direction * Float(void.to) + up * bottom, u: direction * (right - Float(void.to)),
                             v: up * (top - bottom), w: inward * proud)
                }
                if top - Float(void.head) > 0.01 {
                    trim.box(origin: from + head, u: span, v: up * (top - Float(void.head)), w: inward * proud)
                }
                if !isDoorway, Float(void.sill) - bottom > 0.01 {
                    trim.box(origin: from + up * bottom, u: span, v: up * (Float(void.sill) - bottom), w: inward * (proud + 0.02))
                }

                switch void.kind {
                case .window:
                    // Sash frame set mid wall with daylight behind it.
                    let depth = through * 0.55, bar: Float = 0.035
                    let a = from + sill + depth
                    trim.box(origin: a, u: span, v: up * bar, w: inward * 0.03)
                    trim.box(origin: a + rise - up * bar, u: span, v: up * bar, w: inward * 0.03)
                    trim.box(origin: a, u: direction * bar, v: rise, w: inward * 0.03)
                    trim.box(origin: a + span - direction * bar, u: direction * bar, v: rise, w: inward * 0.03)
                    glow.rect(origin: a + inward * 0.012, u: span, v: rise, facing: inward)
                case .door, .closetDoor:
                    buildLeaf(void, on: wall, open: void.id == entryID, parent: root)
                case .opening:
                    break
                }
            }
        }
        if !trim.isEmpty { add(trim.geometry(), slot: .trim, to: root, name: "casings").castsShadow = false }
        if !glow.isEmpty { add(glow.geometry(), slot: .daylight, to: root, name: "daylight") }
    }

    private func buildLeaf(_ void: PreviewLayout.Void, on wall: PreviewLayout.WallFace, open: Bool, parent: SCNNode) {
        let width = Float(void.width) - 0.006, height = Float(void.head) - 0.008, thick: Float = 0.035
        let hingeAt = void.hingeAtEnd ? void.to : void.from
        let closed = v(wall.direction, 0) * (void.hingeAtEnd ? -1 : 1)
        let swing = v(wall.inward, 0) * (void.swingsOutward ? -1 : 1)
        // The entry door stands open so the client looks into the room.
        let angle: Float = open ? .pi / 2 : 0
        let along = simd_normalize(closed * cos(angle) + swing * sin(angle))
        let side = simd_normalize(simd_cross(along, up))
        let hinge = SCNNode()
        hinge.name = "door-\(void.id.uuidString)"
        hinge.simdTransform = simd_float4x4(SIMD4(along, 0), SIMD4(up, 0), SIMD4(side, 0),
                                            SIMD4(v(wall.point(at: hingeAt), 0) + swing * (open ? 0.0 : -0.03), 1))
        parent.addChildNode(hinge)
        // Keep the open leaf on the room side of its own hinge line.
        let offset: Float = simd_dot(side, closed) > 0 ? thick / 2 : -thick / 2
        let leaf = SCNBox(width: CGFloat(width), height: CGFloat(height), length: CGFloat(thick), chamferRadius: 0.002)
        let leafNode = add(leaf, slot: .door, to: hinge)
        leafNode.simdPosition = V3(0.003 + width / 2, height / 2, open ? -offset : 0)
        for face: Float in [-1, 1] {
            let rose = SCNCylinder(radius: 0.026, height: 0.008)
            let roseNode = add(rose, slot: .hardware, to: hinge)
            roseNode.simdPosition = V3(width - 0.06, 0.95, leafNode.simdPosition.z + face * (thick / 2 + 0.004))
            roseNode.simdEulerAngles = V3(.pi / 2, 0, 0)
            let lever = SCNBox(width: 0.12, height: 0.016, length: 0.012, chamferRadius: 0.005)
            let leverNode = add(lever, slot: .hardware, to: hinge)
            leverNode.simdPosition = V3(width - 0.06 - 0.045, 0.95, leafNode.simdPosition.z + face * (thick / 2 + 0.04))
            let neck = SCNCylinder(radius: 0.008, height: 0.04)
            let neckNode = add(neck, slot: .hardware, to: hinge)
            neckNode.simdPosition = V3(width - 0.06, 0.95, leafNode.simdPosition.z + face * (thick / 2 + 0.02))
            neckNode.simdEulerAngles = V3(.pi / 2, 0, 0)
        }
    }

    // MARK: Light

    /// Ceiling light positions: an even grid over the room, kept to open
    /// ceiling inside the outline.
    var lampPoints: [PreviewLayout.Point] {
        let xs = layout.floor.map(\.x), zs = layout.floor.map(\.z)
        guard let minX = xs.min(), let maxX = xs.max(), let minZ = zs.min(), let maxZ = zs.max() else { return [] }
        let across = max(1, Int(((maxX - minX) / 1.3).rounded())), deep = max(1, Int(((maxZ - minZ) / 1.5).rounded()))
        var points: [PreviewLayout.Point] = []
        for i in 0..<across {
            for j in 0..<deep {
                var point = PreviewLayout.Point(x: minX + (maxX - minX) * (Double(i) + 0.5) / Double(across),
                                                z: minZ + (maxZ - minZ) * (Double(j) + 0.5) / Double(deep))
                // Nudge off a bulkhead onto open ceiling.
                for _ in 0..<6 where layout.clearHeight(above: point) < layout.ceilingHeight - 0.001 {
                    let centre = PreviewLayout.Point(x: (minX + maxX) / 2, z: (minZ + maxZ) / 2)
                    point = point + (centre - point) * 0.25
                }
                if layout.contains(point), layout.clearance(from: point) > 0.3,
                   layout.clearHeight(above: point) >= layout.ceilingHeight - 0.001 {
                    points.append(point)
                }
            }
        }
        return Array(points.prefix(3))
    }

    private func buildLights() {
        let root = SCNNode()
        root.name = "lights"
        scene.rootNode.addChildNode(root)
        let xs = layout.floor.map(\.x), zs = layout.floor.map(\.z)
        let centre = v(((xs.min() ?? 0) + (xs.max() ?? 0)) / 2, 0, ((zs.min() ?? 0) + (zs.max() ?? 0)) / 2)

        // One soft key from above. It is the only light that casts
        // shadows; walls and ceiling do not block it, so fixtures sit on
        // the floor with a shadow and the room itself stays evenly lit.
        let key = SCNLight()
        key.type = .directional
        key.intensity = 400
        key.temperature = 6100
        key.castsShadow = true
        key.shadowRadius = 5
        key.shadowSampleCount = 16
        key.shadowMapSize = CGSize(width: 2048, height: 2048)
        key.shadowColor = PreviewTextures.color("000000", alpha: 0.42)
        key.shadowBias = 3
        let keyNode = SCNNode()
        keyNode.name = "key"
        keyNode.light = key
        keyNode.simdPosition = centre + V3(-0.9, 6, 1.3)
        keyNode.simdLook(at: centre)
        root.addChildNode(keyNode)

        // Light bounced off the floor, which is what makes a real ceiling
        // read as white. SceneKit has no bounce light of its own.
        let bounce = SCNLight()
        bounce.type = .directional
        bounce.intensity = 300
        bounce.temperature = 6100
        bounce.castsShadow = false
        let bounceNode = SCNNode()
        bounceNode.name = "bounce"
        bounceNode.light = bounce
        bounceNode.simdPosition = centre
        bounceNode.simdLook(at: centre + V3(0.05, 1, 0.08))
        root.addChildNode(bounceNode)

        // Recessed ceiling lights: a warm pool on the floor and a soft
        // scallop on the walls. No shadows, to keep the frame rate.
        for (index, point) in lampPoints.enumerated() {
            let lamp = SCNLight()
            lamp.type = .spot
            lamp.intensity = 6
            lamp.temperature = 5000
            lamp.spotInnerAngle = 20
            lamp.spotOuterAngle = 160
            lamp.attenuationStartDistance = 0
            lamp.attenuationEndDistance = 7
            lamp.attenuationFalloffExponent = 2
            lamp.castsShadow = false
            let node = SCNNode()
            node.name = "lamp-\(index)"
            node.light = lamp
            node.simdPosition = v(point, layout.ceilingHeight - 0.03)
            node.simdEulerAngles = V3(-.pi / 2, 0, 0)
            root.addChildNode(node)

            let trimRing = SCNCylinder(radius: 0.062, height: 0.004)
            let ring = add(trimRing, slot: .trim, to: overheadHidden)
            ring.simdPosition = v(point, layout.ceilingHeight - 0.002)
            ring.castsShadow = false
            let lens = SCNCylinder(radius: 0.046, height: 0.004)
            add(lens, slot: .lamp, to: overheadHidden).simdPosition = v(point, layout.ceilingHeight - 0.004)
        }
    }

    // MARK: Camera

    private func buildCamera() {
        let camera = SCNCamera()
        camera.projectionDirection = .horizontal
        camera.zNear = 0.05
        camera.zFar = 60
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = -0.15
        camera.screenSpaceAmbientOcclusionIntensity = 0.55
        camera.screenSpaceAmbientOcclusionRadius = 0.22
        camera.screenSpaceAmbientOcclusionBias = 0.02
        camera.screenSpaceAmbientOcclusionDepthThreshold = 0.2
        camera.screenSpaceAmbientOcclusionNormalThreshold = 0.3
        camera.bloomThreshold = 0.95
        camera.bloomIntensity = 0.12
        camera.bloomBlurRadius = 6
        cameraNode.name = "preview-camera"
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
    }

    static func orientation(headingDegrees: Double, pitchDegrees: Double) -> simd_quatf {
        let heading = Float(headingDegrees * .pi / 180), pitch = Float(pitchDegrees * .pi / 180)
        let forward = V3(cos(heading) * cos(pitch), sin(pitch), sin(heading) * cos(pitch))
        // Straight down: keep plan x to the right and plan z down the page.
        let reference: V3 = abs(pitchDegrees) > 89 ? V3(0, 0, -1) : V3(0, 1, 0)
        let back = -simd_normalize(forward)
        let right = simd_normalize(simd_cross(reference, back))
        let upward = simd_cross(back, right)
        return simd_quatf(simd_float3x3(right, upward, back))
    }

    /// The lens for a stop: a 4:3 perspective with the picture slid down
    /// by the stop's shift. SceneKit takes this in place of a field of view.
    static func projection(for stop: PreviewCamera.Stop, near: Float = 0.05, far: Float = 60) -> simd_float4x4 {
        let across = 1 / tan(Float(stop.horizontalFOV) / 2 * .pi / 180)
        return simd_float4x4(SIMD4(across, 0, 0, 0),
                             SIMD4(0, across * Float(PreviewCamera.aspect), 0, 0),
                             SIMD4(0, -Float(stop.verticalShift), -(far + near) / (far - near), -1),
                             SIMD4(0, 0, -2 * far * near / (far - near), 0))
    }

    static func aim(_ camera: SCNCamera?, for stop: PreviewCamera.Stop) {
        camera?.fieldOfView = CGFloat(stop.horizontalFOV)
        camera?.projectionTransform = SCNMatrix4(projection(for: stop))
    }

    /// Puts the one camera at a stop. With a duration it glides there.
    func place(at stop: PreviewCamera.Stop, duration: TimeInterval = 0) {
        currentStop = stop
        overheadHidden.isHidden = stop.kind == .overhead
        SCNTransaction.begin()
        SCNTransaction.animationDuration = duration
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        cameraNode.simdPosition = v(stop.eye.x, stop.eye.y, stop.eye.z)
        cameraNode.simdOrientation = Self.orientation(headingDegrees: stop.headingDegrees, pitchDegrees: stop.pitchDegrees)
        SCNTransaction.commit()
        Self.aim(cameraNode.camera, for: stop)
    }
}
