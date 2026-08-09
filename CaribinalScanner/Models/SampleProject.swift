import Foundation
import SwiftData

/// Seeds a single, realistic sample project the first time the app launches so
/// a new user has something to open — a real plan, estimate, and 3D-less
/// geometry — without needing a LiDAR device or a scan.
///
/// Seeding happens at most once ever (guarded by a UserDefaults flag) and only
/// when no projects exist. If the user has already created (or deleted the
/// sample) projects, the flag is still set so we never seed over them.
enum SampleProject {
    private static let seededFlag = "didSeedSampleProject"

    @MainActor
    static func seedIfNeeded(context: ModelContext) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: seededFlag) else { return }

        // Never seed on top of an existing user. If any projects exist, mark
        // as seeded so a later deletion of the sample can't re-seed it.
        let existing = (try? context.fetch(FetchDescriptor<RenovationProject>())) ?? []
        guard existing.isEmpty else {
            defaults.set(true, forKey: seededFlag)
            return
        }

        let project = RenovationProject(
            name: "Sample — 24 Oak St (Basement Suite)",
            clientName: "Jordan Example",
            address: "24 Oak St, Calgary, AB",
            projectType: "Legal Secondary Suite"
        )
        context.insert(project)
        try? context.save()

        // Give the sample real geometry without LiDAR: a simple rectangle
        // (~6.1m x 4.3m) with a door and a window and a 2.05m ceiling, saved as
        // a ManualRoom so the plan/estimate open with real data.
        var room = ManualRoom()
        room.widthMeters = 6.1
        room.lengthMeters = 4.3
        room.ceilingHeightMeters = 2.05
        room.features = [
            ManualRoom.Feature(kind: .door, wallIndex: 3, offsetMeters: 1.5, widthMeters: 0.9),
            ManualRoom.Feature(kind: .window, wallIndex: 0, offsetMeters: 2.4, widthMeters: 1.2)
        ]

        try? ScanStore.saveManualRoom(room, for: project)

        defaults.set(true, forKey: seededFlag)
    }
}
