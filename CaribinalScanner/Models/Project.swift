import Foundation
import SwiftData

// CloudKit-backed SwiftData requires every stored property to be optional or
// carry a default value, forbids unique constraints, and requires optional
// relationships. The inline defaults below exist for that validation — the
// init still assigns every field. NOTE: the defaults are captured once at
// schema build time (they become the store's attribute defaults), so
// folderName's UUID default is NOT per-materialization; folder uniqueness
// relies on every writer assigning a fresh UUID (the init and backup import
// both do), and deleteAllFiles guards the empty-string case.
@Model
final class RenovationProject {
    var name: String = ""
    var clientName: String = ""
    var address: String = ""
    var phone: String = ""
    var email: String = ""
    var projectType: String = "Basement Development"
    var notes: String = ""
    var createdAt: Date = Date.now
    var scanDate: Date?
    var folderName: String = UUID().uuidString
    var photoFileNames: [String] = []
    var estimateStatus: String = "Not started"
    var permitStatus: String = "Not required"

    static let estimateStatuses = ["Not started", "Draft", "Sent", "Approved"]
    static let permitStatuses = ["Not required", "Not started", "Preparing", "Submitted", "Approved"]
    static let projectTypes = ["Basement Development", "Legal Secondary Suite", "Renovation",
                               "Whole House", "Exterior", "Multi Family", "Property Flip", "Other"]

    init(name: String,
         clientName: String = "",
         address: String = "",
         phone: String = "",
         email: String = "",
         projectType: String = "Basement Development") {
        self.name = name
        self.clientName = clientName
        self.address = address
        self.phone = phone
        self.email = email
        self.projectType = projectType
        self.notes = ""
        self.createdAt = .now
        self.scanDate = nil
        self.folderName = UUID().uuidString
        self.photoFileNames = []
    }
}

/// Synced tombstone for a deleted project. CloudKit record deletion and
/// iCloud Drive file deletion are independent pipelines with no ordering
/// guarantee: a device that edited the project's files while offline can
/// resurrect its folder after the folder was deleted everywhere else. The
/// tombstone travels through the same CloudKit store as the projects, so
/// every device can sweep resurrected folders on launch — and ONLY folders
/// a tombstone names. Unknown folders are never touched: "folder with no
/// project row" is a normal transient state while a project is still
/// downloading.
@Model
final class DeletedProject {
    var folderName: String = ""
    var deletedAt: Date = Date.now

    init(folderName: String) {
        self.folderName = folderName
        self.deletedAt = .now
    }
}
