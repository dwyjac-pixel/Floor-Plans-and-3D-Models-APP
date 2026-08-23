import Foundation

/// Room captured by marking floor corners with the camera (ARKit, no LiDAR
/// required), then optionally edited: interior walls (closets, partitions),
/// doors/windows/openings on the outline walls, and kitchen fixtures.
/// Coordinates are metres in the AR session's world space; only x/z
/// (horizontal) are used.
struct CornerRoom: Codable {
    struct Point: Codable {
        var x: Double
        var z: Double
    }

    /// Whole-room floor finish, rendered in the 3D model.
    enum FloorType: String, Codable, CaseIterable, Identifiable {
        case vinylPlank = "Vinyl Plank"
        case laminate = "Laminate"
        case hardwood = "Hardwood"
        case carpet = "Carpet"
        case tile = "Tile"
        case concrete = "Concrete (bare)"

        var id: String { rawValue }
    }

    /// A straight interior wall segment (partition, closet side).
    struct InteriorWall: Codable, Identifiable {
        var id = UUID()
        var start: Point
        var end: Point
        var paintHex: String?     // nil = default wall finish

        var lengthMeters: Double {
            let dx = end.x - start.x
            let dz = end.z - start.z
            return (dx * dx + dz * dz).squareRoot()
        }

        init(id: UUID = UUID(), start: Point, end: Point, paintHex: String? = nil) {
            self.id = id
            self.start = start
            self.end = end
            self.paintHex = paintHex
        }

        private enum CodingKeys: String, CodingKey {
            case id, start, end, paintHex
        }

