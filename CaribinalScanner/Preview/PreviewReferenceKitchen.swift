enum PreviewReferenceKitchen {
    static func room() -> CornerRoom {
        var room = CornerRoom(corners: [.init(x: 0, z: 0), .init(x: 4.65, z: 0),
                                        .init(x: 4.65, z: 3.6), .init(x: 0, z: 3.6)],
                              ceilingHeightMeters: 2.44, ceilingHeightSource: .assumed)
        room.openings = [.init(kind: .door, wallIndex: 2, offsetMeters: 1.85, widthMeters: 0.90, heightMeters: 2.03)]
        room.fixtures = [
            .init(kind: .fridge, x: 0.53, z: 0.38, widthMeters: 0.91, depthMeters: 0.76),
            .init(kind: .baseCabinets, x: 1.32, z: 0.305, widthMeters: 0.64, depthMeters: 0.61),
            .init(kind: .kitchenSink, x: 2.09, z: 0.305, widthMeters: 0.90, depthMeters: 0.61),
            .init(kind: .dishwasher, x: 2.85, z: 0.305, widthMeters: 0.60, depthMeters: 0.61),
            .init(kind: .stove, x: 3.56, z: 0.33, widthMeters: 0.76, depthMeters: 0.66),
            .init(kind: .baseCabinets, x: 4.28, z: 0.305, widthMeters: 0.65, depthMeters: 0.61),
            .init(kind: .upperCabinets, x: 2.08, z: 0.165, widthMeters: 2.13, depthMeters: 0.33),
            .init(kind: .microwave, x: 3.56, z: 0.20, widthMeters: 0.76, depthMeters: 0.40),
            .init(kind: .shortUpperCabinet, x: 3.56, z: 0.165, widthMeters: 0.76, depthMeters: 0.33),
            .init(kind: .upperCabinets, x: 4.28, z: 0.165, widthMeters: 0.65, depthMeters: 0.33),
        ]
        return room
    }
}
