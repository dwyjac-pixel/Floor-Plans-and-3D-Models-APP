import SceneKit

enum PreviewBathroomLight: String, CaseIterable, Identifiable, Codable {
    case vanity = "Above-Mirror Vanity Light"
    case ceiling = "Ceiling Fixture"
    case potLights = "Pot Lights"

    var id: Self { self }
}

enum PreviewBathroomMirror: String, CaseIterable, Identifiable, Codable {
    case plain = "Plain Mirror"
    case lighted = "Lighted Mirror"

    var id: Self { self }
}

struct PreviewVanityMount {
    let node: SCNNode
    let width: Float
    let depth: Float
    let bottom: Float
    let top: Float
    let clearance: Float

    // 60 mm fixture plus 40 mm mounting gap and 20 mm headroom.
    var fitsLight: Bool { clearance - top >= 0.12 }
}

extension PreviewRoomScene {
    var isBathroom: Bool {
        layout.solids.contains { [.vanity, .toilet, .shower, .tubShower].contains($0.kind) }
    }

    var vanityClearanceUncertain: Bool {
        layout.assumptions.contains {
            switch $0 {
            case .ceilingHeight, .bulkheadDrop, .approximateOutline: true
            default: false
            }
        }
    }

    var defaultBathroomLight: PreviewBathroomLight {
        if vanityMount?.fitsLight == true && !vanityClearanceUncertain { return .vanity }
        return .ceiling
    }

    func setBathroomLighting(_ style: PreviewBathroomLight, mirror: PreviewBathroomMirror,
                             clearanceConfirmed: Bool = false) {
        guard style != .vanity || (vanityMount?.fitsLight == true &&
                                   (!vanityClearanceUncertain || clearanceConfirmed)) else { return }
        lightStyle = style
        mirrorStyle = mirror
        potLights.isHidden = style != .potLights
        potFixtures.isHidden = style != .potLights
        optionalLights.childNodes.forEach { $0.removeFromParentNode() }
        scene.rootNode.childNode(withName: "vanity-lighting", recursively: false)?.removeFromParentNode()

        func fixture(_ shape: SCNGeometry, at position: V3, in parent: SCNNode) {
            let node = SCNNode(geometry: shape)
            shape.firstMaterial = library.material("fixed.lamp")
            node.simdPosition = position
            node.castsShadow = false
            parent.addChildNode(node)
        }

        func glow(at position: V3, in parent: SCNNode, intensity: CGFloat) {
            let node = SCNNode()
            let light = SCNLight()
            light.type = .omni
            light.intensity = intensity
            light.attenuationStartDistance = 0.25
            light.attenuationEndDistance = 2
            light.castsShadow = false
            node.light = light
            node.simdPosition = position
            parent.addChildNode(node)
        }

        if style == .ceiling, let point = lampPoints.first {
            fixture(SCNCylinder(radius: 0.145, height: 0.045),
                    at: v(point, layout.ceilingHeight - 0.024), in: optionalLights)
            glow(at: v(point, layout.ceilingHeight - 0.09), in: optionalLights, intensity: 7)
        }

        guard let mount = vanityMount, style == .vanity || mirror == .lighted else { return }
        let group = SCNNode()
        group.name = "vanity-lighting"
        group.simdTransform = mount.node.simdWorldTransform
        scene.rootNode.addChildNode(group)
        let front = -mount.depth + 0.027
        if style == .vanity {
            fixture(SCNBox(width: CGFloat(mount.width * 0.84), height: 0.06, length: 0.045, chamferRadius: 0.012),
                    at: V3(0, mount.top + 0.07, front), in: group)
            glow(at: V3(0, mount.top + 0.04, front + 0.07), in: group, intensity: 5)
        }
        if mirror == .lighted {
            for side: Float in [-1, 1] {
                fixture(SCNBox(width: 0.012, height: CGFloat(mount.top - mount.bottom - 0.06),
                               length: 0.006, chamferRadius: 0.003),
                        at: V3(side * (mount.width / 2 - 0.034), (mount.top + mount.bottom) / 2, front), in: group)
            }
            glow(at: V3(0, (mount.top + mount.bottom) / 2, front + 0.08), in: group, intensity: 4)
        }
    }
}
