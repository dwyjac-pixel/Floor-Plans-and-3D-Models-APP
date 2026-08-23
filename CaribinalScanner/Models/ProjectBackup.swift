import Foundation
import SwiftData

/// Single-file project backup (.cbproj): the project's entire folder
/// (rooms, estimate, planning, markers, photos, model) plus a manifest of
/// the SwiftData fields, wrapped with FileWrapper so it round-trips
/// losslessly. Save it to Files/iCloud, AirDrop it to another device, and
/// import it from the dashboard.
enum ProjectBackup {
    struct Manifest: Codable {
        var name = ""
        var clientName = ""
        var address = ""
        var phone = ""
        var email = ""
        var projectType = ""
        var notes = ""
        var createdAt = Date.now
        var scanDate: Date?
        var folderName = ""
        var photoFileNames: [String] = []
        var estimateStatus = "Not started"
        var permitStatus = "Not required"
    }

    enum BackupError: LocalizedError {
        case unreadable
        case writeFailed
        case filesNotDownloaded(Int)

        var errorDescription: String? {
            switch self {
            case .unreadable: "That file isn't a readable project backup."
            case .writeFailed: "Could not write the backup file."
            case .filesNotDownloaded(let count):
                "\(count) file\(count == 1 ? " is" : "s are") still downloading from iCloud. Try again once the download finishes."
            }
        }
    }

    private static let manifestName = "manifest.json"
    private static let folderKey = "folder"

    // MARK: - Export

    static func export(_ project: RenovationProject) throws -> URL {
        var manifest = Manifest()
        manifest.name = project.name
        manifest.clientName = project.clientName
        manifest.address = project.address
        manifest.phone = project.phone
        manifest.email = project.email
        manifest.projectType = project.projectType
        manifest.notes = project.notes
        manifest.createdAt = project.createdAt
        manifest.scanDate = project.scanDate
        manifest.folderName = project.folderName
        manifest.photoFileNames = project.photoFileNames
        manifest.estimateStatus = project.estimateStatus
        manifest.permitStatus = project.permitStatus
        let manifestData = try JSONEncoder().encode(manifest)

        let container = FileWrapper(directoryWithFileWrappers: [
            manifestName: FileWrapper(regularFileWithContents: manifestData),
        ])
        let folderURL = try ScanStore.folder(for: project)
        // A backup taken while files are still `.icloud` placeholders would
        // silently package stubs instead of content — worthless exactly when
        // it's needed. Refuse loudly (the check also kicks the downloads, so
        // a retry succeeds once they land).
        let placeholderCount = countPlaceholders(in: folderURL)
        guard placeholderCount == 0 else {
            throw BackupError.filesNotDownloaded(placeholderCount)
        }
        // QA-014: a folder-wrapper failure must surface as an error, not a
        // silent manifest-only backup — the folder always exists here.
        // Coordinated read: a consistent multi-file snapshot the sync
        // daemon can't half-replace mid-wrap.
        let folderWrapper = try coordinatedFolderWrapper(at: folderURL)
        // QA-038: never ship the AI chat transcript in a shared backup.
        if let chatWrapper = folderWrapper.fileWrappers?[ScanStore.aiChatFileName] {
            folderWrapper.removeFileWrapper(chatWrapper)
        }
        stripSyncArtifacts(from: folderWrapper, includingDataStubs: false)
        // Belt over the pre-check: an eviction between countPlaceholders
        // and the wrap would otherwise ship a silently incomplete backup.
        let stubbed = remainingDataPlaceholders(in: folderWrapper)
        guard stubbed == 0 else {
            ScanStore.requestDownload(of: folderURL)
            throw BackupError.filesNotDownloaded(stubbed)
        }
        folderWrapper.preferredFilename = folderKey
        container.addFileWrapper(folderWrapper)

        guard let data = container.serializedRepresentation else {
            throw BackupError.writeFailed
        }
        let safeName = project.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName).cbproj")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Import

    @discardableResult
    static func importBackup(from url: URL, into context: ModelContext) throws -> RenovationProject {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        guard let container = FileWrapper(serializedRepresentation: data),
              let manifestWrapper = container.fileWrappers?[manifestName],
              let manifestData = manifestWrapper.regularFileContents,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData) else {
            throw BackupError.unreadable
        }

