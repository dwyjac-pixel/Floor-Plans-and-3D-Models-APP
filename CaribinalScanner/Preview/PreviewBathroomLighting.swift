import SceneKit

enum PreviewBathroomLight: String, CaseIterable, Identifiable, Codable {
    case vanity = "Above-Mirror Vanity Light"
    case ceiling = "Ceiling Fixture"
    case potLights = "Pot Lights"

    var id: Self { self }

    /// The name written to disk. It never changes, so the title can.
    var key: String {
        switch self {
        case .vanity: "vanity"
        case .ceiling: "ceiling"
        case .potLights: "pot-lights"
        }
    }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let match = Self.allCases.first(where: { $0.key == text || $0.rawValue == text }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown light"))
        }
        self = match
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(key)
    }
}

enum PreviewBathroomMirror: String, CaseIterable, Identifiable, Codable {
    case plain = "Plain Mirror"
    case lighted = "Lighted Mirror"

    var id: Self { self }

    var key: String { self == .plain ? "plain" : "lighted" }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let match = Self.allCases.first(where: { $0.key == text || $0.rawValue == text }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown mirror"))
        }
        self = match
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(key)
    }
}

struct PreviewVanityMount {
    let node: SCNNode
    let width: Float
    let depth: Float
    let bottom: Float
    let top: Float
    let clearance: Float
    /// The glass inside the frame, in the vanity's own space.
    var glass: (x0: Float, x1: Float, y0: Float, y1: Float, z: Float)?

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
        // The fixtures drawn change, so what the mirror shows is out of date.
        mirrorIsStale = true
        // The calibrated ceiling spots light the room for every choice, so
        // a floor or a paint always looks the same whichever fixture is
        // picked and two options are compared under one light. The choice
        // changes which fixtures are drawn. It adds no light of its own:
        // an extra bulb close to a wall burns it to white.
        potLights.isHidden = false
        potFixtures.isHidden = style != .potLights
        optionalLights.childNodes.forEach { $0.removeFromParentNode() }
        scene.rootNode.childNode(withName: "vanity-lighting", recursively: false)?.removeFromParentNode()

        func fixture(_ shape: SCNGeometry, at position: V3, in parent: SCNNode, finish: String = "fixed.lamp") {
            let node = SCNNode(geometry: shape)
            shape.firstMaterial = library.material(finish)
            node.simdPosition = position
            node.castsShadow = false
            parent.addChildNode(node)
        }

        if style == .ceiling, let point = centralLampPoint {
            // A flush drum: a lit lens on a slim dark base, so it reads
            // against a white ceiling.
            fixture(SCNCylinder(radius: 0.155, height: 0.012),
                    at: v(point, layout.ceilingHeight - 0.007), in: optionalLights, finish: "fixed.shadow-gap")
            fixture(SCNCylinder(radius: 0.145, height: 0.045),
                    at: v(point, layout.ceilingHeight - 0.035), in: optionalLights)
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
        }
        if mirror == .lighted {
            for side: Float in [-1, 1] {
                fixture(SCNBox(width: 0.012, height: CGFloat(mount.top - mount.bottom - 0.06),
                               length: 0.006, chamferRadius: 0.003),
                        at: V3(side * (mount.width / 2 - 0.034), (mount.top + mount.bottom) / 2, front), in: group)
            }
        }
    }

    /// The ceiling light position nearest the middle of the room.
    var centralLampPoint: PreviewLayout.Point? {
        let xs = layout.floor.map(\.x), zs = layout.floor.map(\.z)
        let centre = PreviewLayout.Point(x: ((xs.min() ?? 0) + (xs.max() ?? 0)) / 2, z: ((zs.min() ?? 0) + (zs.max() ?? 0)) / 2)
        return lampPoints.min { ($0 - centre).length < ($1 - centre).length }
    }

    /// Lights that are on right now: not hidden, and under no hidden node.
    var activeLights: [SCNLight] {
        var lights: [SCNLight] = []
        scene.rootNode.enumerateHierarchy { node, _ in
            guard let light = node.light else { return }
            var ancestor: SCNNode? = node
            while let current = ancestor {
                if current.isHidden { return }
                ancestor = current.parent
            }
            lights.append(light)
        }
        return lights
    }
}
