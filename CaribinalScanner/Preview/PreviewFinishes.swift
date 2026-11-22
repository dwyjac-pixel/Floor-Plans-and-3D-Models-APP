import Foundation

/// What the room is finished in, kept apart from its geometry.
///
/// A finish names a surface treatment; a slot is the kind of surface it
/// goes on; a look is one finish for every slot. Changing a finish never
/// changes a dimension, so a swap only ever replaces materials.
enum PreviewFinish {
    enum Slot: String, CaseIterable, Codable {
        case floor
        case wetWall
        case wall
        case vanityCabinet
        case vanityTop
        case hardware
        // Fixed in this release.
        case ceiling
        case trim
        case door
        case whiteware
        case showerBase
        case glass
        case glassEdge
        case mirror
        case daylight
        case lamp
        case shadowGap
        case massing

        /// Slots the contractor can change one at a time.
        static let choices: [Slot] = [.floor, .wetWall, .wall, .vanityCabinet, .vanityTop, .hardware]

        var title: String {
            switch self {
            case .floor: "Floor"
            case .wetWall: "Shower tile"
            case .wall: "Paint"
            case .vanityCabinet: "Vanity"
            case .vanityTop: "Counter"
            case .hardware: "Hardware"
            default: rawValue
            }
        }
    }

    struct Tile: Equatable {
        enum Pattern: Equatable {
            case stacked
            /// Each row shifted by this fraction of a tile.
            case offset(Double)
        }

        /// Face size and joint in millimetres, as sold.
        var width: Double
        var height: Double
        var grout: Double
        var pattern: Pattern
        var tileHex: String
        var groutHex: String
        var roughness: Double
        /// Tile to tile shade difference, 0 to 1.
        var variation: Double
        /// Soft clouding within a tile, 0 to 1.
        var mottle: Double

        /// Centre to centre spacing in millimetres.
        var pitchX: Double { width + grout }
        var pitchY: Double { height + grout }
        var rowShift: Double { if case .offset(let fraction) = pattern { fraction } else { 0 } }
        /// Rows before the pattern lines up again.
        var rowsPerRepeat: Int {
            let shift = rowShift
            guard shift > 0 else { return 1 }
            return (1...6).first { abs((Double($0) * shift).rounded() - Double($0) * shift) < 1e-6 } ?? 1
        }
        /// The texture holds a whole number of tiles close to 1.2 m each
        /// way, so shade variation does not visibly repeat in a small room.
        var columns: Int { max(1, Int((1200 / pitchX).rounded())) }
        var rows: Int { rowsPerRepeat * max(1, Int((1200 / (pitchY * Double(rowsPerRepeat))).rounded())) }
        /// Size of one texture repeat in metres. Mapping the texture at
        /// this size is what keeps tile and grout at true scale.
        var repeatWidth: Double { Double(columns) * pitchX / 1000 }
        var repeatHeight: Double { Double(rows) * pitchY / 1000 }
    }

    struct Wood: Equatable {
        var hex: String
        var grainHex: String
        var roughness: Double
        /// Grain runs up the cabinet when true, across it when false.
        var vertical: Bool
    }

    enum Surface: Equatable {
        case paint(hex: String, roughness: Double)
        case tile(Tile)
        case wood(Wood)
        case stone(hex: String, veinHex: String, veining: Double, roughness: Double)
        case metal(hex: String, roughness: Double)
        case glazed(hex: String)
        case glass
        case glassEdge
        case mirror
        case glow(hex: String, strength: Double)
        case flat(hex: String)
    }

    struct Finish: Equatable, Identifiable {
        let id: String
        let slot: Slot
        /// Shown to the contractor and printed on stills. Generic on
        /// purpose: no brand or product is implied.
        let name: String
        let surface: Surface
    }

    struct Look: Equatable, Identifiable {
        let id: String
        let name: String
        let finishes: [Slot: String]
    }

    /// The contractor's choice for one room of one saved revision: a look,
    /// plus any slots changed away from it.
    struct Selection: Equatable, Codable {
        var lookID: String
        var overrides: [Slot: String] = [:]

        init(lookID: String = PreviewFinish.looks[0].id, overrides: [Slot: String] = [:]) {
            self.lookID = lookID
            self.overrides = overrides
        }

        /// The finish for every slot. Unknown ids fall back to the look,
        /// and an unknown look to the first one, so an old file still draws.
        var resolved: [Slot: String] {
            let look = PreviewFinish.looks.first { $0.id == lookID } ?? PreviewFinish.looks[0]
            var result = look.finishes
            for (slot, id) in overrides where PreviewFinish.finish(id)?.slot == slot { result[slot] = id }
            return result
        }

        var look: Look { PreviewFinish.looks.first { $0.id == lookID } ?? PreviewFinish.looks[0] }
    }

    static func finish(_ id: String) -> Finish? { catalog.first { $0.id == id } }
    static func finishes(for slot: Slot) -> [Finish] { catalog.filter { $0.slot == slot } }

