import SceneKit
import simd

/// One ready-made material per finish.
///
/// Building a material is the slow part (its textures are drawn in code),
/// so each is made once and kept. Changing a finish in the room is then
/// only a matter of pointing surfaces at a different ready material.
final class PreviewFinishLibrary {
    private var cache: [String: SCNMaterial] = [:]
    private let lock = NSLock()
    private let textureSize: Int

    init(textureSize: Int = 1024) {
        self.textureSize = textureSize
    }

    func material(_ id: String) -> SCNMaterial {
        lock.lock()
        let ready = cache[id]
        lock.unlock()
        if let ready { return ready }

        // A cold texture should not hold up access to ready materials.
        let finish = PreviewFinish.finish(id) ?? PreviewFinish.finish("fixed.massing")!
        let made = Self.make(finish, textureSize: textureSize)
        lock.lock()
        defer { lock.unlock() }
        if let existing = cache[id] { return existing }
        cache[id] = made
        return made
    }

    /// Every material the given selections can show, for warming up before
    /// the room is revealed.
    func materials(for selections: [PreviewFinish.Selection]) -> [SCNMaterial] {
        var ids: [String] = []
        for selection in selections {
            for id in selection.resolved.values where !ids.contains(id) { ids.append(id) }
        }
        return ids.sorted().map(material)
    }

    private static func seed(_ id: String) -> UInt64 {
        id.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }

    private static func number(_ value: Double) -> NSNumber { NSNumber(value: value) }

    private static func tiled(_ property: SCNMaterialProperty, _ contents: Any, width: Double, height: Double) {
        property.contents = contents
        property.wrapS = .repeat
        property.wrapT = .repeat
        property.minificationFilter = .linear
        property.magnificationFilter = .linear
        property.mipFilter = .linear
        property.maxAnisotropy = 8
        property.contentsTransform = SCNMatrix4(simd_float4x4(diagonal: SIMD4(Float(1 / width), Float(1 / height), 1, 1)))
    }

    private static func make(_ finish: PreviewFinish.Finish, textureSize: Int) -> SCNMaterial {
        let material = SCNMaterial()
        material.name = finish.id
        material.lightingModel = .physicallyBased
        material.metalness.contents = number(0)
        material.roughness.contents = number(0.8)
        switch finish.surface {
        case .paint(let hex, let roughness):
            material.diffuse.contents = PreviewTextures.color(hex)
            material.roughness.contents = number(roughness)
        case .tile(let tile):
            let maps = PreviewTextures.tile(tile, seed: seed(finish.id), size: textureSize)
            tiled(material.diffuse, maps.albedo, width: maps.width, height: maps.height)
            if let roughness = maps.roughness { tiled(material.roughness, roughness, width: maps.width, height: maps.height) }
            // The normal map holds the joint's real slopes, so it is used
            // at full strength and nothing more.
            if let normal = maps.normal { tiled(material.normal, normal, width: maps.width, height: maps.height) }
        case .wood(let wood):
            let maps = PreviewTextures.wood(wood, seed: seed(finish.id), size: textureSize)
            tiled(material.diffuse, maps.albedo, width: maps.width, height: maps.height)
            material.roughness.contents = number(wood.roughness)
        case .stone(let hex, let veinHex, let veining, let roughness):
            let maps = PreviewTextures.stone(hex: hex, veinHex: veinHex, veining: veining, seed: seed(finish.id), size: textureSize)
            tiled(material.diffuse, maps.albedo, width: maps.width, height: maps.height)
            material.roughness.contents = number(roughness)
        case .metal(let hex, let roughness):
            material.diffuse.contents = PreviewTextures.color(hex)
            material.roughness.contents = number(roughness)
            // A near black finish on hardware is a coating over the metal.
            // Drawn as bare metal it would be a black mirror; as a coating
            // it keeps a soft sheen and still reads as black.
            let c = PreviewTextures.rgb(hex)
            material.metalness.contents = number(max(c.r, c.g, c.b) < 0.25 ? 0 : 1)
        case .glazed(let hex):
            material.diffuse.contents = PreviewTextures.color(hex)
            material.roughness.contents = number(0.22)
            material.clearCoat.contents = number(1)
            material.clearCoatRoughness.contents = number(0.05)
        case .glass:
            // Clear glass adds only what it reflects; it never greys what
            // is behind it. Edges and hardware are what make it legible.
            material.diffuse.contents = PreviewTextures.color("000000")
            material.roughness.contents = number(0.03)
            material.blendMode = .add
            material.isDoubleSided = true
            material.writesToDepthBuffer = false
        case .glassEdge:
            material.diffuse.contents = PreviewTextures.color("6F9C8E")
            material.roughness.contents = number(0.25)
        case .mirror:
            // Silvered glass: it shows the lighting environment, which is a
            // soft picture of this room's own shell. There is no reflection
            // pass, so fixtures and finishes do not appear in it.
            material.diffuse.contents = PreviewTextures.color("E9EFEE")
            material.metalness.contents = number(1)
            material.roughness.contents = number(0.02)
        case .glow(let hex, let strength):
            material.diffuse.contents = PreviewTextures.color("000000")
            material.emission.contents = PreviewTextures.color(hex)
            material.emission.intensity = CGFloat(strength)
        case .flat(let hex):
            material.lightingModel = .constant
            material.diffuse.contents = PreviewTextures.color(hex)
        }
        return material
    }
}
