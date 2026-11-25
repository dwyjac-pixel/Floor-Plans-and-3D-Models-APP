import CoreGraphics
import Foundation
import SceneKit
import simd

/// Scene level gates for the finished preview, run on the Mac against
/// the real SceneKit scene: the built room agrees with the layout, and a
/// finish swap changes materials and nothing else.
@main
struct PreviewSceneTests {
    static var failures = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        if !condition() {
            failures += 1
            print("FAIL line \(line): \(message)")
        }
    }

    /// World space bounds of a node and everything under it. Hardware
    /// (pulls, taps, hinges) can be left out, since it stands proud of the
    /// body it is fixed to.
    static func bounds(of root: SCNNode, hardware: Bool = true) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var low = SIMD3<Float>(repeating: .infinity), high = SIMD3<Float>(repeating: -.infinity)
        root.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            if !hardware, geometry.firstMaterial?.name?.hasPrefix("metal.") == true { return }
            let (a, b) = node.boundingBox
            for x in [Float(a.x), Float(b.x)] {
                for y in [Float(a.y), Float(b.y)] {
                    for z in [Float(a.z), Float(b.z)] {
                        let world = node.simdConvertPosition(SIMD3(x, y, z), to: nil)
                        low = simd_min(low, world)
                        high = simd_max(high, world)
                    }
                }
            }
        }
        return low.x.isFinite ? (low, high) : nil
    }

    static func main() {
        let layout = PreviewLayout(room: PreviewReferenceRoom.bathroom())
        let builds = PreviewRoomScene.buildCount
        let room = PreviewRoomScene(layout: layout)
        expect(PreviewRoomScene.buildCount == builds + 1, "one build per room")
        agreesWithLayout(room)
        swapsChangeOnlyMaterials(room)
        cameraConventions(room)
        pictures(room)
        savedChoices()
        bathroomOptions(room)
        kitchenFixtures()
        if failures > 0 {
            print("\(failures) preview scene check(s) failed.")
            exit(1)
        }
        print("Preview scene agrees with the layout, swaps change only materials, and stills render.")
    }

    static func kitchenFixtures() {
        var drawing = PreviewReferenceKitchen.room()
        let original = PreviewLayout(room: drawing)
        expect(original.problems.isEmpty, "sample kitchen fits, including the microwave above the stove")
        guard let stove = drawing.fixtures.firstIndex(where: { $0.kind == .stove }) else {
            expect(false, "sample kitchen has a stove")
            return
        }
        drawing.fixtures[stove].z += 0.90
        drawing.fixtures[stove].rotationDegrees = 90
        let added = CornerRoom.Fixture(kind: .microwave, x: 1.2, z: 3.30, widthMeters: 0.63, depthMeters: 0.40)
        drawing.fixtures.append(added)
        guard let data = try? JSONEncoder().encode(drawing),
              let saved = try? JSONDecoder().decode(CornerRoom.self, from: data) else {
            expect(false, "new kitchen items round-trip through the saved plan")
            return
        }
        let layout = PreviewLayout(room: saved)
        expect(layout.problems.isEmpty, "edited kitchen fits")
        let scene = PreviewRoomScene(layout: layout, library: PreviewFinishLibrary(textureSize: 512))
        guard let wide = scene.stops.first(where: { $0.kind == .kitchenWide }),
              let detail = scene.stops.first(where: { $0.kind == .kitchenDetails }) else {
            expect(false, "edited kitchen has wide and detail camera stops")
            return
        }
        let node = scene.scene.rootNode.childNode(withName: "fixture-\(drawing.fixtures[stove].id)", recursively: true)
        expect(abs(Double(node?.simdPosition.z ?? 0) - drawing.fixtures[stove].z) < 0.001,
               "preview uses the moved position")
        expect(abs(Double(node?.simdEulerAngles.y ?? 0) + .pi / 2) < 0.001, "preview uses saved rotation")
        let microwave = scene.scene.rootNode.childNode(withName: "fixture-\(added.id)", recursively: true)
        expect(microwave?.childNodes.count == 4, "added microwave has a body, door, controls and handle")
        expect(PreviewStill.render(scene, from: wide, width: 480) != nil, "wide preview renders")
        expect(PreviewStill.render(scene, from: detail, width: 480) != nil, "close-up preview renders")
    }

    static func bathroomOptions(_ room: PreviewRoomScene) {
        func checkSurround(_ scene: PreviewRoomScene) {
            let before = scene.shownFinishes
            expect(before[.wetWall] == "wet.prefab", "prefab is the default")
            let camera = scene.cameraNode.simdTransform
            scene.apply(.init(overrides: [.wetWall: "wet.white-3x6"]))
            let after = scene.shownFinishes
            expect(after[.wetWall] == "wet.white-3x6", "tile appears on the surround")
            expect(after.filter { $0.key != .wetWall } == before.filter { $0.key != .wetWall },
                   "surround swap leaves the other finishes alone")
            expect(scene.cameraNode.simdTransform == camera, "surround swap preserves the view")
        }
        checkSurround(room)
        expect(room.lightStyle == .ceiling, "low clearance starts with a ceiling fixture")
        room.setBathroomLighting(.potLights, mirror: .lighted)
        expect(!room.potLights.isHidden && room.mirrorStyle == .lighted, "pot lights and lighted mirror coexist")
        room.setBathroomLighting(.vanity, mirror: .plain)
        expect(room.lightStyle == .potLights, "an above-mirror light cannot be selected when it does not fit")
        var tall = PreviewReferenceRoom.bathroom()
        tall.ceilingHeightMeters = 2.5
        tall.fixtures.removeAll { $0.kind == .bulkhead }
        if let shower = tall.fixtures.firstIndex(where: { $0.kind == .shower }) {
            let fixture = tall.fixtures[shower]
            tall.fixtures[shower] = .init(kind: .tubShower, x: fixture.x, z: fixture.z,
                widthMeters: fixture.widthMeters, depthMeters: fixture.depthMeters,
                rotationDegrees: fixture.rotationDegrees)
        }
        let tub = PreviewRoomScene(layout: PreviewLayout(room: tall))
        checkSurround(tub)
        expect(tub.lightStyle == .vanity, "confirmed tall room starts with a vanity light")
    }

    // MARK: A10, the scene agrees with the layout

    static func agreesWithLayout(_ room: PreviewRoomScene) {
        let layout = room.layout
        let tolerance: Float = 0.002
        func node(_ name: String) -> SCNNode? { room.scene.rootNode.childNode(withName: name, recursively: true) }

        if let floor = node("floor").flatMap({ bounds(of: $0) }) {
            expect(abs(floor.min.x) < tolerance && abs(floor.min.z) < tolerance && abs(floor.max.x - 2.8) < tolerance
                   && abs(floor.max.z - 1.6) < tolerance && abs(floor.max.y) < tolerance, "floor is 2.800 x 1.600 at y 0")
        } else {
            expect(false, "no floor node")
        }
        if let ceiling = node("ceiling").flatMap({ bounds(of: $0) }) {
            expect(abs(ceiling.min.y - 2.134) < tolerance && abs(ceiling.max.y - 2.134) < tolerance, "ceiling underside at 2.134")
            expect(abs(ceiling.max.x - 2.8) < tolerance && abs(ceiling.max.z - 1.6) < tolerance, "ceiling covers the floor")
        } else {
            expect(false, "no ceiling node")
        }
        // Painted and tiled wall faces stay on the plan lines.
        for name in ["walls", "wet-walls"] {
            if let walls = node(name).flatMap({ bounds(of: $0) }) {
                expect(walls.min.x > -tolerance && walls.min.z > -tolerance && walls.max.x < 2.8 + tolerance
                       && walls.max.z < 1.6 + tolerance && walls.max.y < 2.134 + tolerance, "\(name) stay on the plan lines")
            } else {
                expect(false, "no \(name) node")
            }
        }

        for solid in layout.solids {
            guard let fixture = node("fixture-\(solid.id.uuidString)"), let box = bounds(of: fixture, hardware: false),
                  let whole = bounds(of: fixture) else {
                expect(false, "no node for \(solid.kind.rawValue)")
                continue
            }
            let xs = solid.corners.map { Float($0.x) }, zs = solid.corners.map { Float($0.z) }
            expect(box.min.x > xs.min()! - tolerance && box.max.x < xs.max()! + tolerance && box.min.z > zs.min()! - tolerance
                   && box.max.z < zs.max()! + tolerance, "\(solid.kind.rawValue) stays on its drawn footprint")
            // A pull or a tap may stand proud of the body, never by much.
            let proud: Float = 0.04
            expect(whole.min.x > xs.min()! - proud && whole.max.x < xs.max()! + proud && whole.min.z > zs.min()! - proud
                   && whole.max.z < zs.max()! + proud, "\(solid.kind.rawValue) hardware stays within 40 mm of its footprint")
            switch solid.kind {
            case .vanity, .shower, .bulkhead:
                expect(box.min.x < xs.min()! + tolerance && box.max.x > xs.max()! - tolerance && box.min.z < zs.min()! + tolerance
                       && box.max.z > zs.max()! - tolerance, "\(solid.kind.rawValue) fills its drawn footprint")
            default:
                break
            }
            if solid.kind == .bulkhead {
                expect(abs(box.min.y - 1.934) < tolerance, "bulkhead underside at 1.934")
            } else {
                expect(abs(box.min.y) < tolerance, "\(solid.kind.rawValue) stands on the floor")
                expect(box.max.y < Float(layout.clearHeight(above: solid.centre)) + tolerance, "\(solid.kind.rawValue) fits under the ceiling")
            }
        }
        expect(room.lampPoints.count >= 1 && room.lampPoints.count <= 3, "one to three ceiling lights")
        // The light budget holds for every light and mirror choice: one
        // shadow caster and at most four others, counting only lights
        // that are switched on.
        let startLight = room.lightStyle, startMirror = room.mirrorStyle
        for style in PreviewBathroomLight.allCases {
            for mirror in PreviewBathroomMirror.allCases {
                room.setBathroomLighting(style, mirror: mirror, clearanceConfirmed: true)
                let lights = room.activeLights
                expect(lights.filter(\.castsShadow).count == 1 && lights.count <= 5,
                       "\(style.rawValue) with \(mirror.rawValue): one shadow caster, five lights at most (found \(lights.count))")
            }
        }
        room.setBathroomLighting(startLight, mirror: startMirror, clearanceConfirmed: true)
    }

    // MARK: B1 to B3, a swap changes materials and nothing else

    static func swapsChangeOnlyMaterials(_ room: PreviewRoomScene) {
        func fingerprint() -> [String] {
            var lines: [String] = []
            room.scene.rootNode.enumerateHierarchy { node, _ in
                let geometry = node.geometry.map { "\(ObjectIdentifier($0).hashValue)" } ?? "none"
                lines.append("\(node.name ?? "?") \(geometry) \(node.simdWorldTransform)")
            }
            return lines
        }
        let camera = room.cameraNode
        let transform = camera.simdWorldTransform
        let projection = camera.camera.map { simd_float4x4($0.projectionTransform) }
        let builds = PreviewRoomScene.buildCount, nodes = room.nodeCount
        let before = fingerprint()

        var selections = PreviewFinish.looks.map { PreviewFinish.Selection(lookID: $0.id) }
        for slot in PreviewFinish.Slot.choices {
            for finish in PreviewFinish.finishes(for: slot) {
                selections.append(.init(lookID: PreviewFinish.looks[0].id, overrides: [slot: finish.id]))
            }
        }
        for round in 0..<8 {
            for selection in selections {
                room.apply(selection)
                let resolved = selection.resolved
                expect(room.shownFinishes.allSatisfy { resolved[$0.key] == $0.value }, "scene shows the selection (round \(round))")
            }
        }
        expect(room.cameraNode === camera && camera.simdWorldTransform == transform, "camera did not move")
        expect(camera.camera.map { simd_float4x4($0.projectionTransform) } == projection, "lens did not change")
        expect(PreviewRoomScene.buildCount == builds, "no rebuild on swap")
        expect(room.nodeCount == nodes && fingerprint() == before, "same nodes, same geometry, same places")

        // One slot at a time: every other slot keeps its material.
        let base = PreviewFinish.Selection(lookID: PreviewFinish.looks[0].id)
        room.apply(base)
        let shown = room.shownFinishes
        for slot in PreviewFinish.Slot.choices {
            guard let other = PreviewFinish.finishes(for: slot).first(where: { $0.id != shown[slot] }) else { continue }
            room.apply(.init(lookID: base.lookID, overrides: [slot: other.id]))
            let now = room.shownFinishes
            let changed = PreviewFinish.Slot.allCases.filter { now[$0] != shown[$0] }
            expect(changed == [slot], "changing \(slot.rawValue) changed \(changed.map(\.rawValue))")
        }
        room.apply(base)
        expect(room.shownFinishes == shown, "back where it started")
        // Every slot a contractor can change is actually on screen in this room.
        for slot in PreviewFinish.Slot.choices { expect(shown[slot] != nil, "\(slot.rawValue) has geometry") }
    }

    // MARK: A11, the overhead view is the plan the right way round

    static func cameraConventions(_ room: PreviewRoomScene) {
        let down = PreviewRoomScene.orientation(headingDegrees: 0, pitchDegrees: -90)
        let right = simd_act(down, SIMD3<Float>(1, 0, 0)), top = simd_act(down, SIMD3<Float>(0, 1, 0))
        expect(simd_distance(right, SIMD3(1, 0, 0)) < 1e-4, "overhead: plan x runs to the right")
        expect(simd_distance(top, SIMD3(0, 0, -1)) < 1e-4, "overhead: plan z runs down the page")
        let level = PreviewRoomScene.orientation(headingDegrees: 90, pitchDegrees: 0)
        expect(simd_distance(simd_act(level, SIMD3<Float>(0, 0, -1)), SIMD3(0, 0, 1)) < 1e-4, "heading 90 looks along +z")
        expect(simd_distance(simd_act(level, SIMD3<Float>(0, 1, 0)), SIMD3(0, 1, 0)) < 1e-4, "standing views are upright")
        if let doorway = room.stops.first(where: { $0.kind == .doorway }) {
            room.place(at: doorway)
            expect(!room.overheadHidden.isHidden, "ceiling shows from the doorway")
        }
        if let overhead = room.stops.first(where: { $0.kind == .overhead }) {
            room.place(at: overhead)
            expect(room.overheadHidden.isHidden, "ceiling steps aside from overhead")
            room.place(at: room.stops[0])
        }
    }

    // MARK: Saved choices outlive a renamed slot or a reworded label

    static func savedChoices() {
        let stored = #"{"lookID":"bright-neutral","overrides":{"floor":"floor.charcoal-24x24","retired":"x"}}"#
        if let back = try? JSONDecoder().decode(PreviewFinish.Selection.self, from: Data(stored.utf8)) {
            expect(back.lookID == "bright-neutral" && back.overrides == [.floor: "floor.charcoal-24x24"],
                   "a slot this build does not know is skipped and the rest is kept")
        } else {
            expect(false, "a selection with an unknown slot does not read")
        }
        let selection = PreviewFinish.Selection(lookID: "warm-modern", overrides: [.wall: "wall.sage"])
        let written = (try? JSONEncoder().encode(selection)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        expect(written.contains(#""wall":"wall.sage""#), "overrides are saved by slot name: \(written)")
        expect((try? JSONDecoder().decode(PreviewFinish.Selection.self, from: Data(written.utf8))) == selection, "selection round trips")
        func text<T: Encodable>(_ value: T) -> String {
            (try? JSONEncoder().encode([value])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        for light in PreviewBathroomLight.allCases {
            let byKey = try? JSONDecoder().decode([PreviewBathroomLight].self, from: Data("[\"\(light.key)\"]".utf8))
            let byTitle = try? JSONDecoder().decode([PreviewBathroomLight].self, from: Data("[\"\(light.rawValue)\"]".utf8))
            expect(byKey == [light] && byTitle == [light], "\(light.key) reads by its key and by its title")
            expect(text(light) == "[\"\(light.key)\"]", "\(light.key) is saved by its key, not its title")
        }
        for mirror in PreviewBathroomMirror.allCases {
            let byKey = try? JSONDecoder().decode([PreviewBathroomMirror].self, from: Data("[\"\(mirror.key)\"]".utf8))
            expect(byKey == [mirror] && text(mirror) == "[\"\(mirror.key)\"]", "\(mirror.key) mirror is saved by its key")
        }
        expect((try? JSONDecoder().decode([PreviewBathroomLight].self, from: Data("[\"Chandelier\"]".utf8))) == nil,
               "an unknown light is refused, so the caller can fall back")
        // Every kind can be placed: the newer ones are saved beside rooms.json.
        expect(Set(CornerRoom.Fixture.Kind.placeable) == Set(CornerRoom.Fixture.Kind.allCases), "every kind is offered in the editor")
    }

    // MARK: Stills

    static func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    /// Share of pixels where any channel differs by more than `threshold`.
    static func difference(_ a: [UInt8], _ b: [UInt8], threshold: Int) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var changed = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            if abs(Int(a[i]) - Int(b[i])) > threshold || abs(Int(a[i + 1]) - Int(b[i + 1])) > threshold
                || abs(Int(a[i + 2]) - Int(b[i + 2])) > threshold { changed += 1 }
        }
        return Double(changed) / Double(a.count / 4)
    }

    static func pictures(_ room: PreviewRoomScene) {
        guard let doorway = room.stops.first(where: { $0.kind == .doorway }) else {
            expect(false, "no doorway stop")
            return
        }
        let warm = PreviewFinish.Selection(lookID: PreviewFinish.looks[0].id)
        let bright = PreviewFinish.Selection(lookID: PreviewFinish.looks[1].id)
        room.apply(warm)
        let live = room.cameraNode.simdWorldTransform
        guard let first = PreviewStill.render(room, from: doorway, width: 480) else {
            expect(false, "still did not render")
            return
        }
        expect(first.width == 480 && first.height == 360, "still is 4:3")
        expect(room.cameraNode.simdWorldTransform == live, "taking a still does not move the live camera")
        room.apply(bright)
        guard let second = PreviewStill.render(room, from: doorway, width: 480) else { return }
        room.apply(warm)
        guard let again = PreviewStill.render(room, from: doorway, width: 480) else { return }
        let a = pixels(first), b = pixels(second), c = pixels(again)
        expect(difference(a, b, threshold: 8) > 0.2, "the two looks are visibly different pictures")
        expect(difference(a, c, threshold: 2) < 0.005, "swapping there and back leaves no trace")
        // Not a blank or blown out frame.
        var dark = 0, blown = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            let top = max(a[i], a[i + 1], a[i + 2])
            if top < 12 { dark += 1 }
            if min(a[i], a[i + 1], a[i + 2]) > 250 { blown += 1 }
        }
        let total = Double(a.count / 4)
        expect(Double(dark) / total < 0.2, "picture is not mostly black")
        expect(Double(blown) / total < 0.02, "picture is not blown out (\(Int(Double(blown) / total * 100)) percent at white)")
        // Whites keep their shape under every light and mirror choice,
        // from both standing views and in both looks.
        let startLight = room.lightStyle, startMirror = room.mirrorStyle
        for look in [warm, bright] {
            room.apply(look)
            for style in PreviewBathroomLight.allCases {
                for mirror in PreviewBathroomMirror.allCases {
                    room.setBathroomLighting(style, mirror: mirror, clearanceConfirmed: true)
                    for stop in room.stops where stop.kind != .overhead {
                        guard let still = PreviewStill.render(room, from: stop, width: 360) else { continue }
                        let p = pixels(still)
                        var white = 0
                        for i in stride(from: 0, to: p.count, by: 4) where min(p[i], p[i + 1], p[i + 2]) > 250 { white += 1 }
                        let share = Double(white) / Double(p.count / 4)
                        expect(share < 0.02, "\(room.lightStyle.rawValue), \(mirror.rawValue), \(stop.kind.rawValue): \(String(format: "%.1f", share * 100)) percent of the picture is pure white")
                    }
                }
            }
        }
        room.setBathroomLighting(startLight, mirror: startMirror, clearanceConfirmed: true)
        room.apply(warm)
        let lines = PreviewCaption.lines(revisionTitle: "Test", savedAt: nil, roomName: "Bathroom", look: "Warm Modern",
                                         layout: room.layout, useImperial: true)
        let captioned = PreviewStill.captioned(first, lines: lines)
        expect((captioned?.height ?? 0) > first.height && captioned?.width == first.width, "caption band is added under the picture")
        expect(PreviewStill.png(first)?.isEmpty == false, "still encodes as PNG")
    }
}