        // Tolerant decode: a missing/legacy key falls back to a default
        // rather than voiding the whole room (mirrors ManualRoom).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            start = try c.decode(Point.self, forKey: .start)
            end = try c.decode(Point.self, forKey: .end)
            paintHex = try c.decodeIfPresent(String.self, forKey: .paintHex)
        }
    }

    /// A door, window, or cased opening on an outline wall.
    struct Opening: Codable, Identifiable {
        enum Kind: String, Codable, CaseIterable, Identifiable {
            case door = "Door"
            case closetDoor = "Closet Door"
            case window = "Window"
            case opening = "Opening"

            var id: String { rawValue }

            /// Placement width until the user edits it: 32" standard door,
            /// 60" closet (bifold pair), 4' window, 5' cased opening.
            var defaultWidthMeters: Double {
                switch self {
                case .door: 0.81
                case .closetDoor: 1.52
                case .window: 1.2
                case .opening: 1.5
                }
            }
        }

        var id = UUID()
        var kind: Kind
        var wallIndex: Int        // outline wall (corner index)…
        var interiorWallID: UUID? // …or an interior wall; overrides wallIndex
        var offsetMeters: Double  // from the wall's starting corner/endpoint
        var widthMeters: Double
        var sillMeters: Double?   // windows only; nil = 0.91 m default
        var heightMeters: Double? // window height (nil = 1.07 m) / door height (nil = 2.03 m)
        var clearWidthMeters: Double?   // unobstructed (egress) opening — windows
        var clearHeightMeters: Double?
        var hingeOnEnd: Bool?     // doors: hinge at the far jamb (nil = near)
        var swingsOutward: Bool?  // doors: swing away from the room interior
    }

    /// Kitchen fixtures placed on the plan; rendered as footprints in 2D
    /// and boxes (with countertops) in 3D.
    struct Fixture: Codable, Identifiable {
        enum Kind: String, Codable, CaseIterable, Identifiable {
            case baseCabinets = "Base Cabinets & Countertop"
            case upperCabinets = "Upper Cabinets"
            case island = "Island & Countertop"
            case fridge = "Refrigerator"
            case stove = "Stove"
            case toilet = "Toilet"
            case vanity = "Vanity"
            case tubShower = "Tub / Shower"
            case shower = "Shower Stall"
            case bedQueen = "Queen Bed"
            case bedSingle = "Single Bed"
            case dresser = "Dresser"
            case sofa = "Sofa"
            case washer = "Washer"
            case dryer = "Dryer"
            case furnace = "Furnace"
            case waterHeater = "Water Heater"
            case stairs = "Stairs"
            case bulkhead = "Bulkhead (Dropped Ceiling)"

            var id: String { rawValue }

            enum Category: String, CaseIterable, Identifiable {
                case kitchen = "Kitchen"
                case bathroom = "Bathroom"
                case bedroomLiving = "Bedroom & Living"
                case utility = "Utility & Stairs"

                var id: String { rawValue }
            }

            var category: Category {
                switch self {
                case .baseCabinets, .upperCabinets, .island, .fridge, .stove: .kitchen
                case .toilet, .vanity, .tubShower, .shower: .bathroom
                case .bedQueen, .bedSingle, .dresser, .sofa: .bedroomLiving
                case .washer, .dryer, .furnace, .waterHeater, .stairs, .bulkhead: .utility
                }
            }

            var sfSymbol: String {
                switch self {
                case .baseCabinets, .upperCabinets, .dresser: "cabinet"
                case .island: "table.furniture"
                case .fridge: "refrigerator"
                case .stove: "stove"
                case .toilet: "toilet"
                case .vanity: "sink"
                case .tubShower: "bathtub"
                case .shower: "shower"
                case .bedQueen, .bedSingle: "bed.double"
                case .sofa: "sofa"
                case .washer: "washer"
                case .dryer: "dryer"
                case .furnace: "flame"
                case .waterHeater: "water.waves"
                case .stairs: "stairs"
                case .bulkhead: "arrow.down.to.line"
                }
            }

            var shortLabel: String {
                switch self {
                case .baseCabinets: "Cabinets"
                case .upperCabinets: "Uppers"
                case .island: "Island"
                case .fridge: "Fridge"
                case .stove: "Stove"
                case .toilet: "WC"
                case .vanity: "Vanity"
                case .tubShower: "Tub"
                case .shower: "Shower"
                case .bedQueen, .bedSingle: "Bed"
                case .dresser: "Dresser"
                case .sofa: "Sofa"
                case .washer: "W"
                case .dryer: "D"
                case .furnace: "Furnace"
                case .waterHeater: "WH"
                case .stairs: "Stairs"
                case .bulkhead: "Bulkhead"
                }
            }

            var defaultSize: (width: Double, depth: Double) {
                switch self {
                case .baseCabinets: (2.4, 0.61)
                case .upperCabinets: (2.4, 0.33)
                case .island: (1.8, 0.91)
                case .fridge: (0.91, 0.76)
                case .stove: (0.76, 0.66)
                case .toilet: (0.5, 0.71)
                case .vanity: (0.9, 0.55)
                case .tubShower: (1.52, 0.76)
                case .shower: (0.91, 0.91)
                case .bedQueen: (1.53, 2.03)
                case .bedSingle: (0.99, 1.91)
                case .dresser: (1.5, 0.51)
                case .sofa: (2.2, 0.95)
                case .washer: (0.69, 0.76)
                case .dryer: (0.69, 0.76)
                case .furnace: (0.71, 0.91)
                case .waterHeater: (0.61, 0.61)
                case .stairs: (3.0, 0.91)
                case .bulkhead: (2.4, 0.6)
                }
            }
        }

        var id = UUID()
        var kind: Kind
        var x: Double             // centre, plan space
        var z: Double
        var widthMeters: Double
        var depthMeters: Double
        var rotationDegrees: Double = 0
        var dropMeters: Double?   // bulkheads: how far below the ceiling
    }

    /// Host geometry for an opening — outline wall or interior wall.
    func hostWall(for opening: Opening) -> (start: Point, ux: Double, uz: Double, length: Double)? {
        let a: Point
        let b: Point
        if let interiorID = opening.interiorWallID {
            guard let wall = interiorWalls.first(where: { $0.id == interiorID }) else { return nil }
            a = wall.start
            b = wall.end
        } else {
            guard corners.count >= 2,
                  opening.wallIndex >= 0, opening.wallIndex < corners.count else { return nil }
            a = corners[opening.wallIndex]
            b = corners[(opening.wallIndex + 1) % corners.count]
        }
        let dx = b.x - a.x
        let dz = b.z - a.z
        let length = (dx * dx + dz * dz).squareRoot()
        guard length > 0.01 else { return nil }
        return (a, dx / length, dz / length, length)
    }

    var corners: [Point] = []
    var ceilingHeightMeters: Double = 0
    var interiorWalls: [InteriorWall] = []
    var openings: [Opening] = []
    var fixtures: [Fixture] = []
    /// Set by the tape-measure accuracy check: the correction (%) that was
    /// applied to match a site measurement. Printed on reports.
    var verifiedAccuracyPercent: Double?
    /// Whole-room floor finish; nil = builder default.
    var floorType: FloorType?
    /// Floor tint; nil = the finish's natural colour.
    var floorHex: String?
    /// Paint per outline wall (wall index → hex); indexes are fixed up
    /// when walls split or merge.
    var outlineWallHex: [Int: String] = [:]

    init() {}

    init(corners: [Point], ceilingHeightMeters: Double) {
        self.corners = corners
        self.ceilingHeightMeters = ceilingHeightMeters
    }

    // Custom decoding so files saved by earlier versions still load.
    private enum CodingKeys: String, CodingKey {
        case corners, ceilingHeightMeters, interiorWalls, openings, fixtures,
             verifiedAccuracyPercent, floorType, floorHex, outlineWallHex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        corners = try container.decodeIfPresent([Point].self, forKey: .corners) ?? []
        ceilingHeightMeters = try container.decodeIfPresent(Double.self, forKey: .ceilingHeightMeters) ?? 0
        // Element-tolerant: one unreadable interior wall / opening / fixture
        // is skipped rather than voiding the whole room.
        interiorWalls = (try container.decodeIfPresent([LossyDecodable<InteriorWall>].self, forKey: .interiorWalls) ?? []).compactMap { $0.value }
        openings = (try container.decodeIfPresent([LossyDecodable<Opening>].self, forKey: .openings) ?? []).compactMap { $0.value }
        fixtures = (try container.decodeIfPresent([LossyDecodable<Fixture>].self, forKey: .fixtures) ?? []).compactMap { $0.value }
        verifiedAccuracyPercent = try container.decodeIfPresent(Double.self, forKey: .verifiedAccuracyPercent)
        floorType = try container.decodeIfPresent(FloorType.self, forKey: .floorType)
        floorHex = try container.decodeIfPresent(String.self, forKey: .floorHex)
        outlineWallHex = try container.decodeIfPresent([Int: String].self, forKey: .outlineWallHex) ?? [:]
    }
}

