import Foundation

/// A hand-measured room — the fallback when the device has no LiDAR or a
/// scan isn't practical. A main rectangle plus optional bump-outs for
/// L-shapes, with doors/windows/openings along the main walls. Converts to
/// FloorPlanModel for display and reporting, exactly like a scanned room.
struct ManualRoom: Codable {
    struct Feature: Codable, Identifiable {
        enum Kind: String, Codable, CaseIterable, Identifiable {
            case door = "Door"
            case closetDoor = "Closet Door"
            case window = "Window"
            case opening = "Opening"

            var id: String { rawValue }
        }

        var id = UUID()
        var kind: Kind
        var wallIndex: Int        // 0-3, clockwise: top, right, bottom, left
        var offsetMeters: Double  // from the wall's starting corner, clockwise
        var widthMeters: Double
    }

    /// A rectangular section that extends the room outward from one of the
    /// main rectangle's walls — for L-shaped basements and bump-outs.
    struct BumpOut: Codable, Identifiable {
        var id = UUID()
        var wallIndex: Int        // wall of the main rectangle it attaches to
        var offsetMeters: Double  // from the wall's starting corner
        var widthMeters: Double   // along the wall
        var depthMeters: Double   // outward from the wall
    }

    static let wallNames = ["Top wall", "Right wall", "Bottom wall", "Left wall"]

    var widthMeters: Double = 0
    var lengthMeters: Double = 0
    var ceilingHeightMeters: Double = 0
    var features: [Feature] = []
    var bumpOuts: [BumpOut] = []

    init() {}

    // Custom decoding so files saved before bump-outs existed still load.
    private enum CodingKeys: String, CodingKey {
        case widthMeters, lengthMeters, ceilingHeightMeters, features, bumpOuts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        widthMeters = try container.decodeIfPresent(Double.self, forKey: .widthMeters) ?? 0
        lengthMeters = try container.decodeIfPresent(Double.self, forKey: .lengthMeters) ?? 0
        ceilingHeightMeters = try container.decodeIfPresent(Double.self, forKey: .ceilingHeightMeters) ?? 0
        features = try container.decodeIfPresent([Feature].self, forKey: .features) ?? []
        bumpOuts = try container.decodeIfPresent([BumpOut].self, forKey: .bumpOuts) ?? []
    }

    /// A single, non-overlapping bump-out interval along one main wall,
    /// clamped to the wall length.
    struct MergedBump {
        var from: Double
        var to: Double
        var depth: Double   // deepest of any bumps that merged together
    }

    /// The bump-outs on `wall`, normalised and merged so overlapping or
    /// touching intervals become one rectangle. Both conversion paths
    /// (`CornerRoom(manual:)` and `FloorPlanModel(manual:)`) consume this so
    /// their outline geometry and floor-area sum agree; without the merge,
    /// overlapping bump-outs produce a self-overlapping outline, doubled
    /// walls, and double-counted area.
    func mergedBumpOuts(forWall wall: Int, wallLength: Double) -> [MergedBump] {
        let normalised = bumpOuts
            .filter { min(max($0.wallIndex, 0), 3) == wall }
            .compactMap { bump -> MergedBump? in
                let from = min(max(bump.offsetMeters, 0), wallLength)
                let to = min(from + max(bump.widthMeters, 0.3), wallLength)
                let depth = bump.depthMeters
                guard to > from + 0.01, depth >= 0.1 else { return nil }
                return MergedBump(from: from, to: to, depth: depth)
            }
            .sorted { $0.from < $1.from }

        var merged: [MergedBump] = []
        for bump in normalised {
            if var last = merged.last, bump.from <= last.to + 0.01 {
                last.to = max(last.to, bump.to)
                last.depth = max(last.depth, bump.depth)
                merged[merged.count - 1] = last
            } else {
                merged.append(bump)
            }
        }
        return merged
    }
}
