import SwiftUI
import SwiftData
#if canImport(FoundationModels)
import FoundationModels
#endif

/// App-wide AI assistant chat: ask about clients, projects, quotes, and
/// statuses in plain language; the on-device model answers through tools
/// that read real project data — and can update statuses or add notes.
struct AssistantScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RenovationProject.createdAt, order: .reverse)
    private var projects: [RenovationProject]
    @AppStorage("useImperialUnits") private var useImperial = true

    @State private var messages: [(role: String, text: String)] = []
    @State private var input = ""
    @State private var isThinking = false
    @State private var session: Any?

    private let suggestions = [
        "List my projects",
        "Who's waiting on a permit?",
        "Pull up the sample client",
        "Which quotes aren't sent yet?",
    ]

    var body: some View {
        NavigationStack {
            Group {
                switch OnDeviceAI.availability {
                case .unsupported:
                    ContentUnavailableView(
                        "Needs Apple Intelligence",
                        systemImage: "sparkles.slash",
                        description: Text("The assistant runs on-device on iPhone 15 Pro or later with iOS 26 — no API key, nothing leaves the phone."))
                case .needsAppleIntelligence:
                    ContentUnavailableView(
                        "Turn on Apple Intelligence",
                        systemImage: "sparkles",
                        description: Text("This device supports it. Turn on Apple Intelligence in Settings → Apple Intelligence & Siri, then come back."))
                case .available:
                    chat
                }
            }
            .navigationTitle("Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if messages.isEmpty {
                            Text("Ask about any client or project — statuses, quotes, areas, notes — or tell me to update a status or add a note. Everything stays on this phone.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.top, 12)
                        }
                        ForEach(messages.indices, id: \.self) { index in
                            let message = messages[index]
                            HStack {
                                if message.role == "user" { Spacer(minLength: 40) }
                                Text(message.text)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(message.role == "user"
                                                ? AnyShapeStyle(.tint.opacity(0.15))
                                                : AnyShapeStyle(.thinMaterial),
                                                in: RoundedRectangle(cornerRadius: 14))
                                if message.role != "user" { Spacer(minLength: 40) }
                            }
                            .id(index)
                        }
                        if isThinking {
                            HStack { ProgressView(); Text("Working…").foregroundStyle(.secondary) }
                        }
                    }
                    .padding(.horizontal)
                }
                .onChange(of: messages.count) { _, count in
                    withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }

            if messages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) {
                                input = suggestion
                                send()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 6)
            }

            HStack {
                TextField("Ask about clients, quotes, statuses…", text: $input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || isThinking)
            }
            .padding()
        }
    }

    private func send() {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return }
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !isThinking else { return }
        input = ""
        messages.append(("user", text))
        isThinking = true

        // Fresh snapshots each conversation keep answers current without
        // letting background tools near SwiftData (QA-012).
        let active: LanguageModelSession
        if let existing = session as? LanguageModelSession {
            active = existing
        } else {
            let snapshots = AppAssistant.snapshot(projects)
            active = AppAssistant.makeSession(
                snapshots: snapshots,
                imperial: useImperial,
                setStatus: { project, kind, value in
                    await MainActor.run { applyStatus(project: project, kind: kind, value: value) }
                },
                addNote: { project, note in
                    await MainActor.run { applyNote(project: project, note: note) }
                })
            session = active
        }

        Task {
            do {
                let response = try await active.respond(to: text)
                await MainActor.run {
                    messages.append(("assistant", response.content))
                    isThinking = false
                }
            } catch {
                await MainActor.run {
                    messages.append(("assistant", "I hit a snag: \(error.localizedDescription). Try rephrasing, or start a fresh question."))
                    isThinking = false
                    session = nil
                }
            }
        }
        #endif
    }

    // MARK: - Write actions (main actor, validated, reversible)

    @MainActor
    private func findProject(_ query: String) -> RenovationProject? {
        let lowered = query.lowercased()
        return projects.first {
            $0.name.lowercased().contains(lowered) || $0.clientName.lowercased().contains(lowered)
        }
    }

    @MainActor
    private func applyStatus(project query: String, kind: String, value: String) -> String {
        guard let project = findProject(query) else {
            return "No project matches \"\(query)\"."
        }
        let allowed = kind.lowercased() == "permit"
            ? RenovationProject.permitStatuses
            : RenovationProject.estimateStatuses
        guard let status = allowed.first(where: { $0.lowercased() == value.lowercased() }) else {
            return "\"\(value)\" isn't a valid \(kind) status. Choices: \(allowed.joined(separator: ", "))."
        }
        if kind.lowercased() == "permit" {
            project.permitStatus = status
        } else {
            project.estimateStatus = status
        }
        try? modelContext.save()
        return "Done — \(project.name)'s \(kind.lowercased()) status is now \(status)."
    }

    @MainActor
    private func applyNote(project query: String, note: String) -> String {
        guard let project = findProject(query) else {
            return "No project matches \"\(query)\"."
        }
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        project.notes += (project.notes.isEmpty ? "" : "\n") + "[\(stamp)] \(note)"
        try? modelContext.save()
        return "Note added to \(project.name)."
    }
}