/// Wraps a `Decodable` so a failed element decode yields `nil` instead of
/// throwing — decoding an array of these and compact-mapping drops only the
/// bad elements. The wrapper itself never throws, so the surrounding
/// unkeyed container always advances correctly past a skipped element.
private struct LossyDecodable<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

// Tolerant decoders for the nested value types: a missing/legacy key (e.g.
// a fixture saved before `rotationDegrees` existed) falls back to a default
// rather than throwing `keyNotFound` and voiding the entire room. Declared
// in extensions so the synthesized memberwise initializers stay available.
extension CornerRoom.Opening {
    private enum CodingKeys: String, CodingKey {
        case id, kind, wallIndex, interiorWallID, offsetMeters, widthMeters,
             sillMeters, heightMeters, clearWidthMeters, clearHeightMeters,
             hingeOnEnd, swingsOutward
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        self.init(id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
                  kind: kind,
                  wallIndex: try c.decodeIfPresent(Int.self, forKey: .wallIndex) ?? 0,
                  interiorWallID: try c.decodeIfPresent(UUID.self, forKey: .interiorWallID),
                  offsetMeters: try c.decodeIfPresent(Double.self, forKey: .offsetMeters) ?? 0,
                  widthMeters: try c.decodeIfPresent(Double.self, forKey: .widthMeters) ?? kind.defaultWidthMeters,
                  sillMeters: try c.decodeIfPresent(Double.self, forKey: .sillMeters),
                  heightMeters: try c.decodeIfPresent(Double.self, forKey: .heightMeters),
                  clearWidthMeters: try c.decodeIfPresent(Double.self, forKey: .clearWidthMeters),
                  clearHeightMeters: try c.decodeIfPresent(Double.self, forKey: .clearHeightMeters),
                  hingeOnEnd: try c.decodeIfPresent(Bool.self, forKey: .hingeOnEnd),
                  swingsOutward: try c.decodeIfPresent(Bool.self, forKey: .swingsOutward))
    }
}

extension CornerRoom.Fixture {
    private enum CodingKeys: String, CodingKey {
        case id, kind, x, z, widthMeters, depthMeters, rotationDegrees, dropMeters
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        self.init(id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
                  kind: kind,
                  x: try c.decodeIfPresent(Double.self, forKey: .x) ?? 0,
                  z: try c.decodeIfPresent(Double.self, forKey: .z) ?? 0,
                  widthMeters: try c.decodeIfPresent(Double.self, forKey: .widthMeters) ?? kind.defaultSize.width,
                  depthMeters: try c.decodeIfPresent(Double.self, forKey: .depthMeters) ?? kind.defaultSize.depth,
                  rotationDegrees: try c.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0,
                  dropMeters: try c.decodeIfPresent(Double.self, forKey: .dropMeters))
    }
}
