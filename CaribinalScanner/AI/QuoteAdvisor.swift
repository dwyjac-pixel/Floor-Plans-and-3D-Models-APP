import Foundation
import Security

/// One turn of the per-project AI quote conversation, persisted so the
/// discussion survives app restarts.
struct AIChatMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var role: String        // "user" | "assistant"
    var text: String
}

/// Keychain storage for the Claude API key — never UserDefaults, never in
/// a project file that could ride along in a backup export.
enum APIKeyStore {
    private static let service = "com.caribinalcreations.scanner.anthropic"
    private static let account = "api-key"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only wipe the stored key when a real replacement is being written —
        // an empty/whitespace input must not delete the existing key.
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        delete()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Claude-powered quote review: builds a project snapshot (rooms, takeoff
/// with the user's pricing, estimate) and converses about what to replace,
/// fix, add, or remove. Talks to the Claude API directly over HTTPS.
enum QuoteAdvisor {
    static let model = "claude-opus-5"

    enum AdvisorError: LocalizedError {
        case noAPIKey
        case api(String)
        case badResponse
        case refused

        var errorDescription: String? {
            switch self {
            case .noAPIKey: "Add your Claude API key first."
            case .api(let message): message
            case .badResponse: "The AI service returned an unexpected response."
            case .refused: "The AI declined to answer that. Try rephrasing your question."
            }
        }
    }

    /// Compact project snapshot the model sees as its system context.
    static func buildContext(project: RenovationProject,
                             rooms: [RoomEntry],
                             takeoff: MaterialTakeoff?,
                             adjustments: TakeoffAdjustments,
                             estimate: EstimateResult?,
                             useImperial: Bool) -> String {
        var lines: [String] = []
        lines.append("PROJECT: \(project.name)")
        lines.append("Type: \(project.projectType)")
        let guidance = ProjectTypeProfile.profile(for: project.projectType).aiGuidance
        if !guidance.isEmpty { lines.append(guidance) }
        if !project.clientName.isEmpty { lines.append("Client: \(project.clientName)") }
        if !project.address.isEmpty { lines.append("Address: \(project.address)") }
        if !project.notes.isEmpty { lines.append("Notes: \(project.notes)") }

        if !rooms.isEmpty {
            lines.append("\nROOMS (\(rooms.count)):")
            for entry in rooms {
                let room = entry.room
                let area = Measure.area(room.floorAreaSquareMeters, imperial: useImperial)
                let ceiling = Measure.length(room.ceilingHeightMeters > 0.5 ? room.ceilingHeightMeters : 2.4,
                                             imperial: useImperial)
                let doors = room.openings.filter { $0.kind == .door }.count
                let closets = room.openings.filter { $0.kind == .closetDoor }.count
                let windows = room.openings.filter { $0.kind == .window }.count
                var parts = ["\(entry.name): \(area), ceiling \(ceiling)"]
                if doors > 0 { parts.append("\(doors) door(s)") }
                if closets > 0 { parts.append("\(closets) closet door(s)") }
                if windows > 0 { parts.append("\(windows) window(s)") }
                if !room.fixtures.isEmpty {
                    parts.append("fixtures: " + room.fixtures.map(\.kind.rawValue).joined(separator: ", "))
                }
                lines.append("- " + parts.joined(separator: "; "))
            }
        }

        if let takeoff, !takeoff.lines.isEmpty {
            lines.append("\nMATERIAL TAKEOFF (quote line items):")
            for line in takeoff.lines {
                let included = adjustments.isIncluded(line)
                var text = "- [\(included ? "included" : "EXCLUDED")] \(line.category) / \(line.item): \(line.quantity)"
                if let price = adjustments.price(for: line) {
                    text += " @ \(Money.format(price))"
                } else {
                    text += " (no price entered)"
                }
                if !line.note.isEmpty { text += " — \(line.note)" }
                lines.append(text)
            }
            lines.append("Included takeoff total: \(Money.format(adjustments.total(for: takeoff)))")
        }

        if let estimate {
            lines.append("\nESTIMATE:")
            for line in estimate.lines {
                lines.append("- \(line.label): \(Money.format(line.low)) – \(Money.format(line.high))")
            }
            lines.append("Estimate range: \(estimate.rangeText)")
        }

        return lines.joined(separator: "\n")
    }

    private static func systemPrompt(context: String) -> String {
        """
        You are the quote advisor inside CaribinalScanner, a renovation and \
        property-flip app used by contractors and investors. The user has \
        captured the property below and built a quote from it. Help them \
        decide what should be replaced, fixed, added, or removed from the \
        quote — and why — so the scope and budget fit the project's goal.

        Guidelines:
        - Ground every suggestion in the project data below. Refer to \
        takeoff line items by name.
        - Be concrete about cost impact. Prices are CAD.
        - For a flip, weigh each item against resale value; flag work that \
        rarely returns its cost, and cheap wins that are missing.
        - When you suggest changing a line item, tell the user they can \
        untick or reprice it on the Material Takeoff screen.
        - Flag anything that commonly needs a permit or an inspection.
        - Keep responses focused and brief; use short lists, not essays. \
        You are advising a professional, not writing a report.
        - You cannot see photos or the site itself — say so when a question \
        needs eyes on site, and say what to check.

        PROJECT DATA:
        \(context)
        """
    }

    /// One conversational turn. Sends the whole history each time; the
    /// project snapshot rides in the system prompt with a cache marker so
    /// repeat turns reuse it.
    static func send(history: [AIChatMessage], context: String) async throws -> String {
        guard let apiKey = APIKeyStore.load() else { throw AdvisorError.noAPIKey }

        // Cap the transcript sent to the API to a recent window so token cost
        // stays bounded as the on-disk / UI history grows unbounded.
        let recent = history.suffix(24)
        let messages: [[String: Any]] = recent.map {
            ["role": $0.role, "content": $0.text]
        }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": [[
                "type": "text",
                "text": systemPrompt(context: context),
                "cache_control": ["type": "ephemeral"],
            ]],
            "messages": messages,
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AdvisorError.badResponse }

        // Parse defensively — an error response (proxy 502, rate-limit HTML,
        // gateway timeout) may not be JSON at all. Check the status code
        // BEFORE requiring a parsed body so a raw Foundation parse error
        // never surfaces to the user.
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        if http.statusCode != 200 {
            if let error = json?["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw AdvisorError.api(message)
            }
            throw AdvisorError.api("The AI service returned an error (\(http.statusCode)).")
        }

        guard let json else { throw AdvisorError.badResponse }

        // Check the stop reason before reading content — safety classifiers
        // can decline with an empty content array.
        if json["stop_reason"] as? String == "refusal" {
            throw AdvisorError.refused
        }
        guard let content = json["content"] as? [[String: Any]] else {
            throw AdvisorError.badResponse
        }
        let text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw AdvisorError.badResponse }
        return text
    }
}
