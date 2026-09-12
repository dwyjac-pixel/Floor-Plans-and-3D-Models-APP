import Foundation
import SwiftData

/// Seeds a single, realistic sample project the first time the app launches so
/// a new user has something to open — a real plan, estimate, and 3D-less
/// geometry — without needing a LiDAR device or a scan.
///
/// Seeding happens at most once per device (guarded by a UserDefaults flag)
/// and only when no projects exist. With CloudKit sync, a second device can
/// still seed before the first sync arrives (the store looks empty), so the
/// sample carries a CONSTANT folderName that only the seeder ever writes —
/// `dedupeSamples` then converges every device onto one copy. User projects
/// always have UUID folder names, so the dedupe can never touch them.
enum SampleProject {
    private static let seededFlag = "didSeedSampleProject"

    /// Fixed identity for the seeded sample across all devices.
    static let sampleFolderName = "sample-24-oak-st"

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
            name: "Sample: 24 Oak St (Basement Suite)",
            clientName: "Jordan Example",
            address: "24 Oak St, Calgary, AB",
            projectType: "Legal Secondary Suite"
        )
        project.folderName = sampleFolderName
        context.insert(project)
        try? context.save()

        // In cloud mode another device may have seeded (and edited) the
        // sample already — its manual_room.json can exist here as a real
        // file or an undownloaded placeholder. Never write defaults over
        // either; the row dedupe converges the rest.
        let existingGeometry = (try? ScanStore.folder(for: project))
            .map { dir -> Bool in
                let target = dir.appendingPathComponent(ScanStore.manualRoomFileName)
                return FileManager.default.fileExists(atPath: target.path)
                    || ScanStore.isAwaitingDownload(target)
            } ?? false
        if !existingGeometry {
            try? ScanStore.saveManualRoom(defaultRoom(), for: project)
        }

        defaults.set(true, forKey: seededFlag)
    }

    /// Samples seeded before the dash was dropped from the name still carry
    /// it; retitle them once so the list matches new installs.
    @MainActor
    static func retitleLegacySample(context: ModelContext) {
        let legacyName = "Sample \u{2014} 24 Oak St (Basement Suite)"
        let all = (try? context.fetch(FetchDescriptor<RenovationProject>())) ?? []
        let stale = all.filter { $0.folderName == sampleFolderName && $0.name == legacyName }
        guard !stale.isEmpty else { return }
        for sample in stale {
            sample.name = "Sample: 24 Oak St (Basement Suite)"
        }
        try? context.save()
    }

    /// Collapses duplicate samples after CloudKit merges. Every device runs
    /// this independently, so the survivor choice must be deterministic:
    /// earliest createdAt, tie-broken by the stable id string. Extra rows
    /// share the constant folder, so deleting them never touches files.
    @MainActor
    static func dedupeSamples(context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<RenovationProject>())) ?? []
        let samples = all.filter { $0.folderName == sampleFolderName }
        guard samples.count > 1 else { return }
        let ordered = samples.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return "\($0.persistentModelID)" < "\($1.persistentModelID)"
        }
        for extra in ordered.dropFirst() {
            context.delete(extra)
        }
        try? context.save()
    }

    /// A CloudKit-delivered sample row can arrive on a device where the
    /// room FILE cannot follow (iCloud Drive off for the app while CloudKit
    /// still syncs). Only then — file sync inactive and no plan source of
    /// any kind present — rebuild the sample's geometry. Never runs in
    /// cloud mode, where writing would race the file's own arrival.
    @MainActor
    static func ensureSampleGeometry(context: ModelContext) {
        guard !ScanStore.isCloudRoot else { return }
        let all = (try? context.fetch(FetchDescriptor<RenovationProject>())) ?? []
        guard let sample = all.first(where: { $0.folderName == sampleFolderName }),
              ScanStore.loadManualRoom(for: sample) == nil,
              ScanStore.loadRooms(for: sample).isEmpty,
              ScanStore.roomDataURL(for: sample) == nil else { return }
        try? ScanStore.saveManualRoom(defaultRoom(), for: sample)
        // Backdate the rebuilt default so it can never outrank a real
        // cloud copy in a future mtime-newest-wins merge (the migration
        // only overwrites on strictly-newer local dates).
        if let dir = try? ScanStore.folder(for: sample) {
            let path = dir.appendingPathComponent(ScanStore.manualRoomFileName).path
            try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)],
                                                   ofItemAtPath: path)
        }
    }

    /// The sample's geometry: a simple rectangle (~6.1m x 4.3m) with a door
    /// and a window and a 2.05m ceiling, saved as a ManualRoom so the
    /// plan/estimate open with real data.
    private static func defaultRoom() -> ManualRoom {
        var room = ManualRoom()
        room.widthMeters = 6.1
        room.lengthMeters = 4.3
        room.ceilingHeightMeters = 2.05
        room.features = [
            ManualRoom.Feature(kind: .door, wallIndex: 3, offsetMeters: 1.5, widthMeters: 0.9),
            ManualRoom.Feature(kind: .window, wallIndex: 0, offsetMeters: 2.4, widthMeters: 1.2)
        ]
        return room
    }
}
