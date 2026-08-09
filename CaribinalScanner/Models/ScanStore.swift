import Foundation
import RoomPlan
import UIKit

/// Manages the files that belong to a project: the exported USDZ model,
/// the encoded CapturedRoom data used to draw the floor plan, and photos.
/// Everything lives under Documents/Projects/<folderName>/ so it is visible
/// in the Files app (file sharing is enabled in the build settings).
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
    static let dealFileName = "deal.json"
    static let planningFileName = "planning.json"
    static let permitMeasurementsFileName = "permit_measurements.json"
    static let quoteSettingsFileName = "quote_settings.json"
    static let markersFileName = "markers.json"
    static let photoCaptionsFileName = "photo_captions.json"
    static let photosFolderName = "photos"

    static var projectsRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Projects", isDirectory: true)
    }

    static func folder(for project: RenovationProject) throws -> URL {
        let url = projectsRoot.appendingPathComponent(project.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Scan files

    /// Saves a LiDAR scan. room.json — the data every feature reads — is
    /// written FIRST so a fragile USDZ export can never lose the scan; the
    /// export falls back to .mesh when RoomPlan can't parametrize, and goes
    /// to its own file so corner-room exports can never clobber it.
    static func save(capturedRoom: CapturedRoom, for project: RenovationProject) throws {
        let dir = try folder(for: project)
        let data = try JSONEncoder().encode(capturedRoom)
        try data.write(to: dir.appendingPathComponent(roomDataFileName), options: .atomic)
        let usdz = dir.appendingPathComponent(lidarUSDZFileName)
        do {
            try capturedRoom.export(to: usdz, exportOptions: .parametric)
        } catch {
            do {
                try capturedRoom.export(to: usdz, exportOptions: .mesh)
            } catch {
                // QA-048: both exports failed — drop any stale USDZ so the
                // 3D model can't show a previous room. room.json is already
                // written, so the save stays non-fatal.
                try? FileManager.default.removeItem(at: usdz)
            }
        }
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
        let dir = try folder(for: project)
        let data = try JSONEncoder().encode(room)
        try data.write(to: dir.appendingPathComponent(manualRoomFileName), options: .atomic)
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
        let dir = try folder(for: project)
        let data = try JSONEncoder().encode(RoomsFile(rooms: rooms))
        try data.write(to: dir.appendingPathComponent(roomsFileName), options: .atomic)
    }

    /// Legacy pre-multi-room file — read only, for migration into rooms.json.
    static func loadCornerRoom(for project: RenovationProject) -> CornerRoom? {
        decodeFile(CornerRoom.self, named: cornerRoomFileName, for: project)
    }

    // MARK: - Estimate & planning

    static func saveEstimate(_ inputs: EstimateInputs, for project: RenovationProject) throws {
        let dir = try folder(for: project)
        let data = try JSONEncoder().encode(inputs)
        try data.write(to: dir.appendingPathComponent(estimateFileName), options: .atomic)
    }

    static func loadEstimate(for project: RenovationProject) -> EstimateInputs? {
        decodeFile(EstimateInputs.self, named: estimateFileName, for: project)
    }

    static func saveTakeoffAdjustments(_ adjustments: TakeoffAdjustments,
                                       for project: RenovationProject) throws {
        let dir = try folder(for: project)
        let data = try JSONEncoder().encode(adjustments)
        try data.write(to: dir.appendingPathComponent(takeoffAdjustmentsFileName), options: .atomic)
    }

    static func loadTakeoffAdjustments(for project: RenovationProject) -> TakeoffAdjustments? {
        decodeFile(TakeoffAdjustments.self, named: takeoffAdjustmentsFileName, for: project)
    }

    static func saveAIChat(_ messages: [AIChatMessage], for project: RenovationProject) throws {
        let dir = try folder(for: project)
        let data = try JSONEncoder().encode(messages)
        try data.write(to: dir.appendingPathComponent(aiChatFileName), options: .atomic)
    }

    static func loadAIChat(for project: RenovationProject) -> [AIChatMessage]? {
        decodeFile([AIChatMessage].self, named: aiChatFileName, for: project)
    }

    static func saveROI(_ inputs: ROIInputs, for project: RenovationProject) throws {
        let dir = try folder(for: project)
        let data = try JSONEncoder().encode(inputs)
        try data.write(to: dir.appendingPathComponent(roiFileName), options: .atomic)
    }

    static func loadROI(for project: RenovationProject) -> ROIInputs? {
        decodeFile(ROIInputs.self, named: roiFileName, for: project)
    }

    static func saveDeal(_ inputs: DealInputs, for project: RenovationProject) throws {
        let dir = try folder(for: project)
        let data = try JSONEncoder().encode(inputs)
        try data.write(to: dir.appendingPathComponent(dealFileName), options: .atomic)
    }

    static func loadDeal(for project: RenovationProject) -> DealInputs? {
        decodeFile(DealInputs.self, named: dealFileName, for: project)
    }

    static func savePlanning(_ checklist: PlanningChecklist, for project: RenovationProject) throws {
        let dir = try folder(for: project)
        let data = try JSONEncoder().encode(checklist)
        try data.write(to: dir.appendingPathComponent(planningFileName), options: .atomic)
    }

    static func loadPlanning(for project: RenovationProject) -> PlanningChecklist? {
        decodeFile(PlanningChecklist.self, named: planningFileName, for: project)
    }

    // MARK: - Quote settings

    static func saveQuoteSettings(_ settings: QuoteSettings, for project: RenovationProject) throws {
        let dir = try folder(for: project)
        let data = try JSONEncoder().encode(settings)
        try data.write(to: dir.appendingPathComponent(quoteSettingsFileName), options: .atomic)
    }

    /// Returns the project's saved quote settings, or defaults when absent.
    /// Routes through `decodeFile`, so a corrupt file is quarantined like
    /// every other loader before defaults are returned.
    static func loadQuoteSettings(for project: RenovationProject) -> QuoteSettings {
        decodeFile(QuoteSettings.self, named: quoteSettingsFileName, for: project) ?? QuoteSettings()
    }

    // MARK: - Plan markers & photo captions

    static func saveMarkers(_ markers: PlanMarkers, for project: RenovationProject) throws {
        let dir = try folder(for: project)
        let data = try JSONEncoder().encode(markers)
        try data.write(to: dir.appendingPathComponent(markersFileName), options: .atomic)
    }

    static func loadMarkers(for project: RenovationProject) -> PlanMarkers? {
        decodeFile(PlanMarkers.self, named: markersFileName, for: project)
    }

    static func savePhotoCaptions(_ captions: [String: String], for project: RenovationProject) throws {
        let dir = try folder(for: project)
        let data = try JSONEncoder().encode(captions)
        try data.write(to: dir.appendingPathComponent(photoCaptionsFileName), options: .atomic)
    }

    static func loadPhotoCaptions(for project: RenovationProject) -> [String: String] {
        decodeFile([String: String].self, named: photoCaptionsFileName, for: project) ?? [:]
    }

    static func removeFile(named name: String, for project: RenovationProject) {
        guard let url = existingFile(named: name, for: project) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func savePermitMeasurements(_ measurements: PermitMeasurements, for project: RenovationProject) throws {
        let dir = try folder(for: project)
        let data = try JSONEncoder().encode(measurements)
        try data.write(to: dir.appendingPathComponent(permitMeasurementsFileName), options: .atomic)
    }

    static func loadPermitMeasurements(for project: RenovationProject) -> PermitMeasurements? {
        decodeFile(PermitMeasurements.self, named: permitMeasurementsFileName, for: project)
    }

    private static func existingFile(named name: String, for project: RenovationProject) -> URL? {
        guard let dir = try? folder(for: project) else { return nil }
        let url = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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

    /// Renames an unreadable file out of the way so a later save cannot
    /// destroy it. Best-effort; failure to rename leaves the file in place.
    private static func quarantineFile(at url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let dest = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
        try? FileManager.default.moveItem(at: url, to: dest)
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
        try jpeg.write(to: dir.appendingPathComponent(name), options: .atomic)
        return name
    }

    static func photoURL(named name: String, in project: RenovationProject) -> URL? {
        // QA-009: refuse traversal names before touching the filesystem.
        guard isSafePhotoFileName(name), let dir = try? folder(for: project) else { return nil }
        let photosDir = dir.appendingPathComponent(photosFolderName, isDirectory: true)
        let url = photosDir.appendingPathComponent(name)
        // Defence in depth: the resolved file must sit directly inside photos/.
        guard url.deletingLastPathComponent().standardizedFileURL.path
                == photosDir.standardizedFileURL.path else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func deletePhoto(named name: String, in project: RenovationProject) {
        guard let url = photoURL(named: name, in: project) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func deleteAllFiles(for project: RenovationProject) {
        let url = projectsRoot.appendingPathComponent(project.folderName, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
    }
}