    static let catalog: [Finish] = [
        // Floor
        Finish(id: "floor.greige-12x24", slot: .floor, name: "Warm greige porcelain, 12 x 24 in",
               surface: .tile(Tile(width: 610, height: 305, grout: 3, pattern: .offset(1.0 / 3.0),
                                   tileHex: "B9AD9C", groutHex: "9C9285", roughness: 0.42, variation: 0.05, mottle: 0.35))),
        Finish(id: "floor.grey-12x24", slot: .floor, name: "Soft grey porcelain, 12 x 24 in",
               surface: .tile(Tile(width: 610, height: 305, grout: 3, pattern: .offset(0.5),
                                   tileHex: "B4B6B6", groutHex: "8E9192", roughness: 0.4, variation: 0.04, mottle: 0.3))),
        Finish(id: "floor.charcoal-24x24", slot: .floor, name: "Charcoal porcelain, 24 x 24 in",
               surface: .tile(Tile(width: 610, height: 610, grout: 3, pattern: .stacked,
                                   tileHex: "55585A", groutHex: "3F4142", roughness: 0.45, variation: 0.05, mottle: 0.4))),
        // Shower tile
        Finish(id: "wet.ivory-4x12", slot: .wetWall, name: "Ivory ceramic, 4 x 12 in, stacked upright",
               surface: .tile(Tile(width: 100, height: 300, grout: 2, pattern: .stacked,
                                   tileHex: "EFE9DD", groutHex: "D6CFC2", roughness: 0.18, variation: 0.035, mottle: 0.1))),
        Finish(id: "wet.white-3x6", slot: .wetWall, name: "White subway, 3 x 6 in, brick pattern",
               surface: .tile(Tile(width: 150, height: 75, grout: 2, pattern: .offset(0.5),
                                   tileHex: "F4F5F4", groutHex: "B9BCBD", roughness: 0.14, variation: 0.02, mottle: 0.05))),
        Finish(id: "wet.marble-12x24", slot: .wetWall, name: "Marble look porcelain, 12 x 24 in",
               surface: .tile(Tile(width: 610, height: 305, grout: 2, pattern: .offset(0.5),
                                   tileHex: "ECEBE8", groutHex: "D2D1CE", roughness: 0.2, variation: 0.03, mottle: 0.6))),
        // Paint
        Finish(id: "wall.warm-white", slot: .wall, name: "Warm white paint",
               surface: .paint(hex: "EEE8DC", roughness: 0.9)),
        Finish(id: "wall.soft-grey", slot: .wall, name: "Soft grey paint",
               surface: .paint(hex: "D9DCDC", roughness: 0.9)),
        Finish(id: "wall.sage", slot: .wall, name: "Muted sage paint",
               surface: .paint(hex: "C3CCBC", roughness: 0.9)),
        // Vanity
        Finish(id: "vanity.walnut", slot: .vanityCabinet, name: "Walnut flat panel vanity",
               surface: .wood(Wood(hex: "7A5639", grainHex: "4C3221", roughness: 0.5, vertical: false))),
        Finish(id: "vanity.white", slot: .vanityCabinet, name: "White painted vanity",
               surface: .paint(hex: "F2F1EE", roughness: 0.45)),
        Finish(id: "vanity.oak", slot: .vanityCabinet, name: "Natural oak flat panel vanity",
               surface: .wood(Wood(hex: "C2A27C", grainHex: "A38561", roughness: 0.55, vertical: false))),
        Finish(id: "vanity.navy", slot: .vanityCabinet, name: "Navy painted vanity",
               surface: .paint(hex: "2F3D52", roughness: 0.45)),
        // Counter
        Finish(id: "top.white-quartz", slot: .vanityTop, name: "White quartz counter",
               surface: .stone(hex: "F3F1EC", veinHex: "C9C4BA", veining: 0.15, roughness: 0.22)),
        Finish(id: "top.veined-quartz", slot: .vanityTop, name: "Grey veined quartz counter",
               surface: .stone(hex: "EDEDEB", veinHex: "8F9396", veining: 0.6, roughness: 0.2)),
        // Hardware
        Finish(id: "metal.brushed-brass", slot: .hardware, name: "Brushed brass hardware",
               surface: .metal(hex: "C9A560", roughness: 0.32)),
        Finish(id: "metal.chrome", slot: .hardware, name: "Polished chrome hardware",
               surface: .metal(hex: "E4E6E8", roughness: 0.2)),
        Finish(id: "metal.matte-black", slot: .hardware, name: "Matte black hardware",
               surface: .metal(hex: "2A2A2B", roughness: 0.5)),
        // Fixed
        Finish(id: "fixed.ceiling", slot: .ceiling, name: "Flat white ceiling",
               surface: .paint(hex: "F6F4EF", roughness: 0.95)),
        Finish(id: "fixed.trim", slot: .trim, name: "White trim", surface: .paint(hex: "F5F4F0", roughness: 0.5)),
        Finish(id: "fixed.door", slot: .door, name: "White door", surface: .paint(hex: "F3F2EE", roughness: 0.5)),
        Finish(id: "fixed.whiteware", slot: .whiteware, name: "White china", surface: .glazed(hex: "F7F7F5")),
        Finish(id: "fixed.shower-base", slot: .showerBase, name: "White shower base", surface: .glazed(hex: "F2F2F0")),
        Finish(id: "fixed.glass", slot: .glass, name: "Clear glass", surface: .glass),
        Finish(id: "fixed.glass-edge", slot: .glassEdge, name: "Glass edge", surface: .glassEdge),
        Finish(id: "fixed.mirror", slot: .mirror, name: "Mirror", surface: .mirror),
        Finish(id: "fixed.daylight", slot: .daylight, name: "Daylight", surface: .glow(hex: "F4F8FF", strength: 2.2)),
        Finish(id: "fixed.lamp", slot: .lamp, name: "Ceiling light", surface: .glow(hex: "FFF1DC", strength: 3.0)),
        Finish(id: "fixed.shadow-gap", slot: .shadowGap, name: "Shadow gap", surface: .flat(hex: "1E1D1C")),
        Finish(id: "fixed.massing", slot: .massing, name: "Not yet detailed", surface: .paint(hex: "CFCBC4", roughness: 0.8)),
    ]

