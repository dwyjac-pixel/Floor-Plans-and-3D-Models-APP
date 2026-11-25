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
    let potFixtures = SCNNode()
    let potLights = SCNNode()
    let optionalLights = SCNNode()
    var vanityMount: PreviewVanityMount?
    /// The mirror's own glass, once its reflection has been taken. It
    /// belongs to this room alone: two rooms never share a reflection.
    var mirrorMaterial: SCNMaterial?
    /// True when a finish has changed since the reflection was taken.
    var mirrorIsStale = true
    /// Where the viewer stood when it was taken.
    var mirrorEye: V3?
    /// Kept between reflections so each one costs a single small picture.
    var mirrorRenderer: SCNRenderer?
    /// The floor this room was joined into, if it was. Its nodes live
    /// there from then on, and `scene` is left empty.
    private(set) weak var joinedScene: SCNScene?
    /// The scene this room is drawn in: its own, or the floor it joined.
    var drawnScene: SCNScene { joinedScene ?? scene }
    var lightStyle = PreviewBathroomLight.potLights
    var mirrorStyle = PreviewBathroomMirror.plain

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
        // The fill light: a soft picture of this room's own shell, drawn
        // from the plan. It does not depend on the look.
        let environment = PreviewTextures.environment(for: layout, lamps: lampPoints)
        scene.lightingEnvironment.contents = environment.image
        scene.lightingEnvironment.intensity = CGFloat(environment.intensity)
        overheadHidden.name = "ceiling-group"
        scene.rootNode.addChildNode(overheadHidden)
        buildShell()
        buildOpenings()
        buildFixtures()
        buildLights()
        if isBathroom {
            setBathroomLighting(defaultBathroomLight, mirror: .plain)
        }
        buildCamera()
        apply(selection)
        // The mirror is left blank here. Whoever shows the room takes its
        // reflection once the room is where it will be drawn: a room built
        // for a floor is joined first, and a test may never look at it.
        if let first = stops.first { aimCamera(at: first, duration: 0) }
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
            let plain = library.material(id)
            for geometry in list {
                // The mirror keeps its own glass once it has a reflection.
                let material = slot == .mirror && reflects(geometry) ? (mirrorMaterial ?? plain) : plain
                if geometry.firstMaterial !== material { geometry.materials = [material] }
            }
        }
        SCNTransaction.commit()
        // What the mirror shows is the room in its old finishes until it is taken again.
        mirrorIsStale = true
    }

    /// Whether this is the glass the reflection is taken for: the mirror
    /// of the first vanity. A second vanity's mirror stays plain, because
    /// the picture is only true for the glass it was taken through.
    private func reflects(_ geometry: SCNGeometry) -> Bool {
        guard let mount = vanityMount else { return false }
        var found = false
        mount.node.enumerateHierarchy { node, stop in
            if node.geometry === geometry {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// Puts the mirror's own glass on the mirror.
    func useMirrorGlass() {
        guard let glass = mirrorMaterial else { return }
        for geometry in geometries[.mirror] ?? [] where reflects(geometry) { geometry.materials = [glass] }
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

        // Light is counted so that 1 is the amount that shows a surface at
        // its own colour. The fill from the environment is about half of
        // that everywhere; the lights below add the rest, and the brightest
        // white in the room stays a little under 1 so it keeps its shading.

        // One soft key from above. It is the only light that casts
        // shadows; walls and ceiling do not block it, so fixtures sit on
        // the floor with a shadow whatever the room's shape.
        let key = SCNLight()
        key.type = .directional
        key.intensity = 210
        key.color = PreviewTextures.light(1, 0.985, 0.955)
        key.castsShadow = true
        key.shadowRadius = 6
        key.shadowSampleCount = 16
        key.shadowMapSize = CGSize(width: 1024, height: 1024)
        key.shadowColor = PreviewTextures.color("000000", alpha: 1)
        key.shadowBias = 3
        let keyNode = SCNNode()
        keyNode.name = "key"
        keyNode.light = key
        keyNode.simdPosition = centre + V3(-1.5, 6, 1.4)
        keyNode.simdLook(at: centre)
        root.addChildNode(keyNode)

        // Light bounced off the floor, which is what makes a real ceiling
        // read as white. SceneKit has no bounce light of its own.
        let bounce = SCNLight()
        bounce.type = .directional
        bounce.intensity = 380
        bounce.castsShadow = false
        let bounceNode = SCNNode()
        bounceNode.name = "bounce"
        bounceNode.light = bounce
        bounceNode.simdPosition = centre
        bounceNode.simdLook(at: centre + V3(0.05, 1, 0.08))
        root.addChildNode(bounceNode)

        // Recessed ceiling lights. Each is a wide warm cone: strongest on
        // the wall a little below the ceiling, easing off toward the floor
        // and into the corners, and cut off before it can reach the ceiling
        // or a bulkhead beside it. No shadows, to keep the frame rate.
        // SceneKit counts a spot so that an intensity of pi lights a
        // surface one metre away at 1.
        root.addChildNode(potLights)
        overheadHidden.addChildNode(potFixtures)
        overheadHidden.addChildNode(optionalLights)
        for (index, point) in lampPoints.enumerated() {
            let lamp = SCNLight()
            lamp.type = .spot
            lamp.intensity = 1.25
            lamp.color = PreviewTextures.light(1, 0.95, 0.87)
            lamp.spotInnerAngle = 90
            lamp.spotOuterAngle = 162
            lamp.castsShadow = false
            let node = SCNNode()
            node.name = "lamp-\(index)"
            node.light = lamp
            node.simdPosition = v(point, layout.ceilingHeight - 0.03)
            node.simdEulerAngles = V3(-.pi / 2, 0, 0)
            potLights.addChildNode(node)

            let trimRing = SCNCylinder(radius: 0.062, height: 0.004)
            let ring = add(trimRing, slot: .trim, to: potFixtures)
            ring.simdPosition = v(point, layout.ceilingHeight - 0.002)
            ring.castsShadow = false
            let lens = SCNCylinder(radius: 0.046, height: 0.004)
            add(lens, slot: .lamp, to: potFixtures).simdPosition = v(point, layout.ceilingHeight - 0.004)
        }
    }

    /// Moves this room into a floor made of several rooms and returns the
    /// group that now holds it.
    ///
    /// A floor has one sun. The room's own key and bounce stay behind
    /// unless `bringSun` is set, which the first room does; otherwise every
    /// room would be lit by every other room's pair and the same paint
    /// would change brightness with the number of rooms. The room's
    /// ceiling lights come along and are confined to this room's own
    /// surfaces, so no surface is ever lit by more than its own lamps.
    func join(_ floor: SCNScene, named name: String, index: Int, bringSun: Bool) -> SCNNode {
        let group = SCNNode()
        group.name = name
        joinedScene = floor
        let category = 1 << (index % 30 + 1)
        for child in scene.rootNode.childNodes where child !== cameraNode {
            if child.name == "lights" {
                potLights.removeFromParentNode()
                group.addChildNode(potLights)
                if bringSun { floor.rootNode.addChildNode(child) }
                continue
            }
            group.addChildNode(child)
        }
        group.enumerateHierarchy { node, _ in
            node.categoryBitMask = category
            node.light?.categoryBitMask = category
        }
        floor.rootNode.addChildNode(group)
        return group
    }

    // MARK: Camera

    private func buildCamera() {
        let camera = SCNCamera()
        Self.configure(camera)
        cameraNode.name = "preview-camera"
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
    }

    /// Exposure and shading for every preview camera, so a single room and
    /// a whole floor show the same finish the same way.
    static func configure(_ camera: SCNCamera) {
        camera.projectionDirection = .horizontal
        camera.zNear = 0.05
        camera.zFar = 60
        // A fixed exposure with no tone curve: what a light adds is what
        // the picture shows, so a paint colour is not bent on its way to
        // the screen and two looks are always exposed alike.
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = 0
        camera.whitePoint = 1
        // A tight radius: a crisp contact line where a fixture meets a
        // wall or the floor. A wide one greys whole walls, frames flat
        // panels in soot and turns chrome black.
        camera.screenSpaceAmbientOcclusionIntensity = 0.6
        camera.screenSpaceAmbientOcclusionRadius = 0.04
        camera.screenSpaceAmbientOcclusionBias = 0.02
        camera.screenSpaceAmbientOcclusionDepthThreshold = 0.2
        camera.screenSpaceAmbientOcclusionNormalThreshold = 0.3
        camera.bloomThreshold = 0.95
        camera.bloomIntensity = 0.12
        camera.bloomBlurRadius = 6
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
    /// SceneKit reads a projection it is handed with depth running from 0
    /// at the near plane to 1 at the far plane, and that is how this one is
    /// written. Written the other common way (-1 to 1) the near plane
    /// lands at twice the distance asked for, 0.10 m here, and a wall
    /// close beside the viewer is cut away at the edge of a wide view.
    static func projection(for stop: PreviewCamera.Stop, near: Float = 0.05, far: Float = 60) -> simd_float4x4 {
        let across = 1 / tan(Float(stop.horizontalFOV) / 2 * .pi / 180)
        return simd_float4x4(SIMD4(across, 0, 0, 0),
                             SIMD4(0, across * Float(PreviewCamera.aspect), 0, 0),
                             SIMD4(0, -Float(stop.verticalShift), -far / (far - near), -1),
                             SIMD4(0, 0, -far * near / (far - near), 0))
    }

    static func aim(_ camera: SCNCamera?, for stop: PreviewCamera.Stop) {
        camera?.fieldOfView = CGFloat(stop.horizontalFOV)
        camera?.projectionTransform = SCNMatrix4(projection(for: stop))
    }

    /// Puts the one camera at a stop. With a duration it glides there.
    func place(at stop: PreviewCamera.Stop, duration: TimeInterval = 0) {
        aimCamera(at: stop, duration: duration)
        // A glide shows the old reflection until it lands; whoever starts
        // one takes the mirror again when it ends.
        if duration == 0 { refreshMirror() }
    }

    private func aimCamera(at stop: PreviewCamera.Stop, duration: TimeInterval) {
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
