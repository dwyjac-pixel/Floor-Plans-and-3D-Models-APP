import Foundation
import RoomPlan
import UIKit

/// Manages the files that belong to a project: the exported USDZ model,
/// the encoded CapturedRoom data used to draw the floor plan, and photos.
/// Everything lives under Projects/<folderName>/ — inside the iCloud Drive
/// container's Documents/ when iCloud is available (synced across devices,
/// visible in Files under iCloud Drive), else under local Documents/
/// (visible in Files via file sharing, exactly as before).
enum ScanStore {
    static let usdzFileName = "scan.usdz"
    static let lidarUSDZFileName = "lidar_scan.usdz"
    static let roomDataFileName = "room.json"
    static let manualRoomFileName = "manual_room.json"
    static let cornerRoomFileName = "corner_room.json"
    static let roomsFileName = "rooms.json"
    static let estimateFileName = "estimate.json"
    static let takeoffAdjustmentsFileName = "takeoff_adjustments.json"
    static let aiChatFileName = "ai_chat.json"
    static let roiFileName = "roi.json"
    static let planningFileName = "planning.json"
    static let permitMeasurementsFileName = "permit_measurements.json"
    static let quoteSettingsFileName = "quote_settings.json"
    static let markersFileName = "markers.json"
    static let scanWalksFileName = "scan_walks.json"
    static let aiContextFileName = "ai_context.json"
    static let photoCaptionsFileName = "photo_captions.json"
    static let photosFolderName = "photos"

    // MARK: - Storage root (local vs iCloud Drive)

    /// The root every path derives from. Pinned exactly once per launch by
    /// `bootstrap()` BEFORE the first view renders, and never changed while
    /// the app runs — screens capture folder URLs in their inits, so a
    /// mid-session root switch would silently split reads and writes across
    /// two trees. Falls back to the local root if somehow read pre-bootstrap.
    static var projectsRoot: URL {
        rootLock.lock()
        defer { rootLock.unlock() }
        return cachedRoot ?? localProjectsRoot
    }

    /// True when this session is using the iCloud Drive container.
    static var isCloudRoot: Bool {
        rootLock.lock()
        defer { rootLock.unlock() }
        if let cachedRoot { return cachedRoot != localProjectsRoot }
        return false
    }

    private static let rootLock = NSLock()
    private static var cachedRoot: URL?

    static let cloudContainerID = "iCloud.com.caribinalcreations.scanner"

