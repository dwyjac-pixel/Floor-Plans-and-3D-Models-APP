import Foundation
import SwiftData
#if canImport(FoundationModels)
import FoundationModels
#endif

/// App-wide on-device assistant: the model answers from real project data
/// through tools, never from imagination. Reads work on snapshots built on
/// the main actor (QA-012 — tools run off-main and must not touch SwiftData
/// models); writes hop back to the main actor through injected callbacks.
enum AppAssistant {

    /// Plain-value picture of one project, safe to hand to background tools.
    struct ProjectSnapshot: Sendable {
        var name: String
        var client: String
        var address: String
        var postal: String
        var phone: String
        var email: String
        var type: String
        var estimateStatus: String
        var permitStatus: String
        var created: Date
        var scanned: Date?
        var roomCount: Int
        var floorAreaM2: Double
        var floors: [String]
        var quoteTotal: Double?
        var notes: String

        func summary(imperial: Bool) -> String {
            var out = "• \(name)"
            if !client.isEmpty { out += ": client \(client)" }
            if !address.isEmpty { out += ", \(address)" }
            if !postal.isEmpty { out += " (\(postal))" }
            out += ". Type: \(type). Estimate: \(estimateStatus). Permit: \(permitStatus)."
            if roomCount > 0 {
                out += " \(roomCount) room(s), \(Measure.area(floorAreaM2, imperial: imperial))"
                if floors.count > 1 { out += " across \(floors.joined(separator: ", "))" }
                out += "."
            }
            if let quoteTotal { out += " Quote total \(Money.format(quoteTotal))." }
            if !phone.isEmpty { out += " Phone \(phone)." }
            if !email.isEmpty { out += " Email \(email)." }
            return out
        }
    }

    /// Built on the main actor; disk reads per project are small JSON files.
    @MainActor
    static func snapshot(_ projects: [RenovationProject]) -> [ProjectSnapshot] {
        projects.map { project in
            let rooms = ScanStore.loadRooms(for: project)
            let adjustments = ScanStore.loadTakeoffAdjustments(for: project)
            var total: Double?
            if let adjustments, !adjustments.prices.isEmpty {
                let sum = adjustments.prices
                    .filter { !adjustments.excludedKeys.contains($0.key) }
                    .values.reduce(0, +)
                if sum > 0 { total = sum }
            }
            return ProjectSnapshot(
                name: project.name,
                client: project.clientName,
                address: project.address,
                postal: project.postalCode,
                phone: project.phone,
                email: project.email,
                type: project.projectType,
                estimateStatus: project.estimateStatus,
                permitStatus: project.permitStatus,
                created: project.createdAt,
                scanned: project.scanDate,
                roomCount: rooms.count,
                floorAreaM2: rooms.reduce(0) { $0 + $1.room.floorAreaSquareMeters },
                floors: {
                    var seen: [String] = []
                    for entry in rooms where !seen.contains(entry.floorDisplayName) {
                        seen.append(entry.floorDisplayName)
                    }
                    return seen
                }(),
                quoteTotal: total,
                notes: String(project.notes.prefix(300)))
        }
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
extension AppAssistant {

    static func makeSession(snapshots: [ProjectSnapshot],
                            imperial: Bool,
                            setStatus: @escaping @Sendable (String, String, String) async -> String,
                            addNote: @escaping @Sendable (String, String) async -> String)
        -> LanguageModelSession {
        let tools: [any Tool] = [
            LookupProjectsTool(snapshots: snapshots, imperial: imperial),
            ProjectNotesTool(snapshots: snapshots),
            SetStatusTool(perform: setStatus),
            AddNoteTool(perform: addNote),
        ]
        return LanguageModelSession(tools: tools, instructions: """
        You are the office assistant inside Interior AI Reno Planner, a \
        contractor's basement-renovation app. Answer ONLY from what the tools return. Look \
        projects up before stating any fact, and if the tools don't have it, say so. \
        You can also update a project's estimate/permit status and add notes when \
        asked. Be brief and practical; format money and measurements exactly as the \
        tools give them.
        """)
    }

    struct LookupProjectsTool: Tool {
        let name = "lookup_projects"
        let description = "Search projects and clients by any text (client name, project name, address, postal code, status). Empty query lists every project. Returns client contact info, statuses, room/area facts, and quote totals."

        @Generable
        struct Arguments {
            @Guide(description: "Text to match against name, client, address, postal code, type, or status. Empty for all.")
            var query: String
        }

        let snapshots: [AppAssistant.ProjectSnapshot]
        let imperial: Bool

        func call(arguments: Arguments) async throws -> String {
            let query = arguments.query.trimmingCharacters(in: .whitespaces).lowercased()
            let matches = query.isEmpty ? snapshots : snapshots.filter {
                [$0.name, $0.client, $0.address, $0.postal, $0.type,
                 $0.estimateStatus, $0.permitStatus]
                    .contains { $0.lowercased().contains(query) }
            }
            guard !matches.isEmpty else {
                return "No projects match \"\(arguments.query)\". There are \(snapshots.count) project(s) total."
            }
            let listed = matches.prefix(6).map { $0.summary(imperial: imperial) }
            var text = listed.joined(separator: "\n")
            if matches.count > 6 { text += "\n(and \(matches.count - 6) more)" }
            return text
        }
    }

    struct ProjectNotesTool: Tool {
        let name = "project_notes"
        let description = "Read the saved notes for one project (matched by project or client name)."

        @Generable
        struct Arguments {
            @Guide(description: "Project or client name")
            var project: String
        }

        let snapshots: [AppAssistant.ProjectSnapshot]

        func call(arguments: Arguments) async throws -> String {
            let query = arguments.project.lowercased()
            guard let match = snapshots.first(where: {
                $0.name.lowercased().contains(query) || $0.client.lowercased().contains(query)
            }) else {
                return "No project matches \"\(arguments.project)\"."
            }
            return match.notes.isEmpty
                ? "\(match.name) has no notes."
                : "Notes for \(match.name): \(match.notes)"
        }
    }

    struct SetStatusTool: Tool {
        let name = "set_status"
        let description = "Update a project's estimate status (Not started, Draft, Sent, Approved) or permit status (Not required, Not started, Preparing, Submitted, Approved)."

        @Generable
        struct Arguments {
            @Guide(description: "Project or client name")
            var project: String
            @Guide(description: "Exactly 'estimate' or 'permit'")
            var kind: String
            @Guide(description: "The new status value")
            var value: String
        }

        let perform: @Sendable (String, String, String) async -> String

        func call(arguments: Arguments) async throws -> String {
            await perform(arguments.project, arguments.kind, arguments.value)
        }
    }

    struct AddNoteTool: Tool {
        let name = "add_note"
        let description = "Append a note to a project's notes."

        @Generable
        struct Arguments {
            @Guide(description: "Project or client name")
            var project: String
            @Guide(description: "The note text to add")
            var note: String
        }

        let perform: @Sendable (String, String) async -> String

        func call(arguments: Arguments) async throws -> String {
            await perform(arguments.project, arguments.note)
        }
    }
}
#endif
