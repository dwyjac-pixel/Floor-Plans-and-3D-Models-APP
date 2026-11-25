import Metal
import SceneKit
import simd

/// What the mirror shows, without a reflection pass on every frame.
///
/// For a flat mirror, everything seen in the glass is exactly what a
/// camera would see from the viewer's own position mirrored through the
/// wall, looking back into the room through the glass as through a
/// window. So one picture taken from there, fitted to the glass, is the
/// true reflection for that standing position, in the room's current
/// finishes. It stays true while the viewer only looks around. It is
/// taken again when the viewer has moved or a finish has changed.
extension PreviewRoomScene {
    /// Takes the mirror's picture again when it is out of date: a finish
    /// changed, or the viewer stands somewhere else. Cheap to call when
    /// neither happened. `eye` is the viewer in world space; without it,
    /// the camera's current stop is used. A room with no mirror, a viewer
    /// behind the glass, or one farther from it than `reach` metres does
    /// nothing.
    func refreshMirror(seenFrom eye: V3? = nil, reach: Float = 12) {
        autoreleasepool { takeMirror(seenFrom: eye, reach: reach) }
    }

    private func takeMirror(seenFrom eye: V3?, reach: Float) {
        guard let mount = vanityMount, let glassSize = mount.glass else { return }
        guard let eye = eye ?? currentStop.map({ v($0.eye.x, $0.eye.y, $0.eye.z) }) else { return }
        if !mirrorIsStale, let last = mirrorEye, simd_distance(last, eye) < 0.02 { return }

        // The glass in world space, as it faces the room.
        let node = mount.node
        let lowerLeft = node.simdConvertPosition(V3(glassSize.x0, glassSize.y0, glassSize.z), to: nil)
        let lowerRight = node.simdConvertPosition(V3(glassSize.x1, glassSize.y0, glassSize.z), to: nil)
        let upperLeft = node.simdConvertPosition(V3(glassSize.x0, glassSize.y1, glassSize.z), to: nil)
        let across = lowerRight - lowerLeft, rise = upperLeft - lowerLeft
        let facing = simd_normalize(simd_cross(across, rise))
        let distance = simd_dot(eye - lowerLeft, facing)
        // Behind the glass, or so far off that the mirror is a speck.
        guard distance > 0.05, simd_distance(eye, lowerLeft + (across + rise) / 2) < reach else { return }
        let behind = eye - facing * (2 * distance)

        // From behind the wall the glass is a window, and left and right
        // are the other way round.
        let pa = lowerRight, pb = lowerLeft, pc = lowerRight + rise
        let right = simd_normalize(pb - pa), upward = simd_normalize(pc - pa)
        let toward = simd_normalize(simd_cross(right, upward))
        let depth = -simd_dot(toward, pa - behind)
        guard depth > 0.05 else { return }
        // The near plane lies on the glass, so nothing between the mirrored
        // viewer and the mirror (the wall, the next room) is drawn.
        let near = depth + 0.003, far: Float = 60
        let l = simd_dot(right, pa - behind) * near / depth, r = simd_dot(right, pb - behind) * near / depth
        let b = simd_dot(upward, pa - behind) * near / depth, t = simd_dot(upward, pc - behind) * near / depth
        guard r - l > 1e-4, t - b > 1e-4 else { return }

        let lens = SCNCamera()
        Self.configure(lens)
        lens.zNear = Double(near)
        lens.zFar = Double(far)
        // SceneKit reads a projection it is handed with depth running from
        // 0 at the near plane to 1 at the far plane. Written the other
        // common way (-1 to 1), the near plane lands at about twice the
        // distance asked for and cuts away everything close to the glass.
        let depthScale = -far / (far - near), depthOffset = -far * near / (far - near)
        lens.projectionTransform = SCNMatrix4(simd_float4x4(
            SIMD4(2 * near / (r - l), 0, 0, 0),
            SIMD4(0, 2 * near / (t - b), 0, 0),
            SIMD4((r + l) / (r - l), (t + b) / (t - b), depthScale, -1),
            SIMD4(0, 0, depthOffset, 0)))
        // In a floor of several rooms the whole floor is drawn, so the
        // glass shows the hall through this room's doorway as well.
        let window = SCNNode()
        window.camera = lens
        window.simdTransform = simd_float4x4(SIMD4(right, 0), SIMD4(upward, 0), SIMD4(toward, 0), SIMD4(behind, 1))
        let drawn = drawnScene
        drawn.rootNode.addChildNode(window)
        defer { window.removeFromParentNode() }

        let width = simd_length(across), height = simd_length(rise)
        let long: Float = 768
        let pixels = CGSize(width: CGFloat(max(64, (long * min(1, width / height)).rounded())),
                            height: CGFloat(max(64, (long * min(1, height / width)).rounded())))
        if mirrorRenderer == nil, let device = MTLCreateSystemDefaultDevice() {
            let made = SCNRenderer(device: device, options: nil)
            made.autoenablesDefaultLighting = false
            mirrorRenderer = made
        }
        guard let renderer = mirrorRenderer else { return }
        if renderer.scene !== drawn { renderer.scene = drawn }
        renderer.pointOfView = window
        defer { renderer.pointOfView = nil }
        let shot = renderer.snapshot(atTime: 0, with: pixels, antialiasingMode: .multisampling4X)
        #if os(macOS)
        guard let picture = shot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        #else
        guard let picture = shot.cgImage else { return }
        #endif

        let glass = mirrorMaterial ?? {
            let material = SCNMaterial()
            material.name = "fixed.mirror"
            // The picture already holds the room's light. Nothing more falls on the glass.
            material.lightingModel = .constant
            // A silvered mirror returns a little under all the light.
            material.diffuse.intensity = 0.93
            material.diffuse.wrapS = .clamp
            material.diffuse.wrapT = .clamp
            // The glass is measured in metres from its lower left corner
            // as seen from the room; the picture runs the other way across,
            // and from its top down.
            material.diffuse.contentsTransform = SCNMatrix4(simd_float4x4(
                SIMD4(-1 / width, 0, 0, 0), SIMD4(0, -1 / height, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(1, 1, 0, 1)))
            return material
        }()
        glass.diffuse.contents = picture
        if mirrorMaterial == nil {
            mirrorMaterial = glass
            useMirrorGlass()
        }
        mirrorEye = eye
        mirrorIsStale = false
    }
}
