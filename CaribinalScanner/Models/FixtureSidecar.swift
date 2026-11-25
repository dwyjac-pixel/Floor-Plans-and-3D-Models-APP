import Foundation

/// Keeps fixture kinds that versions up to 1.0.2 cannot read out of the
/// files those versions rewrite.
///
/// 1.0.2 skips a fixture whose kind it does not know, then saves the room,
/// and every saved revision, without it. So a kind added after 1.0.2 is
/// never written into rooms.json or plan_history.json. It is written into
/// `fixtures_extra.json` in the same project folder, which those versions
/// never open, and is put back when the room is read. On an older device
/// the room shows without those fixtures. Nothing is lost: they are there
/// again on any device with this version.
///
/// Everything here works on encoded JSON. The room model is unchanged, and
/// a kind this version cannot read either (from a later version) is carried
/// through every save untouched.
enum FixtureSidecar {
    static let fileName = "fixtures_extra.json"

    /// The kinds 1.0.2 reads. Never add to this list. A new kind belongs
    /// in the sidecar for as long as any device may run a version that
    /// drops kinds it does not know.
    static let legacyKinds: Set<String> = [
        "Base Cabinets & Countertop", "Upper Cabinets", "Island & Countertop", "Refrigerator", "Stove",
        "Toilet", "Vanity", "Tub / Shower", "Shower Stall", "Queen Bed", "Single Bed", "Dresser", "Sofa",
        "Washer", "Dryer", "Furnace", "Water Heater", "Stairs", "Bulkhead (Dropped Ceiling)",
    ]

    /// How a save treats fixtures already in the sidecar.
    enum Mode {
        /// The rooms being saved were read together with this exact
        /// sidecar, so they are the whole truth: a fixture missing from
        /// them was deleted.
        case replace
        /// The sidecar changed, or could not be read, since the rooms were
        /// read. Nothing already stored is dropped.
        case keepStored
    }

    private typealias Object = [String: Any]

    private static func parse(_ data: Data?) -> Object? {
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? Object
    }

    private static func write(_ object: Object) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func kind(_ fixture: Any) -> String? { (fixture as? Object)?["kind"] as? String }
    private static func id(_ item: Any) -> String? { (item as? Object)?["id"] as? String }

    /// A fixture with no readable kind is left where it is.
    private static func isLegacy(_ fixture: Any) -> Bool { kind(fixture).map(legacyKinds.contains) ?? true }

    /// A stored fixture this version cannot read: a kind from a later version.
    private static func isUnreadable(_ fixture: Any) -> Bool {
        guard let kind = kind(fixture) else { return true }
        return CornerRoom.Fixture.Kind(rawValue: kind) == nil
    }

    /// The sidecar's bytes as this version would write them, for telling
    /// whether a save changes anything.
    static func canonical(_ data: Data?) -> Data? { parse(data).flatMap(write) }

    // MARK: Moving fixtures out and back

    /// Takes the newer kinds out of each room and returns them by room id,
    /// together with whatever must be kept from what was stored before.
    private static func strip(_ entries: [Any], stored: Object, mode: Mode) -> (entries: [Any], extras: Object) {
        var extras: Object = mode == .keepStored ? stored : [:]
        let cleaned = entries.map { item -> Any in
            guard var entry = item as? Object, let roomID = entry["id"] as? String,
                  var room = entry["room"] as? Object else { return item }
            let fixtures = room["fixtures"] as? [Any] ?? []
            let present = Set(fixtures.compactMap(id))
            let before = stored[roomID] as? [Any] ?? []
            let kept = before.filter { old in
                if isUnreadable(old) { return true }
                // A fixture this version can read is in the room being
                // saved, or it was deleted. It is only kept when the room
                // cannot be trusted to be complete.
                return mode == .keepStored && !(id(old).map(present.contains) ?? false)
            }
            let moved = fixtures.filter { !isLegacy($0) }
            if !moved.isEmpty { room["fixtures"] = fixtures.filter(isLegacy) }
            entry["room"] = room
            let all = moved + kept
            extras[roomID] = all.isEmpty ? nil : all
            return entry
        }
        return (cleaned, extras)
    }

    /// Puts stored fixtures back into their rooms. One already in the room
    /// (a file written before the sidecar existed) is not added twice.
    private static func restore(_ entries: [Any], extras: Object) -> [Any] {
        entries.map { item -> Any in
            guard var entry = item as? Object, let roomID = entry["id"] as? String,
                  let added = extras[roomID] as? [Any], !added.isEmpty,
                  var room = entry["room"] as? Object else { return item }
            let fixtures = room["fixtures"] as? [Any] ?? []
            let present = Set(fixtures.compactMap(id))
            room["fixtures"] = fixtures + added.filter { !(id($0).map(present.contains) ?? false) }
            entry["room"] = room
            return entry
        }
    }

