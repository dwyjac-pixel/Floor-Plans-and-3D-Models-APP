import Foundation
import SceneKit
import simd

/// Exports the reference bathroom from the doorway in every curated look,
/// for a side by side review. One room is built once and only its
/// materials change between pictures, so camera, lens, exposure, lights
/// and geometry are the same by construction. A manifest written beside
/// the pictures records those settings and proves nothing else moved.
/// Usage: render-doorway-pair.sh <output folder> [width]
@main
struct PreviewDoorwayPairMain {
    static func main() {
        let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
        let width = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 2000 : 2000
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let layout = PreviewLayout(room: PreviewReferenceRoom.bathroom())
        precondition(layout.problems.isEmpty, "reference room is blocked: \(layout.problems)")
        let buildsBefore = PreviewRoomScene.buildCount
        let room = PreviewRoomScene(layout: layout)
        guard let doorway = room.stops.first(where: { $0.kind == .doorway }) else {
            print("the reference room has no doorway stop")
            exit(1)
        }

        // Everything about the scene except its materials.
        func fingerprint() -> String {
            var lines: [String] = []
            room.scene.rootNode.enumerateHierarchy { node, _ in
                let geometry = node.geometry.map { "\(ObjectIdentifier($0).hashValue)" } ?? "none"
                var line = "\(node.name ?? "?")|\(geometry)|\(node.simdWorldTransform)|\(node.isHidden)"
                if let light = node.light {
                    line += "|\(light.type.rawValue)|\(light.intensity)|\(light.temperature)|\(light.castsShadow)"
                }
                lines.append(line)
            }
            if let camera = room.cameraNode.camera {
                lines.append("exposure \(camera.exposureOffset) \(camera.wantsExposureAdaptation) \(camera.wantsHDR)")
            }
            lines.append("environment \(room.scene.lightingEnvironment.intensity)")
            return lines.joined(separator: "\n")
        }
        func digest(_ text: String) -> String {
            String(text.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }, radix: 16)
        }

        var manifest: [String] = []
        manifest.append("Finished Preview doorway pair")
        if CommandLine.arguments.count > 3 { manifest.append("Source: \(CommandLine.arguments[3])") }
        manifest.append("Room: reference bathroom (a test drawing, not a client job), 2.800 x 1.600 m, ceiling 2.134 m, bulkhead underside 1.934 m")
        manifest.append("Drawing signature: \(layout.signature)")
        manifest.append("")
        manifest.append("Camera (identical for every picture)")
        manifest.append(String(format: "  eye x %.3f, y %.3f, z %.3f m (scene space; the door is on the x = 0 wall, so negative x is a step back in the hall)",
                               doorway.eye.x, doorway.eye.y, doorway.eye.z))
        manifest.append(String(format: "  heading %.1f degrees, pitch %.1f degrees, horizontal field of view %.0f degrees, lens shift %.2f, picture 4:3",
                               doorway.headingDegrees, doorway.pitchDegrees, doorway.horizontalFOV, doorway.verticalShift))
        if let camera = room.cameraNode.camera {
            manifest.append(String(format: "  exposure offset %.2f, exposure adaptation %@, HDR %@, ambient occlusion %.2f, bloom %.2f",
                                   Double(camera.exposureOffset), camera.wantsExposureAdaptation ? "on" : "off",
                                   camera.wantsHDR ? "on" : "off", Double(camera.screenSpaceAmbientOcclusionIntensity),
                                   Double(camera.bloomIntensity)))
        }
        manifest.append("")
        manifest.append("Lights (identical for every picture)")
        room.scene.rootNode.enumerateHierarchy { node, _ in
            guard let light = node.light else { return }
            manifest.append(String(format: "  %@: %@, intensity %.0f, %.0f K, %@", node.name ?? "?", light.type.rawValue,
                                   Double(light.intensity), Double(light.temperature), light.castsShadow ? "casts shadows" : "no shadows"))
        }
        manifest.append(String(format: "  lighting environment: one painted interior, intensity %.2f", Double(room.scene.lightingEnvironment.intensity)))
        manifest.append("")

        var prints: [String] = []
        for look in PreviewFinish.looks {
            let selection = PreviewFinish.Selection(lookID: look.id)
            room.apply(selection)
            prints.append(digest(fingerprint()))
            guard let picture = PreviewStill.render(room, from: doorway, width: width) else {
                print("render failed for \(look.name)")
                exit(1)
            }
            var lines = PreviewCaption.lines(revisionTitle: "a test drawing, not a client job", savedAt: nil,
                                             roomName: "Reference bathroom", look: look.name, layout: layout, useImperial: true)
            lines.append("Reference bathroom 2.80 x 1.60 m, ceiling 2.13 m. Same camera, lens, exposure and lighting in every look.")
            let final = PreviewStill.captioned(picture, lines: lines) ?? picture
            let file = folder.appendingPathComponent("reference-bathroom-doorway-\(look.id).png")
            do {
                guard let data = PreviewStill.png(final) else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: file, options: .atomic)
            } catch {
                print("could not write \(file.path)")
                exit(1)
            }
            print(file.path)
            manifest.append("\(look.name): \(file.lastPathComponent), \(final.width) x \(final.height) pixels")
            for slot in PreviewFinish.Slot.choices {
                let name = selection.resolved[slot].flatMap(PreviewFinish.finish)?.name ?? "?"
                manifest.append("  \(slot.title): \(name)")
            }
        }
        manifest.append("")
        let locked = Set(prints).count == 1 && PreviewRoomScene.buildCount == buildsBefore + 1
        manifest.append("Lock check: \(locked ? "PASS" : "FAIL"). Scene built \(PreviewRoomScene.buildCount - buildsBefore) time, \(room.nodeCount) nodes.")
        manifest.append("Digest of every node, geometry, position, light and exposure setting, taken before each picture: \(prints.joined(separator: ", "))")
        let note = folder.appendingPathComponent("reference-bathroom-doorway-manifest.txt")
        try? manifest.joined(separator: "\n").appending("\n").write(to: note, atomically: true, encoding: .utf8)
        print(note.path)
        if !locked { exit(1) }
    }
}
