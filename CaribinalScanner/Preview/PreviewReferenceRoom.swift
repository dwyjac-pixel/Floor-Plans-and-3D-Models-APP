import Foundation

/// A small basement bathroom with every dimension stated, used as the
/// quality reference for the finished preview and as the sample a
/// contractor can open before they have drawn a bathroom of their own.
/// Offset from the plan origin on purpose, so placement bugs show.
enum PreviewReferenceRoom {
    static let name = "Sample bathroom"

    static func bathroom() -> CornerRoom {
        var room = CornerRoom(corners: [.init(x: 10.0, z: 20.0), .init(x: 12.8, z: 20.0),
                                        .init(x: 12.8, z: 21.6), .init(x: 10.0, z: 21.6)],
                              ceilingHeightMeters: 2.134, ceilingHeightSource: .fieldMeasured)
        room.bulkheadClearanceMeters = 1.934
        room.openings = [
            .init(kind: .door, wallIndex: 3, offsetMeters: 0.150, widthMeters: 0.762, heightMeters: 1.930),
            .init(kind: .window, wallIndex: 2, offsetMeters: 1.000, widthMeters: 0.600,
                  sillMeters: 1.600, heightMeters: 0.400),
        ]
        room.fixtures = [
            .init(kind: .vanity, x: 10.530, z: 20.275, widthMeters: 0.760, depthMeters: 0.550),
            .init(kind: .toilet, x: 11.400, z: 20.355, widthMeters: 0.500, depthMeters: 0.710),
            .init(kind: .shower, x: 12.400, z: 20.800, widthMeters: 1.600, depthMeters: 0.800, rotationDegrees: 90),
            .init(kind: .bulkhead, x: 11.400, z: 20.150, widthMeters: 2.800, depthMeters: 0.300, dropMeters: 0.200),
        ]
        room.floorType = .tile
        return room
    }
}