    static var localProjectsRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Projects", isDirectory: true)
    }

    /// Resolves the storage root and migrates local projects into iCloud.
    /// Must complete before the first view renders (the app gates on it).
    /// `url(forUbiquityContainerIdentifier:)` can block, so this runs off
    /// the main actor; when iCloud is unavailable (signed out, disabled for
    /// the app, missing entitlement) everything stays local and keeps
    /// working exactly as before.
    ///
    /// The cloud root lives under the container's Documents/ so the
    /// projects stay user-visible in Files under iCloud Drive — the same
    /// visibility philosophy as UIFileSharingEnabled today. That does mean
    /// a user can rename folders in Finder; a renamed folder simply renders
    /// as an empty project, and .cbproj backups are the recovery story.
    static func bootstrap() async {
        ScanDebugLog.log("boot: resolving ubiquity container")
        let resolved: URL? = await Task.detached(priority: .userInitiated) {
            FileManager.default.url(forUbiquityContainerIdentifier: cloudContainerID)
        }.value
        ScanDebugLog.log("boot: ubiquity container \(resolved == nil ? "nil" : "resolved")")

        guard let container = resolved else {
            rootLock.lock()
            cachedRoot = localProjectsRoot
            rootLock.unlock()
            return
        }

        let cloudRoot = container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: cloudRoot, withIntermediateDirectories: true)

        // Idempotent every-launch merge: catches first-run migration, files
        // written locally during an iCloud-off spell, and anything a crashed
        // previous migration left behind.
        migrate(localRoot: localProjectsRoot, into: cloudRoot)
        ScanDebugLog.log("boot: migrate done")

        rootLock.lock()
        cachedRoot = cloudRoot
        rootLock.unlock()

        resolveConflictVersions(under: cloudRoot)
        ScanDebugLog.log("boot: conflict resolution done")
        requestDownload(of: cloudRoot)
        ScanDebugLog.log("boot: download requested")
    }

    /// Merges the local Projects tree into the cloud tree, per file, newest
    /// modification date wins. The losing file is preserved next to the
    /// winner as `<name>.pre-merge-<ts>` — a merge must never destroy the
    /// only copy of anything. Local files that lose or merge cleanly are
    /// removed so the local tree drains to empty.
    private static func migrate(localRoot: URL, into cloudRoot: URL) {
        let fm = FileManager.default
        // Sweep temps a crashed previous migration left behind — they are
        // inert (never match a primary filename) but shouldn't accumulate.
        if let e = fm.enumerator(at: cloudRoot, includingPropertiesForKeys: nil) {
            for case let item as URL in e where item.lastPathComponent.contains(".migrating-") {
                try? fm.removeItem(at: item)
            }
        }
        guard let folders = try? fm.contentsOfDirectory(at: localRoot,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return }
        for localFolder in folders {
            guard (try? localFolder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let cloudFolder = cloudRoot.appendingPathComponent(localFolder.lastPathComponent, isDirectory: true)
            mergeFolder(local: localFolder, cloud: cloudFolder)
            // Remove the local folder only when fully drained.
            if let leftovers = try? fm.contentsOfDirectory(atPath: localFolder.path), leftovers.isEmpty {
                try? fm.removeItem(at: localFolder)
            }
        }
    }

    private static func mergeFolder(local: URL, cloud: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: cloud, withIntermediateDirectories: true)
        guard let items = try? fm.contentsOfDirectory(at: local,
                                                      includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                                                      options: []) else { return }
        for item in items {
            let name = item.lastPathComponent
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                mergeFolder(local: item, cloud: cloud.appendingPathComponent(name, isDirectory: true))
                if let leftovers = try? fm.contentsOfDirectory(atPath: item.path), leftovers.isEmpty {
                    try? fm.removeItem(at: item)
                }
                continue
            }
            let dest = cloud.appendingPathComponent(name)
            let destPlaceholder = placeholderURL(for: dest)
            if fm.fileExists(atPath: destPlaceholder.path) {
                // The cloud copy exists but isn't downloaded — we can't
                // compare dates against content we don't have. Preserve the
                // local file beside it rather than guess.
                preserve(item, in: cloud)
                continue
            }
            if fm.fileExists(atPath: dest.path) {
                let localDate = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let cloudDate = (try? dest.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if localDate > cloudDate {
                    preserve(dest, in: cloud)
                    if migrationCopy(from: item, to: dest) {
                        try? fm.removeItem(at: item)
                    }
                } else {
                    preserve(item, in: cloud)
                }
            } else {
                // The local source is removed ONLY after a verified copy —
                // a failed copy leaves it in place, and the every-launch
                // idempotent merge retries it. A merge must never destroy
                // the only copy of anything.
                if migrationCopy(from: item, to: dest) {
                    try? fm.removeItem(at: item)
                }
            }
        }
    }

    /// Moves a merge loser to `<name>.pre-merge-<ts>` inside `folder`.
    private static func preserve(_ url: URL, in folder: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let dest = folder.appendingPathComponent("\(url.lastPathComponent).pre-merge-\(stamp)")
        try? FileManager.default.moveItem(at: url, to: dest)
    }

    /// Copies a file into the cloud tree under file coordination and
    /// reports whether the copy verifiably landed. The copy goes to a temp
    /// name and is promoted with an atomic rename — a crash mid-copy can
    /// never leave a truncated file wearing the real name (which would
    /// carry a fresh mtime and beat the intact local copy on the next
    /// merge).
    private static func migrationCopy(from source: URL, to dest: URL) -> Bool {
        let fm = FileManager.default
        var succeeded = false
        var coordError: NSError?
        NSFileCoordinator(filePresenter: nil)
            .coordinate(writingItemAt: dest, options: .forReplacing, error: &coordError) { url in
                let temp = url.deletingLastPathComponent()
                    .appendingPathComponent(".\(url.lastPathComponent).migrating-\(UUID().uuidString)")
                do {
                    try fm.copyItem(at: source, to: temp)
                    _ = try? fm.removeItem(at: url)
                    try fm.moveItem(at: temp, to: url)
                    succeeded = fm.fileExists(atPath: url.path)
                } catch {
                    try? fm.removeItem(at: temp)
                }
            }
        return succeeded && coordError == nil
    }

    // MARK: - iCloud placeholders, downloads, conflicts

    /// The `.name.icloud` stub that stands in for a not-yet-downloaded file.
    static func placeholderURL(for url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
    }

    /// True when the file exists in the cloud but hasn't been downloaded to
    /// this device — distinct from "absent", so callers can show a
    /// downloading state instead of rendering an empty project.
    static func isAwaitingDownload(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: placeholderURL(for: url).path)
    }

    /// Fire-and-forget recursive download request. Safe on non-ubiquitous
    /// URLs (the call just fails silently).
    static func requestDownload(of url: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    /// True when the name is an `.icloud` stub for actual project data —
    /// stubs for sync bookkeeping (quarantine/merge artifacts) don't count;
    /// nothing should wait on or refuse work over files we'd discard.
    static func isDataPlaceholderName(_ name: String) -> Bool {
        name.hasSuffix(".icloud")
            && !name.contains(".corrupt-")
            && !name.contains(".pre-merge-")
    }

    /// True when any project-data file in the folder is an undownloaded
    /// placeholder; also kicks off their downloads. Drives the
    /// "Downloading from iCloud…" banner.
    static func hasUndownloadedFiles(for project: RenovationProject) -> Bool {
        guard let dir = existingFolder(for: project) else { return false }
        var found = false
        if let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let item as URL in e where isDataPlaceholderName(item.lastPathComponent) {
                found = true
            }
        }
        if found { requestDownload(of: dir) }
        return found
    }

    /// Waits until the project folder holds no undownloaded placeholders.
    /// Returns false on timeout. Used before exports that must snapshot the
    /// whole folder (backups) so they can't silently package stubs.
    static func waitForDownload(for project: RenovationProject, timeout: TimeInterval) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if !hasUndownloadedFiles(for: project) { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return !hasUndownloadedFiles(for: project)
    }

    /// Makes last-writer-wins explicit: iCloud records both sides of a
    /// concurrent edit as NSFileVersion conflicts, which otherwise
    /// accumulate invisibly against quota with an arbitrary current
    /// version. Keep the newest, resolve the rest.
    static func resolveConflictVersions(under root: URL) {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in e {
            guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url),
                  !conflicts.isEmpty else { continue }
            let current = NSFileVersion.currentVersionOfItem(at: url)
            let newest = (conflicts + [current].compactMap { $0 })
                .max { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
            if let newest, newest != current {
                _ = try? newest.replaceItem(at: url)
            }
            for version in conflicts { version.isResolved = true }
            try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        }
    }

    /// Creating variant — for WRITE paths only. Read paths must use
    /// `existingFolder(for:)`: creating directories on reads fabricates
    /// empty per-project folders in the cloud tree (which sync outward and
    /// defeat "not yet synced" detection) and can resurrect a folder
    /// another device just deleted.
    static func folder(for project: RenovationProject) throws -> URL {
        let url = projectsRoot.appendingPathComponent(project.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Non-creating read variant: nil when the project has no folder here.
    static func existingFolder(for project: RenovationProject) -> URL? {
        guard !project.folderName.isEmpty else { return nil }
        let url = projectsRoot.appendingPathComponent(project.folderName, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Coordinated file primitives

    /// Encodes-and-saves for every JSON store. File coordination keeps the
    /// iCloud sync daemon from racing the write (uploading a half-swapped
    /// file or clobbering it with an in-flight download); the atomic option
    /// still guarantees readers never see partial bytes.
    private static func write(_ data: Data, named name: String, for project: RenovationProject) throws {
        let dir = try folder(for: project)
        try coordinatedWrite(data, to: dir.appendingPathComponent(name))
    }

    static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil)
            .coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { dest in
                do { try data.write(to: dest, options: .atomic) } catch { writeError = error }
            }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
    }

    /// Swaps a fully-written temp file (e.g. a USDZ exported to Caches)
    /// into place under file coordination, clearing any undownloaded
    /// placeholder wearing the destination name so the swap can't create
    /// the file beside its own stub.
    static func coordinatedReplace(at url: URL, withItemAt temp: URL) throws {
        let fm = FileManager.default
        var coordError: NSError?
        var swapError: Error?
        NSFileCoordinator(filePresenter: nil)
            .coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { dest in
                do {
                    let placeholder = placeholderURL(for: dest)
                    if fm.fileExists(atPath: placeholder.path) {
                        _ = try? fm.removeItem(at: placeholder)
                    }
                    if fm.fileExists(atPath: dest.path) {
                        _ = try fm.replaceItemAt(dest, withItemAt: temp)
                    } else {
                        try fm.moveItem(at: temp, to: dest)
                    }
                } catch { swapError = error }
            }
        if let coordError { throw coordError }
        if let swapError { throw swapError }
    }

    /// Deletes the logical file AND its `.icloud` placeholder form. The
    /// placeholder half matters: a delete that only checks the real name
    /// no-ops on an undownloaded file, the UI reports success, and the
    /// cloud copy re-syncs everywhere — deleted content resurrecting.
    static func coordinatedDelete(at url: URL) {
        let fm = FileManager.default
        var coordError: NSError?
        NSFileCoordinator(filePresenter: nil)
            .coordinate(writingItemAt: url, options: .forDeleting, error: &coordError) { u in
                _ = try? fm.removeItem(at: u)
            }
        let placeholder = placeholderURL(for: url)
        if fm.fileExists(atPath: placeholder.path) {
            NSFileCoordinator(filePresenter: nil)
                .coordinate(writingItemAt: placeholder, options: .forDeleting, error: &coordError) { u in
                    _ = try? fm.removeItem(at: u)
                }
        }
    }

    // MARK: - Scan files

    /// Saves a LiDAR scan. room.json — the data every feature reads — is
    /// written FIRST so a fragile USDZ export can never lose the scan; the
    /// export falls back to .mesh when RoomPlan can't parametrize, and goes
    /// to its own file so corner-room exports can never clobber it.
    static func save(capturedRoom: CapturedRoom, for project: RenovationProject) throws {
        let dir = try folder(for: project)
        try coordinatedWrite(JSONEncoder().encode(capturedRoom),
                             to: dir.appendingPathComponent(roomDataFileName))
        // Export to a Caches temp, then swap under coordination — the
        // destination may be in the iCloud container, where the sync
        // daemon would otherwise race a direct multi-second export.
        let usdz = dir.appendingPathComponent(lidarUSDZFileName)
        let temp = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(UUID().uuidString).tmp.usdz")
        do {
            do {
                try capturedRoom.export(to: temp, exportOptions: .parametric)
            } catch {
                try capturedRoom.export(to: temp, exportOptions: .mesh)
            }
            try coordinatedReplace(at: usdz, withItemAt: temp)
        } catch {
            // QA-048: export failed — drop the temp and any stale USDZ so
            // the 3D model can't show a previous room. room.json is
            // already written, so the save stays non-fatal.
            try? FileManager.default.removeItem(at: temp)
            coordinatedDelete(at: usdz)
        }
    }

    // MARK: - Continuous multi-room scan walks

    /// One continuous multi-room LiDAR walk. The AR session stays alive
    /// between rooms, so every captured room shares one coordinate space —
    /// their converted plans keep true relative positions automatically.
    struct ScanWalk: Codable {
        var floorName: String
        var capturedAt: Date
        var rooms: [CapturedRoom]
    }

    static func loadScanWalks(for project: RenovationProject) -> [ScanWalk] {
        decodeFile([ScanWalk].self, named: scanWalksFileName, for: project) ?? []
    }

    /// Saves a finished walk: raw room data first (recoverable no matter
    /// what follows), then each room converted to an editable plan — the
    /// batch translated as one unit so the walk's true layout survives —
    /// and finally the whole walk merged into one dollhouse USDZ.
    ///
    /// QA-012 pattern: the caller resolves the directory and loads the
    /// existing rooms/walks on the main actor; this function does pure URL
    /// I/O and never touches a SwiftData model, so it is safe detached.
    /// Returns how many rooms were added and how many failed conversion.
    static func saveScanWalk(rooms captured: [CapturedRoom], floorName: String,
                             existingRooms: [RoomEntry], existingWalks: [ScanWalk],
                             directory dir: URL) async throws -> (added: Int, failed: Int) {
        var walks = existingWalks
        walks.append(ScanWalk(floorName: floorName, capturedAt: .now, rooms: captured))
        try coordinatedWrite(JSONEncoder().encode(walks),
                             to: dir.appendingPathComponent(scanWalksFileName))

        var converted: [CornerRoom] = []
        var failed = 0
        for room in captured {
            if let cornerRoom = ScanConverter.convert(room) {
                converted.append(cornerRoom)
            } else {
                failed += 1
            }
        }
        var all = existingRooms
        let placed = RoomsFile.placeGroup(converted, alongside: existingRooms)
        let base = existingRooms.count
        for (index, room) in placed.enumerated() {
            all.append(RoomEntry(name: "Scanned Room \(base + index + 1)",
                                 room: room, floorName: floorName))
        }
        if !placed.isEmpty {
            try coordinatedWrite(JSONEncoder().encode(RoomsFile(rooms: all)),
                                 to: dir.appendingPathComponent(roomsFileName))
        }

        // Merged walk USDZ via StructureBuilder — a nice-to-have whose
        // failure never voids the save (rooms.json already carries the plan;
        // scan.usdz rebuilds from the converted rooms regardless).
        let usdz = dir.appendingPathComponent(lidarUSDZFileName)
        let temp = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(UUID().uuidString).tmp.usdz")
        do {
            let builder = StructureBuilder(options: [.beautifyObjects])
            let structure = try await builder.capturedStructure(from: captured)
            do {
                try structure.export(to: temp, exportOptions: .parametric)
            } catch {
                try structure.export(to: temp, exportOptions: .mesh)
            }
            try coordinatedReplace(at: usdz, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
        }
        return (placed.count, failed)
    }

    static func usdzURL(for project: RenovationProject) -> URL? {
        existingFile(named: usdzFileName, for: project)
    }

    static func lidarUSDZURL(for project: RenovationProject) -> URL? {
        existingFile(named: lidarUSDZFileName, for: project)
    }

    static func roomDataURL(for project: RenovationProject) -> URL? {
        existingFile(named: roomDataFileName, for: project)
    }

    static func loadCapturedRoom(for project: RenovationProject) -> CapturedRoom? {
        decodeFile(CapturedRoom.self, named: roomDataFileName, for: project)
    }

    // MARK: - Manual measurements

    static func saveManualRoom(_ room: ManualRoom, for project: RenovationProject) throws {
        try write(JSONEncoder().encode(room), named: manualRoomFileName, for: project)
    }

    static func loadManualRoom(for project: RenovationProject) -> ManualRoom? {
        decodeFile(ManualRoom.self, named: manualRoomFileName, for: project)
    }

    // MARK: - Rooms (corner capture / plan trace)

    /// All rooms in the project. Projects saved before multi-room keep
    /// working: a legacy corner_room.json is read as a single "Room 1"
    /// until the first rooms.json save takes over.
    static func loadRooms(for project: RenovationProject) -> [RoomEntry] {
        if let file = decodeFile(RoomsFile.self, named: roomsFileName, for: project) {
            return file.rooms
        }
        if let legacy = loadCornerRoom(for: project) {
            return [RoomEntry(name: "Room 1", room: legacy)]
        }
        return []
    }

    static func saveRooms(_ rooms: [RoomEntry], for project: RenovationProject) throws {
        try write(JSONEncoder().encode(RoomsFile(rooms: rooms)), named: roomsFileName, for: project)
    }

    /// Legacy pre-multi-room file — read only, for migration into rooms.json.
    static func loadCornerRoom(for project: RenovationProject) -> CornerRoom? {
        decodeFile(CornerRoom.self, named: cornerRoomFileName, for: project)
    }

    // MARK: - Estimate & planning

    static func saveEstimate(_ inputs: EstimateInputs, for project: RenovationProject) throws {
        try write(JSONEncoder().encode(inputs), named: estimateFileName, for: project)
    }

    static func loadEstimate(for project: RenovationProject) -> EstimateInputs? {
        decodeFile(EstimateInputs.self, named: estimateFileName, for: project)
    }

    static func saveTakeoffAdjustments(_ adjustments: TakeoffAdjustments,
                                       for project: RenovationProject) throws {
        try write(JSONEncoder().encode(adjustments), named: takeoffAdjustmentsFileName, for: project)
    }

    static func loadTakeoffAdjustments(for project: RenovationProject) -> TakeoffAdjustments? {
        decodeFile(TakeoffAdjustments.self, named: takeoffAdjustmentsFileName, for: project)
    }

    // MARK: - On-device AI context

    private struct AIContext: Codable {
        var postalCode: String?
    }

    static func saveAIPostal(_ postal: String, for project: RenovationProject) {
        try? write(JSONEncoder().encode(AIContext(postalCode: postal)),
                   named: aiContextFileName, for: project)
    }

    static func loadAIPostal(for project: RenovationProject) -> String? {
        let value = decodeFile(AIContext.self, named: aiContextFileName, for: project)?.postalCode
        return (value?.isEmpty ?? true) ? nil : value
    }

    static func saveAIChat(_ messages: [AIChatMessage], for project: RenovationProject) throws {
        try write(JSONEncoder().encode(messages), named: aiChatFileName, for: project)
    }

    static func loadAIChat(for project: RenovationProject) -> [AIChatMessage]? {
        decodeFile([AIChatMessage].self, named: aiChatFileName, for: project)
    }

    static func saveROI(_ inputs: ROIInputs, for project: RenovationProject) throws {
        try write(JSONEncoder().encode(inputs), named: roiFileName, for: project)
    }

    static func loadROI(for project: RenovationProject) -> ROIInputs? {
        decodeFile(ROIInputs.self, named: roiFileName, for: project)
    }

    static func savePlanning(_ checklist: PlanningChecklist, for project: RenovationProject) throws {
        try write(JSONEncoder().encode(checklist), named: planningFileName, for: project)
    }

    static func loadPlanning(for project: RenovationProject) -> PlanningChecklist? {
        decodeFile(PlanningChecklist.self, named: planningFileName, for: project)
    }

    // MARK: - Quote settings

    static func saveQuoteSettings(_ settings: QuoteSettings, for project: RenovationProject) throws {
        try write(JSONEncoder().encode(settings), named: quoteSettingsFileName, for: project)
    }

    /// Returns the project's saved quote settings, or defaults when absent.
    /// Routes through `decodeFile`, so a corrupt file is quarantined like
    /// every other loader before defaults are returned.
    static func loadQuoteSettings(for project: RenovationProject) -> QuoteSettings {
        decodeFile(QuoteSettings.self, named: quoteSettingsFileName, for: project) ?? QuoteSettings()
    }

    // MARK: - Plan markers & photo captions

    static func saveMarkers(_ markers: PlanMarkers, for project: RenovationProject) throws {
        try write(JSONEncoder().encode(markers), named: markersFileName, for: project)
    }

    static func loadMarkers(for project: RenovationProject) -> PlanMarkers? {
        decodeFile(PlanMarkers.self, named: markersFileName, for: project)
    }

    static func savePhotoCaptions(_ captions: [String: String], for project: RenovationProject) throws {
        try write(JSONEncoder().encode(captions), named: photoCaptionsFileName, for: project)
    }

    static func loadPhotoCaptions(for project: RenovationProject) -> [String: String] {
        decodeFile([String: String].self, named: photoCaptionsFileName, for: project) ?? [:]
    }

    static func removeFile(named name: String, for project: RenovationProject) {
        // Deliberately NOT gated on existingFile: an undownloaded file
        // exists only as its placeholder, and the delete must still
        // propagate cloud-wide.
        guard let dir = existingFolder(for: project) else { return }
        coordinatedDelete(at: dir.appendingPathComponent(name))
    }

    static func savePermitMeasurements(_ measurements: PermitMeasurements, for project: RenovationProject) throws {
        try write(JSONEncoder().encode(measurements), named: permitMeasurementsFileName, for: project)
    }

    static func loadPermitMeasurements(for project: RenovationProject) -> PermitMeasurements? {
        decodeFile(PermitMeasurements.self, named: permitMeasurementsFileName, for: project)
    }

    private static func existingFile(named name: String, for project: RenovationProject) -> URL? {
        guard let dir = existingFolder(for: project) else { return nil }
        let url = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        // Present in the cloud but not on this device yet: kick off the
        // download and report "not available yet" — the project-level
        // banner tells the user files are still arriving.
        if isAwaitingDownload(url) { requestDownload(of: url) }
        return nil
    }

    /// Loads and decodes a per-project JSON file. QA-013: distinguishes an
    /// *absent* file (returns nil, nothing to preserve) from one that exists
    /// but is *unreadable/undecodable* — in the latter case the file is
    /// quarantined (renamed to `<name>.corrupt-<timestamp>`) before returning
    /// nil, so the caller's next save can't atomically overwrite a
    /// corrupt-but-recoverable file. File formats are unchanged.
    private static func decodeFile<T: Decodable>(_ type: T.Type, named name: String,
                                                 for project: RenovationProject) -> T? {
        guard let url = existingFile(named: name, for: project) else { return nil }
        // A *read* failure (device locked under data protection, file not yet
        // materialised, transient I/O) must NOT quarantine — the bytes may be
        // perfectly valid and unavailable only for a moment. Return nil and
        // leave the file untouched. Only a *decode* failure of successfully
        // read bytes means the content is actually corrupt.
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            quarantineFile(at: url)
            return nil
        }
    }

    /// Preserves an undecodable file so a later save cannot destroy it.
    /// In the LOCAL root the file is renamed aside (original behavior). In
    /// the CLOUD root a rename would sync — letting one device running an
    /// older build "corrupt-flag" a file every other device decodes fine
    /// (schema skew), destroying the primary copy fleet-wide. There we
    /// quarantine by COPY, leave the original in place, and skip if a
    /// quarantine copy for this file already exists so repeated failed
    /// reads can't pile up copies.
    private static func quarantineFile(at url: URL) {
        let fm = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        let dest = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
        guard isCloudRoot, url.path.hasPrefix(projectsRoot.path) else {
            try? fm.moveItem(at: url, to: dest)
            return
        }
        let dir = url.deletingLastPathComponent()
        let prefix = "\(url.lastPathComponent).corrupt-"
        // An existing quarantine copy may itself be an undownloaded
        // placeholder (".<name>.corrupt-<ts>.icloud") — count both forms.
        let alreadyQuarantined = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .contains { $0.hasPrefix(prefix) || ($0.hasPrefix(".\(prefix)") && $0.hasSuffix(".icloud")) }
        if !alreadyQuarantined {
            try? fm.copyItem(at: url, to: dest)
        }
    }

    /// QA-009: a photo file name must be a bare last-path-component — no
    /// directory separators and no `..` — so it can never escape the
    /// project's photos folder.
    static func isSafePhotoFileName(_ name: String) -> Bool {
        !name.isEmpty
            && !name.contains("/")
            && !name.contains("\\")
            && !name.contains("..")
            && name == (name as NSString).lastPathComponent
    }

    // MARK: - Photos

    static func addPhoto(_ data: Data, to project: RenovationProject) throws -> String {
        let dir = try folder(for: project).appendingPathComponent(photosFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".jpg"
        let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.85) ?? data
        try coordinatedWrite(jpeg, to: dir.appendingPathComponent(name))
        return name
    }

    static func photoURL(named name: String, in project: RenovationProject) -> URL? {
        guard let url = containedPhotoURL(named: name, in: project) else { return nil }
        if FileManager.default.fileExists(atPath: url.path) { return url }
        if isAwaitingDownload(url) { requestDownload(of: url) }
        return nil
    }

    /// QA-009 traversal checks without the existence gate — deletes need
    /// the URL even when only the `.icloud` placeholder is on disk.
    private static func containedPhotoURL(named name: String, in project: RenovationProject) -> URL? {
        guard isSafePhotoFileName(name), let dir = existingFolder(for: project) else { return nil }
        let photosDir = dir.appendingPathComponent(photosFolderName, isDirectory: true)
        let url = photosDir.appendingPathComponent(name)
        // Defence in depth: the resolved file must sit directly inside photos/.
        guard url.deletingLastPathComponent().standardizedFileURL.path
                == photosDir.standardizedFileURL.path else { return nil }
        return url
    }

    static func deletePhoto(named name: String, in project: RenovationProject) {
        guard let url = containedPhotoURL(named: name, in: project) else { return }
        coordinatedDelete(at: url)
    }

    static func deleteAllFiles(for project: RenovationProject) {
        // An empty folderName is conceivable only from a half-synced
        // CloudKit record — and would resolve to the Projects root itself.
        // Never delete the whole tree.
        guard !project.folderName.isEmpty else { return }
        let url = projectsRoot.appendingPathComponent(project.folderName, isDirectory: true)
        coordinatedDelete(at: url)
    }
}
