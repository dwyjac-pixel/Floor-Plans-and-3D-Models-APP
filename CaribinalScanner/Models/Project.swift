import Foundation
import SwiftData

@Model
final class RenovationProject {
    var name: String
    var clientName: String
    var address: String
    var phone: String
    var email: String
    var projectType: String
    var notes: String
    var createdAt: Date
    var scanDate: Date?
    var folderName: String
    var photoFileNames: [String]
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