    private static let fixed: [Slot: String] = [
        .ceiling: "fixed.ceiling", .trim: "fixed.trim", .door: "fixed.door", .whiteware: "fixed.whiteware",
        .showerBase: "fixed.shower-base", .glass: "fixed.glass", .glassEdge: "fixed.glass-edge",
        .mirror: "fixed.mirror", .daylight: "fixed.daylight", .lamp: "fixed.lamp", .shadowGap: "fixed.shadow-gap", .massing: "fixed.massing",
    ]

    static let looks: [Look] = [
        Look(id: "warm-modern", name: "Warm Modern", finishes: fixed.merging([
            .floor: "floor.greige-12x24", .wetWall: "wet.ivory-4x12", .wall: "wall.warm-white",
            .vanityCabinet: "vanity.walnut", .vanityTop: "top.white-quartz", .hardware: "metal.brushed-brass",
        ]) { $1 }),
        Look(id: "bright-neutral", name: "Bright Neutral", finishes: fixed.merging([
            .floor: "floor.grey-12x24", .wetWall: "wet.white-3x6", .wall: "wall.soft-grey",
            .vanityCabinet: "vanity.white", .vanityTop: "top.veined-quartz", .hardware: "metal.chrome",
        ]) { $1 }),
    ]
}

/// The words printed under an exported still. Pure, so the wording rules
/// (plain language, no dashes, every assumption named) can be tested.
enum PreviewCaption {
    static func assumptionText(_ assumptions: [PreviewLayout.Assumption]) -> String? {
        var items: [String] = []
        func add(_ item: String) { if !items.contains(item) { items.append(item) } }
        for assumption in assumptions {
            switch assumption {
            case .ceilingHeight: add("ceiling height")
            case .doorHeight: add("door height")
            case .windowHeight: add("window height")
            case .windowSill: add("window sill height")
            case .bulkheadDrop: add("bulkhead height")
            case .approximateOutline: add("room outline")
            case .genericFixture: break
            }
        }
        guard !items.isEmpty else { return nil }
        return "Not yet confirmed on site: " + items.joined(separator: ", ") + "."
    }

    static func problemText(_ problem: PreviewLayout.Problem, useImperial: Bool = false) -> String {
        func length(_ metres: Double) -> String {
            useImperial ? String(format: "%.1f in", metres / 0.0254) : String(format: "%.0f mm", metres * 1000)
        }
        switch problem {
        case .tooFewCorners: return "The room outline is not a closed shape yet."
        case .noCeilingHeight: return "Enter the ceiling height for this room."
        case .openingOffWall: return "A door or window runs past the end of its wall."
        case .openingAboveCeiling: return "A door or window is taller than the ceiling."
        case .openingsOverlap: return "Two openings on one wall overlap."
        case .interiorWallsNotDrawn(let count):
            return "This room has \(count) interior wall\(count == 1 ? "" : "s"). The preview draws one enclosed room at a time for now. Save the bathroom as its own room."
        case .bulkheadHeightConflict(let drawn, let measured):
            return "The bulkhead is drawn \(length(drawn)) above the floor but measured at \(length(measured))."
        case .fixtureThroughWall(_, let depth): return "A fixture sits \(length(depth)) into a wall."
        case .fixturesOverlap: return "Two fixtures overlap."
        }
    }

    /// Lines for the band under a still, most important first.
    static func lines(revisionTitle: String, savedAt: Date?, roomName: String, look: String,
                      layout: PreviewLayout, useImperial: Bool) -> [String] {
        var first = "Illustration from the drawing: \(roomName), \(revisionTitle)"
        if let savedAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            first += ", saved \(formatter.string(from: savedAt))"
        }
        var lines = [first + ".", "\(look) finishes shown are representative. Confirm colours and products from samples."]
        if let assumed = assumptionText(layout.assumptions) { lines.append(assumed) }
        if layout.assumptions.contains(where: { if case .genericFixture = $0 { true } else { false } }) {
            lines.append("Plain blocks mark items that are not yet detailed.")
        }
        return lines
    }
}