        let project = RenovationProject(name: manifest.name.isEmpty ? "Imported Project" : manifest.name,
                                        clientName: manifest.clientName,
                                        address: manifest.address,
                                        phone: manifest.phone,
                                        email: manifest.email,
                                        projectType: manifest.projectType)
        project.notes = manifest.notes
        project.createdAt = manifest.createdAt
        project.scanDate = manifest.scanDate
        // QA-009: drop any traversal names so an imported backup can never
        // reach outside the project's photos folder at delete/read time.
        project.photoFileNames = manifest.photoFileNames.filter(ScanStore.isSafePhotoFileName)
        project.estimateStatus = manifest.estimateStatus
        project.permitStatus = manifest.permitStatus
        // A fresh folder name avoids colliding with an existing project.
        project.folderName = UUID().uuidString

        if let folderWrapper = container.fileWrappers?[folderKey] {
            // A backup made by an older build could carry sync artifacts;
            // never restore those as literal files.
            stripSyncArtifacts(from: folderWrapper, includingDataStubs: true)
            let destination = ScanStore.projectsRoot
                .appendingPathComponent(project.folderName, isDirectory: true)
            try FileManager.default.createDirectory(at: ScanStore.projectsRoot,
                                                    withIntermediateDirectories: true)
            try folderWrapper.write(to: destination, options: .atomic,
                                    originalContentsURL: nil)
        }

        context.insert(project)
        try context.save()
        return project
    }

    // MARK: - iCloud-aware helpers

    /// Counts `.icloud` placeholder stubs for actual project data anywhere
    /// in the folder — stubs for artifacts the export strips anyway
    /// (quarantine/merge leftovers, the AI chat) don't block a backup —
    /// and kicks off their download so a retry can succeed.
    private static func countPlaceholders(in folder: URL) -> Int {
        var count = 0
        if let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) {
            for case let item as URL in e {
                let name = item.lastPathComponent
                guard ScanStore.isDataPlaceholderName(name),
                      name != ".\(ScanStore.aiChatFileName).icloud" else { continue }
                count += 1
            }
        }
        if count > 0 { ScanStore.requestDownload(of: folder) }
        return count
    }

    /// Counts data `.icloud` stubs that made it INTO the wrapper (post
    /// stripSyncArtifacts, which removes only artifact stubs).
    private static func remainingDataPlaceholders(in wrapper: FileWrapper) -> Int {
        guard let children = wrapper.fileWrappers else { return 0 }
        var count = 0
        for (name, child) in children {
            if name.hasSuffix(".icloud") {
                count += 1
            } else if child.isDirectory {
                count += remainingDataPlaceholders(in: child)
            }
        }
        return count
    }

    /// Reads the folder into a FileWrapper under file coordination, so the
    /// snapshot can't interleave with an in-flight sync replacement.
    /// `.immediate` forces contents to be read INSIDE the coordinated
    /// block (FileWrapper is lazy by default, which would defer the actual
    /// reads to serialization time — outside the lock); `.withoutMapping`
    /// keeps them copies rather than mappings of files the daemon may
    /// replace after the lock is released.
    private static func coordinatedFolderWrapper(at folderURL: URL) throws -> FileWrapper {
        var coordError: NSError?
        var result: Result<FileWrapper, Error> = .failure(BackupError.writeFailed)
        NSFileCoordinator(filePresenter: nil)
            .coordinate(readingItemAt: folderURL, options: [], error: &coordError) { url in
                result = Result { try FileWrapper(url: url, options: [.immediate, .withoutMapping]) }
            }
        if let coordError { throw coordError }
        return try result.get()
    }

    /// Drops quarantine/merge leftovers and (per mode) iCloud placeholder
    /// stubs from a folder wrapper, recursively — sync bookkeeping, not
    /// project data. On EXPORT, data stubs are deliberately left in place
    /// so `remainingDataPlaceholders` can refuse the hollow backup; on
    /// IMPORT everything is stripped so stubs never restore as junk files.
    private static func stripSyncArtifacts(from wrapper: FileWrapper, includingDataStubs: Bool) {
        guard let children = wrapper.fileWrappers else { return }
        for (name, child) in children {
            let isArtifact = name.contains(".corrupt-") || name.contains(".pre-merge-")
            let isStub = name.hasSuffix(".icloud")
            let isStrippableStub = isStub && (includingDataStubs
                || !ScanStore.isDataPlaceholderName(name)
                || name == ".\(ScanStore.aiChatFileName).icloud")
            if isArtifact || isStrippableStub {
                wrapper.removeFileWrapper(child)
            } else if child.isDirectory {
                stripSyncArtifacts(from: child, includingDataStubs: includingDataStubs)
            }
        }
    }
}
