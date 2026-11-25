import Foundation

/// Renders the reference bathroom in every look from every stop, on the
/// Mac, so the picture can be judged without a device. Usage:
/// render-preview-stills.sh <output folder>
@main
struct PreviewStillMain {
    static func main() {
        let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let width = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 1600 : 1600
        let layout = PreviewLayout(room: PreviewReferenceRoom.bathroom())
        precondition(layout.problems.isEmpty, "reference room is blocked: \(layout.problems)")
        let started = Date()
        let room = PreviewRoomScene(layout: layout)
        print(String(format: "built in %.2f s, %d nodes", Date().timeIntervalSince(started), room.nodeCount))
        for look in PreviewFinish.looks {
            let swap = Date()
            room.apply(.init(lookID: look.id))
            print(String(format: "%@ applied in %.3f s", look.name, Date().timeIntervalSince(swap)))
            for stop in room.stops {
                guard let picture = PreviewStill.render(room, from: stop, width: width) else {
                    print("render failed for \(look.id) \(stop.kind.rawValue)")
                    exit(1)
                }
                let lines = PreviewCaption.lines(revisionTitle: "Reference drawing", savedAt: nil,
                                                 roomName: PreviewReferenceRoom.name, look: look.name,
                                                 layout: layout, useImperial: true)
                let final = stop.kind == .doorway ? PreviewStill.captioned(picture, lines: lines) ?? picture : picture
                let file = folder.appendingPathComponent("\(look.id)-\(stop.kind.rawValue).png")
                try? PreviewStill.png(final)?.write(to: file)
                print("wrote \(file.lastPathComponent)")
            }
        }
    }
}
