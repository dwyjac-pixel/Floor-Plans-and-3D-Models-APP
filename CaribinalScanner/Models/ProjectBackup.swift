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

        var errorDescription: String? {
            switch self {
            case .unreadable: "That file isn't a readable project backup."
            case .writeFailed: "Could not write the backup file."
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
        // QA-014: a folder-wrapper failure must surface as an error, not a
        // silent manifest-only backup — the folder always exists here.
        let folderWrapper = try FileWrapper(url: folderURL)
        // QA-038: never ship the AI chat transcript in a shared backup.
        if let chatWrapper = folderWrapper.fileWrappers?[ScanStore.aiChatFileName] {
            folderWrapper.removeFileWrapper(chatWrapper)
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
}