    private static func sidecar(rooms: Object, revisions: Object, existed: Bool) -> Data? {
        if rooms.isEmpty, revisions.isEmpty, !existed { return nil }
        return write(["version": 1, "rooms": rooms, "revisions": revisions])
    }

    // MARK: rooms.json

    /// Rooms as read from disk, with their stored fixtures put back.
    /// Anything that cannot be parsed is returned as it came.
    static func mergeRooms(_ file: Data, sidecar: Data?) -> Data {
        guard let extras = parse(sidecar)?["rooms"] as? Object, !extras.isEmpty,
              var root = parse(file), let entries = root["rooms"] as? [Any] else { return file }
        root["rooms"] = restore(entries, extras: extras)
        return write(root) ?? file
    }

    /// What to write for a rooms save: the file older versions can safely
    /// rewrite, and the sidecar. The sidecar is nil when there is nothing
    /// to store and none existed. Returns nil when the rooms, or a sidecar
    /// that exists, cannot be parsed: the caller then writes the rooms
    /// whole and leaves the sidecar alone.
    static func splitRooms(_ encoded: Data, sidecar stored: Data?, mode: Mode) -> (file: Data, sidecar: Data?)? {
        guard var root = parse(encoded), let entries = root["rooms"] as? [Any] else { return nil }
        let previous = parse(stored)
        if stored != nil, previous == nil { return nil }
        let split = strip(entries, stored: previous?["rooms"] as? Object ?? [:], mode: mode)
        var extras = split.extras
        if mode == .replace {
            // A room that is gone takes its stored fixtures with it.
            let ids = Set(entries.compactMap(id))
            extras = extras.filter { ids.contains($0.key) }
        }
        root["rooms"] = split.entries
        guard let file = write(root) else { return nil }
        return (file, sidecar(rooms: extras, revisions: previous?["revisions"] as? Object ?? [:], existed: stored != nil))
    }

    // MARK: plan_history.json

    private static func snapshots(_ root: Object) -> [Object] {
        var all = root["proposedRevisions"] as? [Any] ?? []
        if let first = root["existingConditions"] { all.insert(first, at: 0) }
        return all.compactMap { $0 as? Object }
    }

    private static func mapSnapshots(_ root: Object, _ change: (Object) -> Object) -> Object {
        var root = root
        if let first = root["existingConditions"] as? Object { root["existingConditions"] = change(first) }
        if let later = root["proposedRevisions"] as? [Any] {
            root["proposedRevisions"] = later.map { ($0 as? Object).map(change) ?? $0 }
        }
        return root
    }

    /// Plan history as read from disk, with each saved revision's stored
    /// fixtures put back.
    static func mergeHistory(_ file: Data, sidecar: Data?) -> Data {
        guard let revisions = parse(sidecar)?["revisions"] as? Object, !revisions.isEmpty,
              let root = parse(file) else { return file }
        let merged = mapSnapshots(root) { snapshot in
            guard let snapshotID = snapshot["id"] as? String, let extras = revisions[snapshotID] as? Object,
                  let entries = snapshot["rooms"] as? [Any] else { return snapshot }
            var snapshot = snapshot
            snapshot["rooms"] = restore(entries, extras: extras)
            return snapshot
        }
        return write(merged) ?? file
    }

    /// What to write for a plan history save. A saved revision never
    /// changes, so nothing already stored for one is ever dropped.
    static func splitHistory(_ encoded: Data, sidecar stored: Data?) -> (file: Data, sidecar: Data?)? {
        guard let root = parse(encoded), !snapshots(root).isEmpty else { return nil }
        let previous = parse(stored)
        if stored != nil, previous == nil { return nil }
        var revisions = previous?["revisions"] as? Object ?? [:]
        let cleaned = mapSnapshots(root) { snapshot in
            guard let snapshotID = snapshot["id"] as? String, let entries = snapshot["rooms"] as? [Any] else { return snapshot }
            let split = strip(entries, stored: revisions[snapshotID] as? Object ?? [:], mode: .keepStored)
            revisions[snapshotID] = split.extras.isEmpty ? nil : split.extras
            var snapshot = snapshot
            snapshot["rooms"] = split.entries
            return snapshot
        }
        guard let file = write(cleaned) else { return nil }
        return (file, sidecar(rooms: previous?["rooms"] as? Object ?? [:], revisions: revisions, existed: stored != nil))
    }
}
